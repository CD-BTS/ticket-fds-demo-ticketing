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

# ---------------------------------------------------------------- #53 QR 검표: 브라우저 기기 역할
# 실제 프론트엔드(src/device/totp.ts, api/tickets.ts)와 같은 방식으로 키·QR·챌린지 응답을 만든다.
# 서버의 인증·서명 검증은 그대로 거친다. 개인키는 이 프로세스 밖으로 나가지 않는다.
function ConvertTo-B64Url([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function ConvertFrom-B64Url([string]$Text) {
    $t = $Text.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    , [Convert]::FromBase64String($t)
}

# ECDSA P-256 키 쌍. 공개키는 SPKI DER(고정 26바이트 헤더 + 0x04||X||Y)의 base64url이다.
function New-TicketDevice {
    $key = [System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::ECDsaP256)
    $blob = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)   # 8바이트 헤더 + X(32) + Y(32)
    $prefix = '3059301306072a8648ce3d020106082a8648ce3d030107034200'
    $spki = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $prefix.Length; $i += 2) { $spki.Add([Convert]::ToByte($prefix.Substring($i, 2), 16)) }
    $spki.Add(4); $spki.AddRange([byte[]]$blob[8..71])
    [pscustomobject]@{
        Ecdsa = (New-Object System.Security.Cryptography.ECDsaCng($key)); PublicKey = (ConvertTo-B64Url $spki.ToArray())
        DeviceId = $null; Secret = $null
    }
}

# SHA-256 ECDSA 서명. ECDsaCng는 Web Crypto와 같은 r||s 64바이트를 돌려준다.
function Get-DeviceSignature($Device, [string]$Text) {
    ConvertTo-B64Url ($Device.Ecdsa.SignData([System.Text.Encoding]::UTF8.GetBytes($Text), [System.Security.Cryptography.HashAlgorithmName]::SHA256))
}

# RFC 6238 TOTP (HMAC-SHA1, 6자리, 30초)
function Get-Totp([byte[]]$Secret, [long]$EpochSeconds) {
    $message = [BitConverter]::GetBytes([long][Math]::Floor($EpochSeconds / 30)); [Array]::Reverse($message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (, $Secret)
    $hash = $hmac.ComputeHash($message); $hmac.Dispose()
    $o = $hash[19] -band 0x0f
    $binary = (([int]$hash[$o] -band 0x7f) -shl 24) -bor ([int]$hash[$o + 1] -shl 16) -bor ([int]$hash[$o + 2] -shl 8) -bor [int]$hash[$o + 3]
    '{0:D6}' -f ($binary % 1000000)
}

function Get-EpochSeconds { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# QR 내용: BTS1.<ticketId>.<deviceId>.<epochSeconds>.<totp>.<signature>
function New-TicketQr($Device, [string]$TicketId, [long]$EpochSeconds = (Get-EpochSeconds), [string]$Totp = $null) {
    if (-not $Totp) { $Totp = Get-Totp $Device.Secret $EpochSeconds }
    $body = "BTS1.$TicketId.$($Device.DeviceId).$EpochSeconds.$Totp"
    "$body.$(Get-DeviceSignature $Device $body)"
}

# 기기 등록: 일회성 챌린지에 서명해 개인키 소유를 증명하고 TOTP 비밀키를 받는다.
function Register-TicketDevice($Device, [string]$TicketId, [string]$Token) {
    $challenge = (Demo POST "/tickets/$TicketId/device-challenges" @{} $Token).Data
    $proof = Get-DeviceSignature $Device "BTS-DEVICE-REGISTER.$TicketId.$($challenge.challenge).$($Device.PublicKey)"
    $enrolled = (Demo POST "/tickets/$TicketId/device" @{ challengeId = $challenge.challengeId; publicKey = $Device.PublicKey; proof = $proof } $Token).Data
    $Device.DeviceId = $enrolled.deviceId
    $Device.Secret = ConvertFrom-B64Url $enrolled.totp.secret
    $enrolled
}

# 검표 챌린지 응답 서명 (프론트엔드 checkInMessage와 같은 문자열)
function Get-CheckInProof($Device, [string]$TicketId, [string]$CheckInId, [string]$Challenge) {
    Get-DeviceSignature $Device "BTS-CHECKIN.$TicketId.$($Device.DeviceId).$CheckInId.$Challenge"
}

# 검표기 요청 (X-Gate-Key)
function Gate([string]$Method, [string]$Path, $Body = $null, [int[]]$Expect = @(200, 201)) {
    Demo $Method $Path $Body $null @{ 'X-Gate-Key' = $script:E2E.gateKey } $Expect
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    Write-Output ("[{0}] {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}
