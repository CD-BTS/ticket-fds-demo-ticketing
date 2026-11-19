# 시나리오 스크립트 공통 함수. Start-E2E.ps1이 만든 .run/keys.json을 읽는다.
$ErrorActionPreference = 'Stop'
$script:E2E = Get-Content -Raw (Join-Path $PSScriptRoot '.run\keys.json') | ConvertFrom-Json

function Invoke-Api {
    param([string]$Method, [string]$Url, $Body = $null, [hashtable]$Headers = @{}, [int[]]$Expect = @(200, 201))
    $params = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 15 }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    }
    try {
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode; $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $status = [int]$resp.StatusCode
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    }
    $json = if ($text) { $text | ConvertFrom-Json } else { $null }
    if ($Expect -notcontains $status) { throw "$Method $Url -> $status $text" }
    [pscustomobject]@{ Status = $status; Code = $json.code; Data = $json.data }
}

function Demo([string]$Method, [string]$Path, $Body = $null, [string]$Token = $null, [hashtable]$Headers = @{}, [int[]]$Expect = @(200, 201)) {
    $h = @{} + $Headers
    if ($Token) { $h.Authorization = "Bearer $Token" }
    Invoke-Api $Method ($script:E2E.demoUrl + '/api/v1' + $Path) $Body $h $Expect
}

function Bts([string]$Method, [string]$Path, $Body = $null, [switch]$Admin, [int[]]$Expect = @(200, 201)) {
    $key = if ($Admin) { $script:E2E.adminKey } else { $script:E2E.serviceKey }
    Invoke-Api $Method ($script:E2E.btsUrl + '/api/v1' + $Path) $Body @{ 'X-API-Key' = $key } $Expect
}

function New-Uuid { [guid]::NewGuid().ToString() }

function Invoke-Sql([ValidateSet('bts', 'demo')][string]$Db, [string]$Sql) {
    if ($Db -eq 'bts') { $c = 'cdbts-e2e-bts-mysql'; $u = 'bts_e2e'; $p = 'bts-e2e-only'; $d = 'fairticket_db' }
    else { $c = 'cdbts-e2e-demo-mysql'; $u = 'demo_e2e'; $p = 'demo-e2e-only'; $d = 'demo_ticketing_db' }
    $out = docker exec -e "MYSQL_PWD=$p" $c mysql "-u$u" $d --batch --default-character-set=utf8mb4 -e $Sql 2>$null
    if ($LASTEXITCODE -ne 0) { throw "SQL 실패 ($Db): $Sql" }
    $out | ConvertFrom-Csv -Delimiter "`t"
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 60, [string]$What = '조건') {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $v = & $Condition
        if ($v) { return $v }
        Start-Sleep -Seconds 2
    }
    throw "$What 대기 시간 초과 (${Seconds}s)"
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    Write-Output ("[{0}] {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}
