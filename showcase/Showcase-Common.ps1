# Showcase 스크립트 공통 설정·함수. 각 스크립트가 dot-source 한다.
# e2e/E2E-Common.ps1의 함수(Invoke-Api, Demo, Bts, QR 기기 함수 등)를 그 파일을 고치지 않고 재사용한다:
# 파일을 구문 분석해 함수 정의만 가져오고, 최상위 문장(e2e 키 파일 읽기)은 실행하지 않는다.
$ErrorActionPreference = 'Stop'
# docker·python 출력(한글 사유·공연명 등)을 UTF-8로 읽는다. Windows PowerShell 5.1 기본값(시스템 코드 페이지)이면 깨진다.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:ShowcaseDir = $PSScriptRoot
$script:RunDir = Join-Path $PSScriptRoot '.run'
New-Item -ItemType Directory -Force $script:RunDir | Out-Null

# 포트·이름. Dev(8080/8081, 3307/3308, 6380)와 E2E(18080/18081, 3317/3318, 6390)와 겹치지 않는다.
$script:SC = [ordered]@{
    Project = 'cdbts-showcase'
    BtsPort = 28080; DemoPort = 28081; AiPort = 8010
    DemoWebPort = 5183; AdminWebPort = 5184
    BtsMysql = @{ Container = 'cdbts-showcase-bts-mysql'; User = 'bts_showcase'; Password = 'bts-showcase-only'; Db = 'fairticket_db'; Port = 3327 }
    DemoMysql = @{ Container = 'cdbts-showcase-demo-mysql'; User = 'demo_showcase'; Password = 'demo-showcase-only'; Db = 'demo_ticketing_db'; Port = 3328 }
    RedisPort = 6391
    ServiceId = 'demo-ticketing'
}

function Get-RepoPath([string]$Name, [string]$Override, [string[]]$Candidates) {
    if ($Override) { return (Resolve-Path $Override).Path }
    $envValue = [Environment]::GetEnvironmentVariable($Name)
    if ($envValue) { return (Resolve-Path $envValue).Path }
    $parent = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach ($c in $Candidates) { $p = Join-Path $parent $c; if (Test-Path $p) { return (Resolve-Path $p).Path } }
    throw "$Name 경로를 찾을 수 없습니다. 환경변수 $Name 또는 -$($Name -replace '_','') 매개변수로 지정하세요. (찾은 위치: $parent\{$($Candidates -join ',')})"
}

function Get-Sha256Hex([string]$value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value)) | ForEach-Object { $_.ToString('x2') })
}
function New-RandomHex([int]$Bytes = 20) {
    $b = New-Object byte[] $Bytes; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

# 인증 정보는 처음 한 번 만들고 .run/secrets.json(커밋 제외)에 보관한다. 재시작해도 같은 키를 쓴다.
# (E2E는 실행마다 새 키를 만들지만, Showcase는 등록된 기기·발급된 티켓·관리자 로그인이 재시작 후에도 유효해야 한다.)
$script:SecretFile = Join-Path $script:RunDir 'secrets.json'
function Get-ShowcaseSecrets([switch]$CreateIfMissing) {
    if (Test-Path $script:SecretFile) { return (Get-Content -Raw -Encoding UTF8 $script:SecretFile | ConvertFrom-Json) }
    if (-not $CreateIfMissing) { throw "인증 정보가 없습니다. 먼저 .\Start-Showcase.ps1 을 실행하세요. ($script:SecretFile)" }
    $ticket = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($ticket)
    $s = [ordered]@{
        serviceId = $script:SC.ServiceId
        serviceKey = 'sc-svc-' + (New-RandomHex); adminKey = 'sc-admin-' + (New-RandomHex)
        gateKey = 'sc-gate-' + (New-RandomHex); ticketSecret = [Convert]::ToBase64String($ticket)
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $s | ConvertTo-Json | Set-Content -Encoding UTF8 $script:SecretFile
    return (Get-Content -Raw -Encoding UTF8 $script:SecretFile | ConvertFrom-Json)
}

# e2e/E2E-Common.ps1에서 함수 정의만 가져온다 (Invoke-Api, Demo, Bts, New-Uuid, Wait-Until, QR·TOTP·기기 함수, Check).
function Import-E2EFunctions {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'e2e\E2E-Common.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "E2E-Common.ps1 구문 분석 실패: $($errors[0])" }
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        Where-Object { $_.Name -ne 'Invoke-Sql' } | ForEach-Object { $_.Extent.Text }
}
foreach ($def in (Import-E2EFunctions)) { . ([scriptblock]::Create($def)) }
$script:Results = New-Object System.Collections.Generic.List[object]

# E2E 함수가 읽는 $script:E2E를 Showcase 값으로 채운다.
function Use-ShowcaseApi {
    $s = Get-ShowcaseSecrets
    $script:E2E = [pscustomobject]@{
        serviceId = $s.serviceId; serviceKey = $s.serviceKey; adminKey = $s.adminKey; gateKey = $s.gateKey
        btsUrl = "http://localhost:$($script:SC.BtsPort)"; demoUrl = "http://localhost:$($script:SC.DemoPort)"
        aiUrl = "http://127.0.0.1:$($script:SC.AiPort)"
    }
}

# Showcase 컨테이너 전용 SQL 조회 (E2E의 Invoke-Sql은 e2e 컨테이너 이름이 고정이라 따로 둔다).
function Invoke-ShowcaseSql([ValidateSet('bts', 'demo')][string]$Db, [string]$Sql) {
    $c = if ($Db -eq 'bts') { $script:SC.BtsMysql } else { $script:SC.DemoMysql }
    $out = docker exec -e "MYSQL_PWD=$($c.Password)" $c.Container mysql "-u$($c.User)" $c.Db --batch --default-character-set=utf8mb4 -e $Sql 2>$null
    if ($LASTEXITCODE -ne 0) { throw "SQL 실패 ($Db): $Sql" }
    $out | ConvertFrom-Csv -Delimiter "`t"
}

function Test-ProcessAlive([string]$Name) {
    $pidFile = Join-Path $script:RunDir "$Name.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $id = [int](Get-Content $pidFile)
    return [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
}

function Wait-Http([string]$url, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3 | Out-Null; return $true }
        catch { if ($_.Exception.Response) { return $true } }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-PythonCommand {
    foreach ($c in @('python', 'py')) { if (Get-Command $c -ErrorAction SilentlyContinue) { return $c } }
    throw 'Python 3.10+ 가 필요합니다 (PATH에서 python 또는 py를 찾지 못함).'
}

# 재시작 후에도 같은 기기로 QR을 만들 수 있도록 내보낼 수 있는 키로 기기를 만든다 (E2E의 New-TicketDevice와 같은 형식).
# 키·TOTP 비밀키는 .run/live-state.json(커밋 제외)에만 저장한다. 서버의 서명·TOTP 검증은 그대로 거친다.
function New-PersistentTicketDevice([string]$PrivateBlob = $null) {
    if ($PrivateBlob) {
        $key = [System.Security.Cryptography.CngKey]::Import([Convert]::FromBase64String($PrivateBlob), [System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
    } else {
        $p = New-Object System.Security.Cryptography.CngKeyCreationParameters
        $p.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        # 이름은 반드시 진짜 null이어야 한다(임시 키). PowerShell은 $null을 문자열 인수로 넘길 때 ""로 바꿔, 이름 ""인 영구 키가 생긴다.
        $key = [System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::ECDsaP256, [NullString]::Value, $p)
    }
    $blob = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    $prefix = '3059301306072a8648ce3d020106082a8648ce3d030107034200'
    $spki = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $prefix.Length; $i += 2) { $spki.Add([Convert]::ToByte($prefix.Substring($i, 2), 16)) }
    $spki.Add(4); $spki.AddRange([byte[]]$blob[8..71])
    [pscustomobject]@{
        Ecdsa = (New-Object System.Security.Cryptography.ECDsaCng($key)); PublicKey = (ConvertTo-B64Url $spki.ToArray())
        DeviceId = $null; Secret = $null
        PrivateBlob = $(if ($PrivateBlob) { $PrivateBlob } else { [Convert]::ToBase64String($key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)) })
    }
}
function Restore-TicketDevice($Saved) {
    $d = New-PersistentTicketDevice $Saved.privateBlob
    $d.DeviceId = $Saved.deviceId; $d.Secret = ConvertFrom-B64Url $Saved.secret
    $d
}