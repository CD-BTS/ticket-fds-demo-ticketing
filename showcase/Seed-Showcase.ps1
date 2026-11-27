# #71 Showcase 데이터 생성. Start-Showcase.ps1로 환경을 띄운 뒤 실행한다. 단계별로 나눠 실행할 수 있고, 다시 실행해도 중복이 생기지 않는다.
#
#  concerts : 시연 공연 10개(좌석 포함)를 Demo DB에 넣고, Demo의 공연 동기화와 같은 API로 BTS에 등록
#  load     : 과거 28일 합성 행동 이력을 BTS 행동 이벤트 API로 적재 (적재 중에는 BTS AI 평가를 잠시 끈다)
#  evaluate : BTS를 AI 평가 켠 상태로 되돌리고, 실제 스케줄러의 평가·Credit·미입장 판정이 끝날 때까지 cursor로 확인
#  live     : 평가가 끝난 사용자 중 대표 계정으로 실제 Demo API를 호출 (정상 예매·QR 검표, CAPTCHA, DELAY, RESTRICT)
#
# 예) 1차 소규모 검증:  .\Seed-Showcase.ps1 -Users 30
#     규모 확장:        .\Seed-Showcase.ps1 -Users 300 ; .\Seed-Showcase.ps1 -Users 1000 ; .\Seed-Showcase.ps1
param(
    [string[]]$Steps = @('concerts', 'load', 'evaluate', 'live'),
    # 앞에서부터 이 인원(공유 IP·결제수단 그룹 단위)까지만 적재. 생략하면 전체 계획(약 1만 4천 명).
    [int]$Users = 0,
    [int]$Seed = 7171,
    [int]$Workers = 16,
    # 이미 적재한 사용자의 이벤트를 다시 보내 BTS가 모두 200(재전송)으로 처리하는지 확인한다.
    [switch]$Replay,
    # live 단계의 정책별 대표 사용자 수
    [int]$LivePerPolicy = 10
)
. (Join-Path $PSScriptRoot 'Showcase-Common.ps1')
Use-ShowcaseApi
$py = Get-PythonCommand
$tool = Join-Path $PSScriptRoot 'seed\showcase_seed.py'
$secrets = Get-ShowcaseSecrets
$dbJson = {
    param($c) (@{ container = $c.Container; user = $c.User; password = $c.Password; db = $c.Db } | ConvertTo-Json -Compress)
}
$common = @('--seed', "$Seed", '--run-dir', $RunDir, '--bts-url', $E2E.btsUrl)
if ($Users -gt 0) { $common += @('--users', "$Users") }
$env:SHOWCASE_SERVICE_KEY = $secrets.serviceKey
# DB 접속 정보는 환경변수로 넘긴다 (PowerShell 5.1은 네이티브 명령 인수의 큰따옴표를 지워 JSON이 깨진다).
$env:SHOWCASE_DEMO_DB = & $dbJson $SC.DemoMysql
$env:SHOWCASE_BTS_DB = & $dbJson $SC.BtsMysql
$timings = [ordered]@{}

function Invoke-Seed([string[]]$arguments) {
    # Python이 stderr에 쓰는 진행 메시지가 오류로 바뀌지 않도록 Continue로 실행한다.
    $ErrorActionPreference = 'Continue'
    & $py -X utf8 $tool @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "showcase_seed.py $($arguments[0]) 실패 (exit $code)" }
}
function Restart-Bts([switch]$AiOff) {
    $mode = if (Test-Path (Join-Path $RunDir 'bts.mode')) { Get-Content (Join-Path $RunDir 'bts.mode') } else { '' }
    $want = if ($AiOff) { 'ai-off' } else { 'ai-on' }
    if ($mode -eq $want -and (Test-ProcessAlive 'bts')) { return }
    Write-Output "BTS 재기동 ($want)"
    $p = @{ Only = 'bts'; Restart = $true; SkipCompose = $true }
    if ($AiOff) { $p.AiOff = $true }
    & (Join-Path $PSScriptRoot 'Start-Showcase.ps1') @p | Out-Host
}

if ($Steps -contains 'concerts') {
    $t = Get-Date
    Write-Output '== 1. 공연·좌석'
    Invoke-Seed (@('concerts') + $common)
    $timings.concerts = [int]((Get-Date) - $t).TotalSeconds
}

if ($Steps -contains 'load') {
    $t = Get-Date
    Write-Output '== 2. 과거 행동 이력 적재 (BTS 행동 이벤트 API)'
    $dry = (Invoke-Seed (@('load', '--dry-run') + $common + $(if ($Replay) { @('--replay') } else { @() }))) | ConvertFrom-Json
    Write-Output "적재 대상: 사용자 $($dry.pendingUsers)명, 이벤트 $($dry.pendingEvents)건"
    if ($dry.pendingUsers -gt 0) {
        # 적재 중 AI 평가를 끄는 이유: 한 사용자의 이벤트가 절반만 들어온 상태로 평가되면 실제와 다른 Feature로 점수가 매겨진다.
        # 적재가 끝난 뒤 실제 스케줄러가 완성된 이력으로 평가한다(evaluate 단계). 모델·Feature·임계값은 바꾸지 않는다.
        Restart-Bts -AiOff
        Invoke-Seed (@('load', '--workers', "$Workers") + $common + $(if ($Replay) { @('--replay') } else { @() }))
    }
    $timings.load = [int]((Get-Date) - $t).TotalSeconds
}

if ($Steps -contains 'evaluate') {
    $t = Get-Date
    Write-Output '== 3. 실제 AI 평가·Credit 산출·미입장 판정 대기'
    Restart-Bts
    $health = Invoke-RestMethod "$($E2E.aiUrl)/health"
    Write-Output "AI 서버: model=$($health.modelVersion) features=$($health.featureDefinitionVersion) threshold=$($health.anomalyThreshold)"
    Invoke-Seed (@('wait-eval') + $common)
    $timings.evaluate = [int]((Get-Date) - $t).TotalSeconds
}

# ------------------------------------------------------------------ live: 대표 계정의 실제 티켓팅·정책 적용
if ($Steps -contains 'live') {
    $t = Get-Date
    Write-Output '== 4. 대표 계정 실제 티켓팅·정책 적용 (Demo API)'
    $liveFile = Join-Path $RunDir 'live-state.json'
    $live = if (Test-Path $liveFile) { Get-Content -Raw -Encoding UTF8 $liveFile | ConvertFrom-Json } else { [pscustomobject]@{ done = [pscustomobject]@{} } }
    $plan = (Invoke-Seed (@('users') + $common)) | ConvertFrom-Json
    $byExt = @{}; foreach ($u in $plan) { $byExt[$u.ext] = $u }

    # 현재 Credit·최신 이상 점수로 BTS가 줄 조치(PolicyDecisionService.expectedAction과 같은 규칙)로 후보를 고른다.
    # 실제 조치는 아래에서 Demo가 BTS에 요청해 받은 결정(policy_decision)이며, 이 값과 다르면 그대로 기록한다.
    $rows = @(Invoke-ShowcaseSql bts @"
SELECT u.external_user_id ext, u.user_id, c.credit_score credit, IFNULL(a.anomaly_score,'') score,
  CASE WHEN a.anomaly_score IS NULL THEN (CASE WHEN c.credit_score>=40 THEN 'ALLOW' WHEN c.credit_score>=20 THEN 'REQUIRE_CAPTCHA' ELSE 'DELAY' END)
       WHEN c.credit_score<20 AND a.anomaly_score>=0.85 THEN 'RESTRICT'
       WHEN c.credit_score<20 OR a.anomaly_score>=0.70 THEN 'DELAY'
       WHEN c.credit_score<40 OR a.anomaly_score>=0.50 THEN 'REQUIRE_CAPTCHA' ELSE 'ALLOW' END expected
FROM user_account u JOIN user_credit c ON c.user_id=u.user_id
LEFT JOIN risk_assessment a ON a.assessment_id=(SELECT MAX(x.assessment_id) FROM risk_assessment x WHERE x.user_id=u.user_id)
WHERE u.service_id='demo-ticketing' AND u.external_user_id LIKE 'sc-u%' AND EXISTS (SELECT 1 FROM risk_assessment y WHERE y.user_id=u.user_id)
ORDER BY u.external_user_id
"@)
    $done = $live.done
    function Save-Live { $live | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $liveFile }
    $onSale = @('sc06', 'sc07', 'sc08')
    $payIndex = [int]((@($done.PSObject.Properties).Count) + 1)

    function DemoAs($u, [string]$Method, [string]$Path, $Body = $null, [string]$Token = $null, [hashtable]$Headers = @{}, [int[]]$Expect = @(200, 201)) {
        # 실제 사용자는 각자 다른 네트워크에서 접속한다. Demo는 루프백 프록시(이 스크립트)가 실은 X-Forwarded-For를 신뢰한다(TRUSTED_PROXIES).
        $h = @{ 'X-Forwarded-For' = $u.ip } + $Headers
        Demo $Method $Path $Body $Token $h $Expect
    }
    function Start-LiveAttempt($u, [string]$concert, [string]$token) {
        $attempt = New-Uuid
        DemoAs $u PUT "/concerts/$concert/booking-attempts/$attempt" @{ clientOccurredAt = (Get-Date).ToUniversalTime().ToString('o') } $token | Out-Null
        $attempt
    }
    function Join-Queue($u, [string]$concert, [string]$token, [string]$attempt, [string]$captcha = $null) {
        $h = @{ 'X-Booking-Attempt' = $attempt }
        if ($captcha) { $h['X-Captcha-Token'] = $captcha }
        DemoAs $u POST "/concerts/$concert/queue" $null $token $h @(200, 201, 403, 503)
    }
    function Wait-Admitted($u, [string]$concert, [string]$token, [string]$attempt) {
        Wait-Until { (DemoAs $u GET "/concerts/$concert/queue/me" $null $token @{ 'X-Booking-Attempt' = $attempt }).Data.status -eq 'ADMITTED' } 90 '대기열 입장' | Out-Null
    }
    function Invoke-FullBooking($u, [string]$concert, [string]$token, [string]$attempt, [string]$payment) {
        DemoAs $u POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $token | Out-Null
        $seats = @((Demo GET "/concerts/$concert/seats").Data | Where-Object status -eq 'AVAILABLE')
        $seat = $seats[(Get-Random -Maximum ([Math]::Min(200, $seats.Count)))].id
        $hold = (DemoAs $u POST "/concerts/$concert/seat-holds" @{ seatIds = @($seat); attemptId = $attempt; transitionId = (New-Uuid) } $token).Data
        DemoAs $u POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'PAYMENT'; status = 'ENTERED' } $token | Out-Null
        $booking = (DemoAs $u POST '/bookings' @{ holdId = $hold.holdId; paymentIdentifier = $payment } $token).Data
        [pscustomobject]@{ Booking = $booking.id; Seat = $seat }
    }

    $want = [ordered]@{ ALLOW = $LivePerPolicy; REQUIRE_CAPTCHA = $LivePerPolicy; DELAY = $LivePerPolicy; RESTRICT = $LivePerPolicy }
    $summary = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($action in $want.Keys) {
        $already = @($done.PSObject.Properties | Where-Object { $_.Value.expected -eq $action }).Count
        $need = $want[$action] - $already
        # ALLOW 대표는 정상 유형에서, 나머지는 그 조치를 받을 사용자에서 고른다. 유형이 섞이도록 유형별로 번갈아 고른다.
        $cands = @($rows | Where-Object { $_.expected -eq $action -and -not $done.($_.ext) -and $byExt[$_.ext] })
        if ($action -eq 'ALLOW') { $cands = @($cands | Where-Object { $byExt[$_.ext].type -in @('normal', 'fast_normal', 'shared_ip') }) }
        $ordered = @($cands | Group-Object { $byExt[$_.ext].type } | ForEach-Object { , @($_.Group) })
        $pick = New-Object System.Collections.Generic.List[object]
        for ($r = 0; $pick.Count -lt $need -and $r -lt 50; $r++) { foreach ($g in $ordered) { if ($r -lt $g.Count -and $pick.Count -lt $need) { $pick.Add($g[$r]) } } }
        Write-Output "[$action] 후보 $($cands.Count)명 중 $($pick.Count)명 실행 (이전 실행 ${already}명)"
        foreach ($row in $pick) {
            $u = $byExt[$row.ext]; $concert = $onSale[$i % 3]; $i++
            $rec = [ordered]@{ ext = $row.ext; bts = $row.user_id; type = $u.type; expected = $action; credit = [int]$row.credit; score = $row.score; concert = $concert; at = (Get-Date).ToUniversalTime().ToString('o') }
            try {
                $token = (DemoAs $u POST '/users' @{ userId = $u.ext }).Data.token
                $attempt = Start-LiveAttempt $u $concert $token
                $q = Join-Queue $u $concert $token $attempt
                $rec.firstResponse = if ($q.Status -ge 400) { $q.Code } else { $q.Data.status }
                switch ($q.Code) {
                    'CAPTCHA_REQUIRED' {
                        # 일부는 한 번 틀린 뒤 통과, 일부는 틀리고 이탈 (CAPTCHA 성공·실패 사례 모두 생성)
                        $ch = (DemoAs $u POST "/concerts/$concert/queue/captcha-challenges" $null $token @{ 'X-Booking-Attempt' = $attempt }).Data
                        $mode = @('pass', 'fail-pass', 'fail-leave')[$i % 3]
                        if ($action -eq 'DELAY') { $mode = @('pass', 'fail-pass')[$i % 2] }
                        if ($mode -ne 'pass') {
                            DemoAs $u POST "/concerts/$concert/queue/captcha-verifications" @{ challengeId = $ch.challengeId; answer = 'wrong' } $token @{ 'X-Booking-Attempt' = $attempt; 'X-Attempt-Transition' = (New-Uuid) } @(403) | Out-Null
                        }
                        if ($mode -eq 'fail-leave') {
                            # 화면 이탈 보고: 현재 단계(CAPTCHA 등)를 그대로 ABANDONED로 보고한다 (AttemptRules).
                            $snap = (DemoAs $u GET "/booking-attempts/$attempt" $null $token).Data
                            DemoAs $u POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = $snap.stage; status = 'ABANDONED' } $token @{} @(200, 409) | Out-Null
                            $rec.result = 'CAPTCHA 실패 후 이탈'
                        } else {
                            $p = $ch.question -split ' '
                            $grant = (DemoAs $u POST "/concerts/$concert/queue/captcha-verifications" @{ challengeId = $ch.challengeId; answer = [string]([int]$p[0] + [int]$p[2]) } $token @{ 'X-Booking-Attempt' = $attempt }).Data.captchaToken
                            $q2 = Join-Queue $u $concert $token $attempt $grant
                            $rec.result = "CAPTCHA $(if ($mode -eq 'pass') { '통과' } else { '실패 후 통과' }) → 대기열 $($q2.Data.status)"
                        }
                    }
                    'QUEUE_RESTRICTED' { $rec.result = '대기열 입장 거부 (예매 제한)' }
                    default {
                        if ($q.Status -ge 400) { $rec.result = "거부 $($q.Code)" }
                        elseif ($action -eq 'ALLOW') {
                            Wait-Admitted $u $concert $token $attempt
                            $payment = 'sc-live-pay-{0:D3}' -f $payIndex; $payIndex++
                            $b = Invoke-FullBooking $u $concert $token $attempt $payment
                            $rec.booking = $b.Booking; $rec.seat = $b.Seat; $rec.payment = $payment
                            $rec.result = "예매 완료 $($b.Seat)"
                            # 일부 정상 사용자는 기기 등록 → 동적 QR → 검표 → 입장 → 중복 입장 거부까지
                            if (@($done.PSObject.Properties | Where-Object { $_.Value.checkin }).Count -lt 6) {
                                $tickets = @((Demo GET "/bookings/$($b.Booking)/tickets" $null $token).Data)
                                $ticket = $tickets[0].ticketId
                                $device = New-PersistentTicketDevice
                                Register-TicketDevice $device $ticket $token | Out-Null
                                $scan = (Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket) }).Data
                                $pending = (Demo GET "/tickets/$ticket/check-in-challenge" $null $token).Data
                                $admitted = (Demo POST "/tickets/$ticket/check-in-proofs" @{ checkInId = $pending.checkInId; proof = (Get-CheckInProof $device $ticket $pending.checkInId $pending.challenge) } $token).Data
                                $dup = Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket) } -Expect @(409)
                                $rec.checkin = [ordered]@{ ticket = $ticket; scan = $scan.status; checkedInAt = $admitted.checkedInAt; duplicate = $dup.Code
                                    device = [ordered]@{ deviceId = $device.DeviceId; secret = (ConvertTo-B64Url $device.Secret); privateBlob = $device.PrivateBlob } }
                                $rec.result += " → QR 검표 입장, 재입장 $($dup.Code)"
                            }
                        } else { $rec.result = "대기열 $($q.Data.status)" }
                    }
                }
            } catch {
                $rec.result = "오류: $($_.Exception.Message)"
            }
            $done | Add-Member -Force -MemberType NoteProperty -Name $row.ext -Value ([pscustomobject]$rec)
            Save-Live
            Write-Output ("  {0} {1,-18} 예상={2,-15} → {3}" -f $row.ext, $u.type, $action, $rec.result)
        }
    }
    # 실제 정책 적용 기록이 Outbox로 BTS에 모두 전달될 때까지 기다린다 (Demo 스케줄러 5초 주기).
    $ids = (@($done.PSObject.Properties.Name) | ForEach-Object { "'$_'" }) -join ','
    if ($ids) {
        Wait-Until {
            $r = @(Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id IN ($ids) AND o.delivery_status<>'SENT'")
            [int]$r[0].n -eq 0
        } 300 'Outbox 전송 완료' | Out-Null
        Write-Output 'Outbox: 대표 계정의 행동 이벤트·정책 적용 기록 전송 완료'
    }
    # 대표 계정의 새 이벤트로 BTS가 다시 평가한다(실제 동작). 그 평가가 끝날 때까지 기다린다.
    Invoke-Seed (@('wait-eval') + $common)
    $timings.live = [int]((Get-Date) - $t).TotalSeconds
}

$stateFile = Join-Path $RunDir 'seed-state.json'
$state = Get-Content -Raw -Encoding UTF8 $stateFile | ConvertFrom-Json
$state | Add-Member -Force -MemberType NoteProperty -Name lastRun -Value ([pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString('o'); users = $Users; steps = $Steps; seconds = [pscustomobject]$timings })
$state | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $stateFile
Write-Output "완료: $(($timings.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)s" }) -join ', ')"
