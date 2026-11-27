# #71 Showcase 환경 기동. e2e/Start-E2E.ps1과 같은 방식(Docker DB + gradlew bootRun)이며, 다음이 다르다.
#  - DB·Redis는 named volume에 저장되어 Stop 후에도 데이터가 남는다.
#  - API 키·검표 키·티켓 서명 키는 처음 한 번 만들어 .run/secrets.json에 두고 재시작해도 그대로 쓴다.
#  - ticket-fds-ai를 컨테이너로 함께 띄우고 BTS의 AI 평가 스케줄러를 켠다.
#  - 사용자별 IP 분리를 위해 Demo가 루프백 프록시(이 PC)의 X-Forwarded-For를 믿도록 한다(TRUSTED_PROXIES, Showcase 전용).
#  - 두 프론트엔드(Vite dev server)도 함께 띄운다.
param(
    [string]$AdminRepo = '',
    [string]$AiRepo = '',
    # bts / demo / web 만 (재)기동할 때. 이미 실행 중인 프로세스는 건너뛴다 (-Restart로 강제 재기동).
    [ValidateSet('all', 'bts', 'demo', 'web')][string]$Only = 'all',
    [switch]$Restart,
    # 대량 이력 적재 중에는 AI 평가를 끈 채 BTS를 띄운다 (Seed-Showcase.ps1이 사용). 평소에는 쓰지 않는다.
    [switch]$AiOff,
    [switch]$NoWeb,
    [switch]$SkipCompose
)
. (Join-Path $PSScriptRoot 'Showcase-Common.ps1')
$AdminRepo = Get-RepoPath 'ADMIN_REPO' $AdminRepo @('ticket-fds-admin', 'admin')
$AiRepo = Get-RepoPath 'AI_REPO' $AiRepo @('ticket-fds-ai', 'ai')
$demoRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$secrets = Get-ShowcaseSecrets -CreateIfMissing

if (-not $SkipCompose -and $Only -eq 'all') {
    $env:ADMIN_REPO = $AdminRepo; $env:AI_REPO = $AiRepo
    if (-not (Test-Path (Join-Path $AdminRepo 'backend\db\schema.sql'))) { throw "ticket-fds-admin 경로가 올바르지 않습니다: $AdminRepo" }
    if (-not (Test-Path (Join-Path $AiRepo 'train_fds_model.py'))) { throw "ticket-fds-ai 경로가 올바르지 않거나 최신 dev가 아닙니다 (train_fds_model.py 없음): $AiRepo" }
    $ErrorActionPreference = 'Continue'
    docker compose -f (Join-Path $PSScriptRoot 'compose.yaml') up -d --build --wait 2>&1 | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw 'Showcase 컨테이너 기동 실패 (docker compose 로그 확인)' }
    # Showcase 전용 성능 인덱스. BTS의 결제수단 공유·IP 밀집도·최근 IP 시도 집계는 behavior_event를 서비스 단위로 훑는데
    # (BehaviorEventRepository), 시연 규모(약 39만 건)에서는 사용자 1명 평가에 수 초가 걸려 전체 평가가 끝나지 않는다.
    # 인덱스는 조회 결과를 바꾸지 않는다. admin schema.sql·Dev·E2E DB에는 적용하지 않는다.
    #  - (service_id, event_type, occurred_at): 결제수단 공유·IP 밀집도(30일 BOOKING) 집계
    #  - (event_type, occurred_at): 최근 10분 IP 시도 집계. service_id가 조인 조건이라 위 인덱스를 못 써 전체를 훑는다.
    foreach ($ixDef in @(@('ix_showcase_event_type_time', 'service_id, event_type, occurred_at'), @('ix_showcase_type_time', 'event_type, occurred_at'))) {
        $ix = @(Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='behavior_event' AND index_name='$($ixDef[0])'")
        if ([int]$ix[0].n -eq 0) {
            Invoke-ShowcaseSql bts "CREATE INDEX $($ixDef[0]) ON behavior_event ($($ixDef[1]))" | Out-Null
            Write-Output "BTS DB: Showcase 성능 인덱스 생성 ($($ixDef[0]))"
        }
    }
}

$aiUrl = "http://127.0.0.1:$($SC.AiPort)"
$btsEnv = @{
    SERVER_PORT = "$($SC.BtsPort)"
    DB_URL = "jdbc:mysql://127.0.0.1:$($SC.BtsMysql.Port)/fairticket_db?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8"
    DB_USERNAME = $SC.BtsMysql.User; DB_PASSWORD = $SC.BtsMysql.Password; JPA_SHOW_SQL = 'false'
    BTS_API_KEY_HASHES = (@{ $secrets.serviceId = (Get-Sha256Hex $secrets.serviceKey) } | ConvertTo-Json -Compress)
    BTS_ADMIN_API_KEYS = ('[{"hash":"' + (Get-Sha256Hex $secrets.adminKey) + '","allServices":true,"services":[]}]')
    # 실제 AI 평가 스케줄러. 주기만 줄이고(기본 60초) 한 번에 평가할 사용자 수를 늘린다(기본 500). 모델·임계값은 그대로.
    AI_ENABLED = $(if ($AiOff) { 'false' } else { 'true' }); AI_BASE_URL = $aiUrl; AI_POLL_MS = '5000'; AI_MAX_USERS_PER_RUN = '1000'
}
# 시연 사용자(대표 계정) 전용 테스트 결제 식별자. 기본 3개만 있으면 정상 사용자끼리 결제수단을 공유하게 된다.
$payIds = @('test-pay-shared-01', 'test-pay-shared-02', 'test-pay-shared-03') + (1..300 | ForEach-Object { 'sc-live-pay-{0:D3}' -f $_ })
$demoEnv = @{
    SERVER_PORT = "$($SC.DemoPort)"; DB_HOST = '127.0.0.1'; DB_PORT = "$($SC.DemoMysql.Port)"
    DB_USERNAME = $SC.DemoMysql.User; DB_PASSWORD = $SC.DemoMysql.Password
    REDIS_HOST = '127.0.0.1'; REDIS_PORT = "$($SC.RedisPort)"; QUEUE_KEY_PREFIX = 'showcase:queue'
    BOOKING_ATTEMPTS_ENABLED = 'true'; DEMO_JOBS_ENABLED = 'true'
    CHECKIN_ENABLED = 'true'; TICKET_SECRET_KEY = $secrets.ticketSecret; GATE_API_KEY = $secrets.gateKey
    # 시연용: 예매 진행 중 공연(수일~수주 뒤)의 티켓으로 QR 검표를 보여 주기 위해 입장 가능 시작을 넓힌다(E2E는 P365D).
    CHECKIN_OPENS_BEFORE = 'P60D'
    BTS_ENABLED = 'true'; BTS_BASE_URL = "http://localhost:$($SC.BtsPort)"; BTS_SERVICE_ID = $secrets.serviceId; BTS_API_KEY = $secrets.serviceKey
    BTS_CONCERT_SYNC_MS = '60000'; POLICY_DECISION_MODE = 'bts'; CAPTCHA_MODE = 'mock'
    # 이 PC(루프백)에서 오는 요청만 X-Forwarded-For를 읽는다. 시연 스크립트가 사용자별 IP를 실어 보낸다.
    TRUSTED_PROXIES = '127.0.0.1,::1'
    TEST_PAYMENT_IDENTIFIERS = ($payIds -join ',')
}

function Start-Logged([string]$name, [string]$file, [string[]]$arguments, [string]$dir, [hashtable]$vars) {
    if (Test-ProcessAlive $name) {
        if (-not $Restart) { Write-Output "$name 이미 실행 중 (pid $(Get-Content (Join-Path $RunDir "$name.pid")))"; return $false }
        & taskkill.exe /PID ([int](Get-Content (Join-Path $RunDir "$name.pid"))) /T /F 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try {
        $log = Join-Path $RunDir "$name.log"
        $p = Start-Process -FilePath $file -ArgumentList $arguments -WorkingDirectory $dir `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
        Set-Content -Path (Join-Path $RunDir "$name.pid") -Value $p.Id
        Write-Output "$name 시작 (pid $($p.Id), 로그 $log)"
    } finally {
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    return $true
}

if ($Only -in @('all', 'bts')) {
    if ($AiOff) { Write-Output 'BTS: AI 평가 스케줄러 꺼짐 (대량 적재 모드)' }
    Start-Logged 'bts' (Join-Path $AdminRepo 'backend\gradlew.bat') @('bootRun', '--console=plain') (Join-Path $AdminRepo 'backend') $btsEnv | Out-Null
    if (-not (Wait-Http "http://localhost:$($SC.BtsPort)/api/v1/users" 300)) { throw "BTS 서버가 응답하지 않습니다. $RunDir\bts.log 확인" }
    Set-Content -Path (Join-Path $RunDir 'bts.mode') -Value $(if ($AiOff) { 'ai-off' } else { 'ai-on' })
}
if ($Only -in @('all', 'demo')) {
    Start-Logged 'demo' (Join-Path $demoRepo 'backend\gradlew.bat') @('bootRun', '--console=plain') (Join-Path $demoRepo 'backend') $demoEnv | Out-Null
    if (-not (Wait-Http "http://localhost:$($SC.DemoPort)/api/v1/concerts" 300)) { throw "Demo 서버가 응답하지 않습니다. $RunDir\demo.log 확인" }
}
if (-not $NoWeb -and $Only -in @('all', 'web')) {
    foreach ($web in @(
            @{ Name = 'demo-web'; Dir = (Join-Path $demoRepo 'frontend'); Port = $SC.DemoWebPort; Vars = @{ DEMO_API_TARGET = "http://localhost:$($SC.DemoPort)" } },
            @{ Name = 'admin-web'; Dir = (Join-Path $AdminRepo 'frontend'); Port = $SC.AdminWebPort; Vars = @{ VITE_API_PROXY_TARGET = "http://localhost:$($SC.BtsPort)" } })) {
        if (-not (Test-Path (Join-Path $web.Dir 'node_modules'))) {
            Write-Output "$($web.Name): node_modules가 없어 npm ci 실행 ($($web.Dir))"
            # npm은 경고를 stderr로 쓰므로 Stop 모드에서 오류로 취급되지 않게 한다.
            Push-Location $web.Dir; $ErrorActionPreference = 'Continue'
            try { & npm.cmd ci --no-audit --no-fund 2>&1 | Out-Host; $npmCode = $LASTEXITCODE } finally { $ErrorActionPreference = 'Stop'; Pop-Location }
            if ($npmCode -ne 0) { throw "$($web.Name): npm ci 실패" }
        }
        Start-Logged $web.Name 'cmd.exe' @('/c', 'npm.cmd', 'run', 'dev', '--', '--port', "$($web.Port)", '--strictPort') $web.Dir $web.Vars | Out-Null
    }
    if (-not (Wait-Http "http://localhost:$($SC.DemoWebPort)/" 120)) { Write-Warning "티켓팅 화면이 응답하지 않습니다. $RunDir\demo-web.log 확인" }
    if (-not (Wait-Http "http://localhost:$($SC.AdminWebPort)/" 120)) { Write-Warning "관리자 화면이 응답하지 않습니다. $RunDir\admin-web.log 확인" }
}

Write-Output ''
Write-Output "준비 완료"
Write-Output "  티켓팅 화면     http://localhost:$($SC.DemoWebPort)"
Write-Output "  관리자 대시보드 http://localhost:$($SC.AdminWebPort)  (서비스 ID: $($secrets.serviceId), 관리자 키: .run\secrets.json 의 adminKey)"
Write-Output "  BTS API $($SC.BtsPort) · Demo API $($SC.DemoPort) · AI $aiUrl"
