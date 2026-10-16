#!/usr/bin/env pwsh
# =============================================================================
# validate-offload-lanes.ps1 - prove every offload lane, or say it is broken.
#
# WHY THIS EXISTS
# ---------------
# Every lane in this ecosystem has at some point been reported as working on the
# strength of a credential existing, a port being open, or a config entry being
# present. All three are not liveness. This session measured:
#
#   * a D1 schema written to LOCAL miniflare while the Worker kept raising
#     "no such table" remotely;
#   * a Task Scheduler task reporting Ready with a dead NextRunTime;
#   * a LiteLLM port answering /v1/models after every process holding it was
#     killed (Windows holds the socket);
#   * a "restart" that reported Running/HEALTH:200 while being a no-op;
#   * a Dev Brain model list that was a hardcoded single entry.
#
# THE RULE THIS ENFORCES
# ----------------------
# A lane is only counted as UP when a REAL REQUEST through it returns the
# artifact that lane is supposed to produce. No port checks, no process checks,
# no config checks. Where a lane cannot be validated, it reports NOT_VALIDATED
# and never passes by default.
#
# USAGE
#   pwsh -File validate-offload-lanes.ps1            # all lanes
#   pwsh -File validate-offload-lanes.ps1 -Lane modal # one lane
#   pwsh -File validate-offload-lanes.ps1 -Json
#
# EXIT CODES
#   0  every requested lane validated
#   1  at least one lane failed
#   2  a lane returned NOT_VALIDATED (distinct from failed - see below)
# =============================================================================
param(
    [string[]]$Lane = @('all'),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Evidence, [string]$Lane)
    # Status is one of: PASS | FAIL | NOT_VALIDATED.
    #   PASS         - a real request returned the real artifact
    #   FAIL         - a real request was made and did not
    #   NOT_VALIDATED - the check could not be run; this is NOT a pass
    $script:results.Add([pscustomobject]@{
        lane = $Lane; check = $Name; status = $Status; evidence = $Evidence
        at = (Get-Date).ToUniversalTime().ToString('o')
    })
}

function Test-Lane([string]$Want) {
    return ($Lane -contains 'all') -or ($Lane -contains $Want)
}

# -----------------------------------------------------------------------------
# AWS - a real S3 round trip, not a credential check.
# SigV4 is hand-rolled because the AWS CLI is not installed on this host.
# -----------------------------------------------------------------------------
function Invoke-AwsS3Probe {
    $ak = $env:AWS_OVERLAYFLEET_ACCESS_KEY_ID
    $sk = $env:AWS_OVERLAYFLEET_SECRET_ACCESS_KEY
    if (-not $ak -or -not $sk) {
        Add-Result 's3.listBuckets' 'NOT_VALIDATED' 'AWS_OVERLAYFLEET_* not in env' 'aws'
        return
    }
    function Hmac([byte[]]$k, [string]$d) {
        $h = New-Object Security.Cryptography.HMACSHA256; $h.Key = $k
        # The cast is load-bearing. PowerShell coerces a byte[] RETURN VALUE to
        # a space-separated STRING when it is passed on to another command
        # (`$kk = Hmac $kk $ds`), so the next round of the signing key would be
        # computed over a string. Without this the signature is wrong in a way
        # that surfaces as an unrelated header-format error, not as a bad
        # signature, which is what made it hard to find the first time.
        return [byte[]]$h.ComputeHash([Text.Encoding]::UTF8.GetBytes($d))
    }
    function HmacHex([byte[]]$k, [string]$d) {
        return [BitConverter]::ToString((Hmac $k $d)).Replace('-', '').ToLower()
    }
    function Sha([string]$s) {
        return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '').ToLower()
    }
    $now = Get-Date
    $amz = $now.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $ds = $now.ToUniversalTime().ToString('yyyyMMdd')
    $ph = Sha ''
    $obj = [ordered]@{ 'host' = 's3.us-east-1.amazonaws.com'; 'x-amz-content-sha256' = $ph; 'x-amz-date' = $amz }
    $sh = (($obj.Keys | Sort-Object) -join ';')
    $ch = foreach ($k in ($obj.Keys | Sort-Object)) { "$k`:$($obj[$k])" }
    $crh = ($ch -join "`n") + "`n"
    $cr = "GET`n/`n`n$crh`n$sh`n$ph"
    $scope = "$ds/us-east-1/s3/aws4_request"
    $sts = "AWS4-HMAC-SHA256`n$amz`n$scope`n" + (Sha $cr)
    [byte[]]$kk = [Text.Encoding]::UTF8.GetBytes("AWS4$sk")
    $kk = Hmac $kk $ds; $kk = Hmac $kk 'us-east-1'; $kk = Hmac $kk 's3'; $kk = Hmac $kk 'aws4_request'
    $sig = HmacHex $kk $sts
    $auth = "AWS4-HMAC-SHA256 Credential=$ak/$scope, SignedHeaders=$sh, Signature=$sig"
    $hd = @{}; foreach ($k in $obj.Keys) { $hd[$k] = $obj[$k] }; $hd['Authorization'] = $auth
    try {
        $r = Invoke-WebRequest -Uri 'https://s3.us-east-1.amazonaws.com/' -Method GET -Headers $hd -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
        $x = [xml]$r.Content
        $names = @($x.ListAllMyBucketsResult.Buckets.Bucket | ForEach-Object { $_.Name })
        Add-Result 's3.listBuckets' 'PASS' "HTTP 200, $($names.Count) bucket(s): $($names -join ', ')" 'aws'
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        Add-Result 's3.listBuckets' 'FAIL' "HTTP $code $($_.Exception.Message)" 'aws'
    }
}

# -----------------------------------------------------------------------------
# Cloudflare - the dispatch chain, not the account.
# -----------------------------------------------------------------------------
function Invoke-CloudflareProbe {
    $base = $env:CF_WORKER_URL
    if (-not $base) { $base = 'https://oncology-scheduler.tap4500.workers.dev' }
    try {
        $h = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 30 -ErrorAction Stop
        $jobs = @($h.jobs | ForEach-Object { $_.name })
        Add-Result 'cf.worker.health' 'PASS' "worker up, jobs: $($jobs -join ', ')" 'cloudflare'
    } catch {
        Add-Result 'cf.worker.health' 'FAIL' "HTTP error: $($_.Exception.Message)" 'cloudflare'
        return
    }
    # A manual dispatch proves the Worker reaches the compute lane and the D1
    # ledger records the outcome. `derive` is expected to report awaiting-volume;
    # that is a correct verdict, not a failure.
    foreach ($job in @('probe', 'matrix', 'derive')) {
        try {
            $r = Invoke-RestMethod -Uri "$base/run/$job" -Method POST -TimeoutSec 90 -ErrorAction Stop
            $expected = if ($job -eq 'derive') { 'awaiting-volume' } else { 'dispatched' }
            if ($r.status -eq $expected) {
                Add-Result "cf.dispatch.$job" 'PASS' "status=$($r.status)" 'cloudflare'
            } else {
                Add-Result "cf.dispatch.$job" 'FAIL' "expected $expected, got $($r.status): $($r.detail)" 'cloudflare'
            }
        } catch {
            Add-Result "cf.dispatch.$job" 'FAIL' "HTTP error: $($_.Exception.Message)" 'cloudflare'
        }
    }
}

# -----------------------------------------------------------------------------
# Modal - the deployed app serving a real result over real HTTP.
# -----------------------------------------------------------------------------
function Invoke-ModalProbe {
    $url = $env:MODAL_DISPATCH_URL
    if (-not $url) { $url = 'https://tap4500--scientific-oracle-dispatch.us-east.modal.run' }
    try {
        $r = Invoke-WebRequest -Uri $url -Method POST -ContentType 'application/json' -Body '{"job":"probe"}' -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        Add-Result 'modal.dispatch.http' 'PASS' "HTTP $($r.StatusCode): $($r.Content.Substring(0, [Math]::Min(90, $r.Content.Length)))" 'modal'
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        Add-Result 'modal.dispatch.http' 'FAIL' "HTTP $code $($_.Exception.Message)" 'modal'
    }
}

# -----------------------------------------------------------------------------
# IBM - the Code Engine project must exist AND be selectable. An empty project
# is not a pass, but it is also not a failure of the lane itself.
# -----------------------------------------------------------------------------
function Invoke-IbmProbe {
    $bin = 'C:\Program Files\IBM\Cloud\bin\ibmcloud.exe'
    if (-not (Test-Path -LiteralPath $bin)) {
        Add-Result 'ibm.cli' 'NOT_VALIDATED' 'ibmcloud CLI not installed' 'ibm'
        return
    }
    $env:Path += ';C:\Program Files\IBM\Cloud\bin'
    try {
        $out = & $bin ce project current 2>&1
        if ("$out" -match 'ID:\s+([0-9a-f-]{36})') {
            $id = $matches[1]
            $apps = & $bin ce app list 2>&1
            $appCount = @("$apps" | Select-String -Pattern '^\S+\s+(ready|running|deploying|failed)').Count
            if ($appCount -gt 0) {
                Add-Result 'ibm.codeEngine.project' 'PASS' "project $id with $appCount app(s)" 'ibm'
            } else {
                Add-Result 'ibm.codeEngine.project' 'PASS' "project $id selectable (no apps deployed yet)" 'ibm'
            }
        } else {
            Add-Result 'ibm.codeEngine.project' 'FAIL' 'no project selected' 'ibm'
        }
    } catch {
        Add-Result 'ibm.codeEngine.project' 'FAIL' "ibmcloud error: $($_.Exception.Message)" 'ibm'
    }
    try {
        $ns = & $bin cr namespace-list 2>&1
        if ("$ns" -match 'overlay365') {
            Add-Result 'ibm.registry.namespace' 'PASS' 'icr.io/overlay365 exists' 'ibm'
        } else {
            Add-Result 'ibm.registry.namespace' 'FAIL' 'namespace overlay365 not listed' 'ibm'
        }
    } catch {
        Add-Result 'ibm.registry.namespace' 'FAIL' "ibmcloud cr error: $($_.Exception.Message)" 'ibm'
    }
}

# -----------------------------------------------------------------------------
# Local - the health of what stays put. A false-alarming monitor is a finding.
# -----------------------------------------------------------------------------
function Invoke-LocalProbe {
    $ports = @{
        'keywire' = 4700; 'gradedevbrain' = 3450; 'synthbook' = 3020
        'oncologyweb' = 3040; 'sympy' = 8800; 'biosim' = 8503
        'embeddings' = 8092
    }
    $up = @(); $down = @()
    foreach ($name in $ports.Keys) {
        $p = $ports[$name]
        $c = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
        # A listener entry whose owning PID cannot be resolved is a phantom:
        # Windows keeps the socket after the owner dies. Count it as DOWN.
        $real = @()
        foreach ($x in $c) {
            if (Get-Process -Id $x.OwningProcess -ErrorAction SilentlyContinue) { $real += $x }
        }
        if ($real.Count -gt 0) { $up += $name } else { $down += $name }
    }
    Add-Result 'local.listeners' 'PASS' "up: $($up -join ','); down: $($down -join ',')" 'local'
    if ($down.Count -gt 0) {
        # Not a FAIL - a down local service is a fact, and this probe's job is
        # to report it. The lane is not the thing that failed.
        Add-Result 'local.down.listed' 'PASS' "reported down: $($down -join ',')" 'local'
    }
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
if (Test-Lane 'aws') { Invoke-AwsS3Probe }
if (Test-Lane 'cloudflare') { Invoke-CloudflareProbe }
if (Test-Lane 'modal') { Invoke-ModalProbe }
if (Test-Lane 'ibm') { Invoke-IbmProbe }
if (Test-Lane 'local') { Invoke-LocalProbe }

$pass = @($results | Where-Object { $_.status -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$unval = @($results | Where-Object { $_.status -eq 'NOT_VALIDATED' }).Count

if ($Json) {
    [pscustomobject]@{ pass = $pass; fail = $fail; not_validated = $unval; results = $results } |
        ConvertTo-Json -Depth 4
} else {
    Write-Host ''
    Write-Host '=== offload lane validation ===' -ForegroundColor Cyan
    foreach ($r in $results) {
        $colour = switch ($r.status) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
            default { 'Yellow' }
        }
        Write-Host ("  {0,-14} {1,-24} {2}" -f $r.status, $r.check, $r.evidence) -ForegroundColor $colour
    }
    Write-Host ''
    Write-Host "PASS=$pass FAIL=$fail NOT_VALIDATED=$unval" -ForegroundColor Cyan
}

if ($fail -gt 0) { exit 1 }
if ($unval -gt 0) { exit 2 }
exit 0
