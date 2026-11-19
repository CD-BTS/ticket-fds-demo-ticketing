# #47 Demo–BTS 통합 시나리오 환경 기동.
# 1) e2e/compose.yaml의 일회성 DB(BTS MySQL 3317, Demo MySQL 3318, Redis 6390)를 띄우고
# 2) 이번 실행에서만 쓰는 테스트 API 키를 만들어
# 3) BTS(ticket-fds-admin, 18080)와 Demo(18081) 백엔드를 백그라운드로 실행한다.
# 키는 e2e/.run/keys.json(커밋 제외)에만 저장되고, 로그는 e2e/.run/*.log에 남는다.
param(
    [string]$AdminRepo = (Join-Path $PSScriptRoot '..\..\ticket-fds-admin'),
    [int]$BtsPort = 18080,
    [int]$DemoPort = 18081,
    [switch]$SkipCompose,
    # 장애 시나리오에서 BTS만 다시 띄울 때: -Only bts -SkipCompose (기존 키 재사용)
    [ValidateSet('all', 'bts', 'demo')][string]$Only = 'all'
)
$ErrorActionPreference = 'Stop'
$AdminRepo = (Resolve-Path $AdminRepo).Path
$demoRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$run = Join-Path $PSScriptRoot '.run'
New-Item -ItemType Directory -Force $run | Out-Null

function New-TestKey { -join ((1..40) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
function Get-Sha256Hex([string]$value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value)) | ForEach-Object { $_.ToString('x2') })
}

if (-not $SkipCompose) {
    $env:ADMIN_REPO = $AdminRepo
    # docker는 진행 상황을 stderr로 쓰므로 Stop 모드에서 오류로 취급되지 않게 한다.
    $ErrorActionPreference = 'Continue'
    docker compose -f (Join-Path $PSScriptRoot 'compose.yaml') up -d --wait 2>&1 | Out-Host
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw 'e2e DB 컨테이너 기동 실패' }
}

$keyFile = Join-Path $run 'keys.json'
if ($Only -ne 'all' -and (Test-Path $keyFile)) {
    $keys = Get-Content -Raw $keyFile | ConvertFrom-Json
    $serviceKey = $keys.serviceKey; $adminKey = $keys.adminKey
} else {
    $serviceKey = 'e2e-svc-' + (New-TestKey)
    $adminKey = 'e2e-admin-' + (New-TestKey)
    $keys = [ordered]@{
        serviceId = 'demo-ticketing'; serviceKey = $serviceKey; adminKey = $adminKey
        btsUrl = "http://localhost:$BtsPort"; demoUrl = "http://localhost:$DemoPort"
    }
    $keys | ConvertTo-Json | Set-Content -Encoding UTF8 $keyFile
}

# --- BTS (ticket-fds-admin) ---
$btsEnv = @{
    SERVER_PORT = "$BtsPort"
    DB_URL = 'jdbc:mysql://127.0.0.1:3317/fairticket_db?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8'  # admin README 기준 URL (JVM이 KST인 개발 PC 가정)
    DB_USERNAME = 'bts_e2e'; DB_PASSWORD = 'bts-e2e-only'; JPA_SHOW_SQL = 'false'
    BTS_API_KEY_HASHES = (@{ 'demo-ticketing' = (Get-Sha256Hex $serviceKey) } | ConvertTo-Json -Compress)
    BTS_ADMIN_API_KEYS = ('[{"hash":"' + (Get-Sha256Hex $adminKey) + '","allServices":true,"services":[]}]')
}
# --- Demo ---
$demoEnv = @{
    SERVER_PORT = "$DemoPort"; DB_HOST = '127.0.0.1'; DB_PORT = '3318'; DB_USERNAME = 'demo_e2e'; DB_PASSWORD = 'demo-e2e-only'
    REDIS_HOST = '127.0.0.1'; REDIS_PORT = '6390'; QUEUE_KEY_PREFIX = 'e2e:queue'
    BOOKING_ATTEMPTS_ENABLED = 'true'; DEMO_JOBS_ENABLED = 'true'; CHECKIN_ENABLED = 'false'
    BTS_ENABLED = 'true'; BTS_BASE_URL = "http://localhost:$BtsPort"; BTS_SERVICE_ID = 'demo-ticketing'; BTS_API_KEY = $serviceKey
    BTS_CONCERT_SYNC_MS = '60000'; POLICY_DECISION_MODE = 'bts'; CAPTCHA_MODE = 'disabled'
}

function Start-Backend([string]$name, [string]$dir, [hashtable]$vars) {
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        $log = Join-Path $run "$name.log"
        $p = Start-Process -FilePath (Join-Path $dir 'gradlew.bat') -ArgumentList 'bootRun', '--console=plain' `
            -WorkingDirectory $dir -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
        Set-Content -Path (Join-Path $run "$name.pid") -Value $p.Id
        Write-Output "$name 시작 (pid $($p.Id), 로그 $log)"
    } finally {
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
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

if ($Only -ne 'demo') {
    Start-Backend 'bts' (Join-Path $AdminRepo 'backend') $btsEnv
    if (-not (Wait-Http "http://localhost:$BtsPort/api/v1/users" 240)) { throw "BTS 서버가 응답하지 않습니다. $run\bts.log 확인" }
}
if ($Only -ne 'bts') {
    Start-Backend 'demo' (Join-Path $demoRepo 'backend') $demoEnv
    if (-not (Wait-Http "http://localhost:$DemoPort/api/v1/concerts" 240)) { throw "Demo 서버가 응답하지 않습니다. $run\demo.log 확인" }
}
Write-Output "준비 완료: BTS $($keys.btsUrl), Demo $($keys.demoUrl)"
