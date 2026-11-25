# #47 Demo–BTS 실서버 통합 시나리오. Start-E2E.ps1 실행 후 사용한다.
# 각 시나리오는 Demo HTTP API로 행동을 만들고, 두 DB를 직접 조회해 결과를 비교한다.
param([string[]]$Only = @())
. (Join-Path $PSScriptRoot 'E2E-Common.ps1')
function Want([string]$n) { $Only.Count -eq 0 -or $Only -contains $n }
$runId = (Get-Date -Format 'HHmmss')

function Login([string]$userId) { (Demo POST '/users' @{ userId = $userId }).Data.token }

function Start-Booking([string]$token, [string]$concert, [string[]]$seats) {
    $attempt = New-Uuid
    Demo PUT "/concerts/$concert/booking-attempts/$attempt" @{} $token | Out-Null
    $q = Demo POST "/concerts/$concert/queue" $null $token @{ 'X-Booking-Attempt' = $attempt }
    if ($q.Data.status -ne 'ADMITTED') {
        Wait-Until { (Demo GET "/concerts/$concert/queue/me" $null $token @{ 'X-Booking-Attempt' = $attempt }).Data.status -eq 'ADMITTED' } 60 '대기열 입장' | Out-Null
    }
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $token | Out-Null
    $hold = Demo POST "/concerts/$concert/seat-holds" @{ seatIds = $seats; attemptId = $attempt; transitionId = (New-Uuid) } $token
    [pscustomobject]@{ Attempt = $attempt; HoldId = $hold.Data.holdId }
}

# 사용자들의 시도 단계 이벤트가 모두 Outbox로 옮겨지고(materialize), Outbox가 모두 SENT가 될 때까지 기다린다.
function Wait-Delivered([string[]]$publicUserIds, [int]$Seconds = 120) {
    $ids = ($publicUserIds | ForEach-Object { "'$_'" }) -join ','
    Wait-Until {
        $pendingAttempts = (Invoke-Sql demo "SELECT COUNT(*) c FROM booking_attempt_events e JOIN booking_attempts a ON a.attempt_id=e.attempt_id JOIN demo_users u ON u.id=a.user_id WHERE u.public_user_id IN ($ids) AND e.outbox_id IS NULL").c
        $rows = @(Invoke-Sql demo "SELECT o.external_event_id, o.event_type, o.delivery_status, DATE_FORMAT(o.occurred_at_utc,'%Y-%m-%dT%H:%i:%s.%fZ') t FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id IN ($ids)")
        # 정책 적용 기록(#67)은 행동 이벤트가 아니므로 전송 완료는 함께 기다리되 반환(=behavior_event와 비교할 행)에서는 뺀다.
        if ([int]$pendingAttempts -eq 0 -and $rows.Count -gt 0 -and -not ($rows | Where-Object delivery_status -ne 'SENT')) { $rows | Where-Object event_type -ne 'POLICY_APPLICATION' }
    } $Seconds 'Outbox 전송 완료'
}

# ---------------------------------------------------------------- #67 정책 적용 기록 공통 함수
# 정책별 동작을 확실히 만들기 위한 fixture: BTS DB의 Credit·이상 점수를 직접 정한다(model_version='e2e-manual').
# 실제 AI 평가 결과가 아니다. AI 점수로 이어지는 흐름은 ai 시나리오가 따로 검증한다.
# fixture 사용자는 X-Booking-Attempt 없이 진행해 behavior_event를 만들지 않는다(AI 재평가로 값이 덮이지 않게).
function Set-RiskFixture([string]$btsUser, [int]$credit, $score = $null) {
    $sql = "UPDATE user_credit SET credit_score=$credit WHERE user_id='$btsUser'"
    if ($null -ne $score) { $sql += "; INSERT INTO risk_assessment(user_id, anomaly_score, model_version) VALUES ('$btsUser', $score, 'e2e-manual')" }
    Invoke-Sql bts $sql | Out-Null
}
# 새 사용자를 만들고 c3 대기열에 한 번 입장시켜(이때는 ALLOW) BTS에 등록한 뒤 위험도 fixture를 넣는다.
function New-PolicyUser([string]$name, [int]$credit, $score = $null) {
    $token = Login $name
    Demo POST '/concerts/c3/queue' $null $token | Out-Null
    $bts = Wait-Until { Get-BtsUserId $name } 30 'BTS 사용자 등록'
    if ($credit -ge 0) { Set-RiskFixture $bts $credit $score }
    [pscustomobject]@{ Name = $name; Token = $token; Bts = $bts }
}
function New-Captcha([string]$concert, [string]$token) { (Demo POST "/concerts/$concert/queue/captcha-challenges" $null $token).Data }
function Get-CaptchaAnswer($challenge) { $p = $challenge.question -split ' '; [string]([int]$p[0] + [int]$p[2]) }   # mock: "12 + 34 = ?"
function Submit-Captcha([string]$concert, [string]$token, $challenge, [string]$answer, [int[]]$Expect = @(200)) {
    Demo POST "/concerts/$concert/queue/captcha-verifications" @{ challengeId = $challenge.challengeId; answer = $answer } $token -Expect $Expect
}
function Get-Applications([string[]]$btsUsers) {
    $ids = ($btsUsers | ForEach-Object { "'$_'" }) -join ','
    @(Invoke-Sql bts "SELECT a.application_id, a.user_id, a.decision_id, a.concert_id, a.action, a.result, a.external_application_id, DATE_FORMAT(a.applied_at,'%Y-%m-%dT%H:%i:%s.%f') t, d.action d_action, IFNULL(d.concert_id,'NULL') d_concert, d.context, d.user_id d_user FROM policy_application a JOIN policy_decision d ON d.decision_id=a.decision_id WHERE a.user_id IN ($ids) ORDER BY a.application_id")
}
function Get-PolicyOutbox([string[]]$publicUserIds) {
    $ids = ($publicUserIds | ForEach-Object { "'$_'" }) -join ','
    @(Invoke-Sql demo "SELECT o.id, o.external_event_id, o.delivery_status, IFNULL(o.last_error_code,'') err, o.retries, IFNULL(o.bts_event_id,0) bts_id, DATE_FORMAT(o.occurred_at_utc,'%Y-%m-%dT%H:%i:%s.%f') t FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id IN ($ids) AND o.event_type='POLICY_APPLICATION' ORDER BY o.id")
}
function Wait-PolicySent([string[]]$publicUserIds, [int]$expected, [int]$Seconds = 90) {
    Wait-Until {
        $rows = @(Get-PolicyOutbox $publicUserIds)   # PS 5.1: 한 행이면 배열이 풀려 .Count가 없다
        if ($rows.Count -ge $expected -and -not ($rows | Where-Object delivery_status -ne 'SENT')) { , $rows }
    } $Seconds "정책 적용 기록 ${expected}건 전송"
}
# 관리자 API의 실제 제재 통계. 기록이 없으면(recorded=false) 나머지가 null이라 0으로 읽는다.
function Get-Sanctions([string]$path) {
    $data = (Bts GET $path -Admin).Data
    $s = $data.sanctions
    [pscustomobject]@{
        Recorded = [bool]$s.recorded; Users = [int]$s.appliedUserCount
        CaptchaUsers = [int]$s.byPolicy.REQUIRE_CAPTCHA.userCount; CaptchaApps = [int]$s.byPolicy.REQUIRE_CAPTCHA.applicationCount
        DelayUsers = [int]$s.byPolicy.DELAY.userCount; DelayApps = [int]$s.byPolicy.DELAY.applicationCount
        RestrictUsers = [int]$s.byPolicy.RESTRICT.userCount; RestrictApps = [int]$s.byPolicy.RESTRICT.applicationCount
        Challenged = [int]$s.captcha.challenged; Passed = [int]$s.captcha.passed; Failed = [int]$s.captcha.failed
        Expected = [int]$(if ($null -ne $data.expectedSanctionUsers) { $data.expectedSanctionUsers } else { $data.expectedSanctionUserCount })
    }
}
function Get-Delta($before, $after) {
    $d = [ordered]@{}
    foreach ($p in $after.PSObject.Properties.Name | Where-Object { $_ -ne 'Recorded' }) { $d[$p] = $after.$p - $before.$p }
    [pscustomobject]$d
}
function Format-Delta($d) { ($d.PSObject.Properties | Where-Object { $_.Name -ne 'Expected' } | ForEach-Object { "$($_.Name)+$($_.Value)" }) -join ' ' }

function Get-BtsUserId([string]$publicUserId) {
    (Invoke-Sql demo "SELECT bts_user_id FROM demo_users WHERE public_user_id='$publicUserId'").bts_user_id
}

# ---------------------------------------------------------------- 1. 공연 동기화
if (Want 'concert') {
    $demo = Invoke-Sql demo "SELECT public_id, title, venue, DATE_FORMAT(start_at,'%Y-%m-%dT%H:%i:%sZ') s, DATE_FORMAT(end_at,'%Y-%m-%dT%H:%i:%sZ') e FROM concerts ORDER BY public_id"
    $bts = Invoke-Sql bts "SELECT concert_id, name, venue, DATE_FORMAT(starts_at,'%Y-%m-%dT%H:%i:%sZ') s, DATE_FORMAT(ends_at,'%Y-%m-%dT%H:%i:%sZ') e FROM concert WHERE service_id='demo-ticketing' ORDER BY concert_id"
    Check '공연: BTS에 전체 공연 등록' (@($bts).Count -eq @($demo).Count) "demo=$(@($demo).Count) bts=$(@($bts).Count)"
    $nameMismatch = @($demo | Where-Object { $d = $_; -not ($bts | Where-Object { $_.concert_id -eq $d.public_id -and $_.name -eq $d.title -and $_.venue -eq $d.venue }) })
    Check '공연: ID·이름·장소 일치' ($nameMismatch.Count -eq 0) ($nameMismatch.public_id -join ',')
    $timeMismatch = @($demo | Where-Object { $d = $_; -not ($bts | Where-Object { $_.concert_id -eq $d.public_id -and $_.s -eq $d.s -and $_.e -eq $d.e }) })
    Check '공연: BTS DB 시작·종료 시각(UTC) 일치' ($timeMismatch.Count -eq 0) (($timeMismatch | ForEach-Object { $id = $_.public_id; "$id demo=$($_.s) bts=$(($bts | Where-Object concert_id -eq $id).s)" }) -join '; ')
    $api = (Bts GET '/admin/concerts/c1?serviceId=demo-ticketing' -Admin).Data.concert
    $demoC1 = ($demo | Where-Object public_id -eq 'c1').s
    Check '공연: BTS 관리자 API 시작 시각(UTC) 일치' ([string]$api.startsAt -eq $demoC1) "api=$($api.startsAt) demoDB=$demoC1"
    $demoApi = (Demo GET '/concerts/c1').Data.startAt
    Check '공연: Demo 자체 API 시작 시각 = Demo DB(UTC)' ([string]$demoApi -eq $demoC1) "demoApi=$demoApi demoDB=$demoC1 (JVM TZ=$([TimeZoneInfo]::Local.Id))"
}

# ---------------------------------------------------------------- 2. 예매 → 취소 (정상 흐름)
if (Want 'booking') {
    $user = "e2e-a-$runId"
    $token = Login $user
    $b = Start-Booking $token 'c1' @('A-01')
    Demo POST "/booking-attempts/$($b.Attempt)/transitions" @{ transitionId = (New-Uuid); stage = 'PAYMENT'; status = 'ENTERED' } $token | Out-Null
    $booking = (Demo POST '/bookings' @{ holdId = $b.HoldId; paymentIdentifier = 'test-pay-shared-01' } $token).Data
    Demo POST "/bookings/$($booking.id)/cancel" $null $token | Out-Null

    $btsUser = Wait-Until { Get-BtsUserId $user } 60 'BTS 사용자 등록'
    Check '사용자: BTS 사용자 등록·UUID 매핑' ([bool](Invoke-Sql bts "SELECT user_id FROM user_account WHERE user_id='$btsUser'")) $btsUser

    $outbox = Wait-Delivered @($user)
    $events = @(Invoke-Sql bts "SELECT external_event_id, event_type, booking_id, DATE_FORMAT(occurred_at,'%Y-%m-%dT%H:%i:%s.%fZ') t, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.concertId')) concert, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.attemptId')) attempt FROM behavior_event WHERE user_id='$btsUser' ORDER BY occurred_at, event_id")
    Check '이벤트: Demo Outbox 전체 SENT' ($true) "outbox=$(@($outbox).Count)"
    Check '이벤트: BTS 저장 건수 = Outbox 건수 (누락·중복 없음)' ($events.Count -eq @($outbox).Count) "outbox=$(@($outbox).Count) bts=$($events.Count)"
    $types = ($events.event_type | Sort-Object -Unique) -join ','
    Check '이벤트: BOOKING·CANCEL·BOOKING_ATTEMPT 모두 저장' (($events.event_type -contains 'BOOKING') -and ($events.event_type -contains 'CANCEL') -and ($events.event_type -contains 'BOOKING_ATTEMPT')) $types
    $timeMismatch = @($outbox | Where-Object { $o = $_; -not ($events | Where-Object { $_.external_event_id -eq $o.external_event_id -and $_.t.Substring(0, 23) -eq $o.t.Substring(0, 23) }) })
    Check '이벤트: occurredAt 밀리초까지 일치' ($timeMismatch.Count -eq 0) (($timeMismatch | Select-Object -First 3 | ForEach-Object { "$($_.event_type) demo=$($_.t)" }) -join '; ')
    $hasMillis = @($events | Where-Object { $_.t -notmatch '\.000' }).Count
    Check '이벤트: 소수 초가 0이 아닌 시각 존재 (밀리초 보존)' ($hasMillis -gt 0) "$hasMillis/$($events.Count)"
    Check '매핑: 모든 이벤트 metadata.concertId = c1' (-not ($events | Where-Object concert -ne 'c1')) ''
    $attemptEvents = @($events | Where-Object event_type -eq 'BOOKING_ATTEMPT')
    Check '매핑: 시도 이벤트 attemptId = 생성한 attemptId' ($attemptEvents.Count -gt 0 -and -not ($attemptEvents | Where-Object attempt -ne $b.Attempt)) "$($attemptEvents.Count)건"
    Check '매핑: BOOKING bookingId = Demo 예매 ID' ([bool]($events | Where-Object { $_.event_type -eq 'BOOKING' -and $_.booking_id -eq $booking.id })) $booking.id
    $joined = (Bts GET "/admin/concerts/c1/users?serviceId=demo-ticketing" -Admin).Data
    $joinedIds = @($joined.content | ForEach-Object { $_.user.userId })
    Check '관리자: 공연별 참여 사용자에 표시' ($joinedIds -contains $btsUser) "users=$($joinedIds.Count)"
    $decisions = @(Invoke-Sql bts "SELECT context, action FROM policy_decision WHERE user_id='$btsUser'")
    Check '정책: QUEUE_JOIN·BOOKING_ATTEMPT 결정 기록' (($decisions.context -contains 'QUEUE_JOIN') -and ($decisions.context -contains 'BOOKING_ATTEMPT')) (($decisions | ForEach-Object { "$($_.context)=$($_.action)" }) -join ',')
}

# ---------------------------------------------------------------- 3. 시도 포기 (예매 없음)
if (Want 'abandon') {
    $user = "e2e-b-$runId"
    $token = Login $user
    $attempt = New-Uuid
    Demo PUT "/concerts/c1/booking-attempts/$attempt" @{} $token | Out-Null
    Demo POST '/concerts/c1/queue' $null $token @{ 'X-Booking-Attempt' = $attempt } | Out-Null
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $token | Out-Null
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ABANDONED' } $token | Out-Null
    $btsUser = Wait-Until { Get-BtsUserId $user } 60 'BTS 사용자 등록'
    $events = Wait-Until {
        $rows = @(Invoke-Sql bts "SELECT event_type, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.stage')) stage, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.status')) status FROM behavior_event WHERE user_id='$btsUser'")
        if ($rows | Where-Object status -eq 'ABANDONED') { $rows }
    } 90 'ABANDONED 이벤트 수신'
    Check '포기: 실패한 시도도 BOOKING_ATTEMPT로 저장' (-not ($events | Where-Object event_type -ne 'BOOKING_ATTEMPT')) "$(@($events).Count)건, 마지막 SEAT_SELECTION/ABANDONED"
    Check '포기: BOOKING 이벤트 없음' (-not ($events | Where-Object event_type -eq 'BOOKING')) ''
}

# ---------------------------------------------------------------- 4. BTS 정책 반영 (RESTRICT)
if (Want 'restrict') {
    # 대기열 통과 후 위험도가 올라간 사용자: 대기열은 통과했지만 좌석 선점에서 차단돼야 한다.
    $user = "e2e-r-$runId"
    $token = Login $user
    $attempt = New-Uuid
    Demo PUT "/concerts/c2/booking-attempts/$attempt" @{} $token | Out-Null
    Demo POST '/concerts/c2/queue' $null $token @{ 'X-Booking-Attempt' = $attempt } | Out-Null
    $btsUser = Wait-Until { Get-BtsUserId $user } 30 'BTS 사용자 등록'
    Invoke-Sql bts "UPDATE user_credit SET credit_score=10 WHERE user_id='$btsUser'; INSERT INTO risk_assessment(user_id, anomaly_score, model_version) VALUES ('$btsUser', 0.93, 'e2e-manual')" | Out-Null
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $token | Out-Null
    $hold = Demo POST '/concerts/c2/seat-holds' @{ seatIds = @('B-02'); attemptId = $attempt; transitionId = (New-Uuid) } $token -Expect @(403)
    Check '정책: 대기열 통과 후 RESTRICT 사용자는 좌석 선점 403' ($hold.Code -eq 'BOOKING_RESTRICTED') $hold.Code
    $token2 = Login "$user-2"
    Demo POST '/concerts/c3/queue' $null $token2 | Out-Null
    $btsUser2 = Wait-Until { Get-BtsUserId "$user-2" } 30 'BTS 사용자 등록'
    Invoke-Sql bts "UPDATE user_credit SET credit_score=10 WHERE user_id='$btsUser2'; INSERT INTO risk_assessment(user_id, anomaly_score, model_version) VALUES ('$btsUser2', 0.93, 'e2e-manual')" | Out-Null
    $q = Demo POST '/concerts/c2/queue' $null $token2 -Expect @(403)
    Check '정책: RESTRICT 사용자는 대기열 입장 403' ($q.Code -eq 'QUEUE_RESTRICTED') $q.Code
}

# ---------------------------------------------------------------- 5. BTS 장애 → 재시도, 유실 없음
if (Want 'outage') {
    $user = "e2e-o-$runId"
    $token = Login $user
    $attempt = New-Uuid
    Demo PUT "/concerts/c3/booking-attempts/$attempt" @{} $token | Out-Null
    Demo POST '/concerts/c3/queue' $null $token @{ 'X-Booking-Attempt' = $attempt } | Out-Null
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $token | Out-Null
    & (Join-Path $PSScriptRoot 'Stop-E2E.ps1') -Only bts | Out-Null
    Start-Sleep -Seconds 3
    $other = Login "$user-q"
    $q = Demo POST '/concerts/c3/queue' $null $other -Expect @(503)
    Check '장애: BTS 중지 중 신규 대기열 입장 503' ($q.Status -eq 503) $q.Code
    $hold = Demo POST '/concerts/c3/seat-holds' @{ seatIds = @('C-03'); attemptId = $attempt; transitionId = (New-Uuid) } $token
    Check '장애: 이미 입장한 사용자의 좌석 선점은 허용' ($hold.Status -eq 201) $hold.Data.holdId
    Demo POST "/booking-attempts/$attempt/transitions" @{ transitionId = (New-Uuid); stage = 'PAYMENT'; status = 'ENTERED' } $token | Out-Null
    $booking = (Demo POST '/bookings' @{ holdId = $hold.Data.holdId; paymentIdentifier = 'test-pay-shared-02' } $token).Data
    Start-Sleep -Seconds 12
    $pending = @(Invoke-Sql demo "SELECT o.delivery_status, o.last_error_code FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id='$user'")
    Check '장애: 전송 실패 이벤트가 Outbox에 대기 (SENT 아님)' (-not ($pending | Where-Object delivery_status -eq 'SENT')) (($pending | Group-Object delivery_status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ',')
    & (Join-Path $PSScriptRoot 'Start-E2E.ps1') -Only bts -SkipCompose | Out-Null
    $outbox = Wait-Delivered @($user) 240
    $btsUser = Get-BtsUserId $user
    $stored = @(Invoke-Sql bts "SELECT external_event_id FROM behavior_event WHERE user_id='$btsUser'")
    Check '장애: 복구 후 전부 재전송, 유실·중복 없음' ($stored.Count -eq @($outbox).Count -and @($stored.external_event_id | Sort-Object -Unique).Count -eq $stored.Count) "outbox=$(@($outbox).Count) bts=$($stored.Count) booking=$($booking.id)"
}

# ---------------------------------------------------------------- 6. 중복 전송 방지 (응답 유실 후 재전송 가정)
if (Want 'replay') {
    $row = @(Invoke-Sql demo "SELECT payload FROM outbox_events WHERE delivery_status='SENT' AND event_type='BOOKING' ORDER BY id DESC LIMIT 1")[0]
    $payload = $row.payload | ConvertFrom-Json
    $before = (Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event").c
    $r = Bts POST '/events' $payload -Expect @(200, 201)
    $after = (Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event").c
    Check '중복: 같은 이벤트 재전송은 200, 저장 건수 그대로' ($r.Status -eq 200 -and $before -eq $after) "status=$($r.Status) before=$before after=$after"
    $payload.metadata | Add-Member -Force NoteProperty ipAddress '203.0.113.99'
    $c = Bts POST '/events' $payload -Expect @(409)
    Check '중복: 같은 ID에 다른 내용은 409' ($c.Status -eq 409) $c.Code
}

# ---------------------------------------------------------------- 7. 동시성: 여러 사용자가 같은 좌석·다른 좌석 동시 선점
if (Want 'concurrency') {
    # 재실행 시 이전 실행이 잡은 좌석과 겹치지 않도록 G·H열에서 무작위로 고른다 (깨끗한 환경에서는 Start-E2E로 DB가 초기화됨)
    $n = 8; $concert = 'c3'; $seat = '{0}-{1:D2}' -f ('G', 'H' | Get-Random), (Get-Random -Minimum 1 -Maximum 13)
    $users = 1..$n | ForEach-Object { $u = "e2e-c$_-$runId"; [pscustomobject]@{ User = $u; Token = (Login $u); Attempt = (New-Uuid) } }
    foreach ($u in $users) {
        Demo PUT "/concerts/$concert/booking-attempts/$($u.Attempt)" @{} $u.Token | Out-Null
        Demo POST "/concerts/$concert/queue" $null $u.Token @{ 'X-Booking-Attempt' = $u.Attempt } | Out-Null
        Demo POST "/booking-attempts/$($u.Attempt)/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $u.Token | Out-Null
    }
    $common = Join-Path $PSScriptRoot 'E2E-Common.ps1'
    $jobs = foreach ($u in $users) {
        Start-Job -ArgumentList $common, $u.Token, $u.Attempt, $concert, $seat -ScriptBlock {
            param($common, $token, $attempt, $concert, $seat)
            . $common
            $r = Demo POST "/concerts/$concert/seat-holds" @{ seatIds = @($seat); attemptId = $attempt; transitionId = ([guid]::NewGuid().ToString()) } $token -Expect @(201, 403, 409, 503)
            "$($r.Status) $($r.Code)"
        }
    }
    $statuses = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job
    $won = @($statuses | Where-Object { "$_" -like '201 *' }).Count
    Check '동시성: 같은 좌석 동시 선점은 1명만 성공' ($won -eq 1) (($statuses | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
    $outbox = Wait-Delivered @($users.User)
    $btsIds = (@($users | ForEach-Object { "'$(Get-BtsUserId $_.User)'" })) -join ','
    $stored = @(Invoke-Sql bts "SELECT external_event_id FROM behavior_event WHERE user_id IN ($btsIds)")
    Check '동시성: 모든 사용자 이벤트가 BTS에 1회씩 저장' ($stored.Count -eq @($outbox).Count -and @($stored.external_event_id | Sort-Object -Unique).Count -eq $stored.Count) "outbox=$(@($outbox).Count) bts=$($stored.Count)"
    $rejected = @(Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event WHERE user_id IN ($btsIds) AND JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.stage'))='SEAT_HOLD' AND JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.status'))='REJECTED'")[0].c
    Check '동시성: 선점 실패가 SEAT_HOLD/REJECTED 시도 이벤트로 기록' ([int]$rejected -eq ($n - 1)) "REJECTED=$rejected"
}

# ---------------------------------------------------------------- 8. QR 검표 → CHECK_IN → BTS 관람 이벤트 (#53)
if (Want 'checkin') {
    $concert = 'c2'
    $user = "e2e-k-$runId"
    $token = Login $user
    $other = Login "$user-x"
    # 재실행 시 좌석이 겹치지 않도록 E·F열에서 연속 2석을 무작위로 고른다.
    $row = 'E', 'F' | Get-Random; $num = Get-Random -Minimum 1 -Maximum 12
    $seats = @(('{0}-{1:D2}' -f $row, $num), ('{0}-{1:D2}' -f $row, ($num + 1)))
    $b = Start-Booking $token $concert $seats
    Demo POST "/booking-attempts/$($b.Attempt)/transitions" @{ transitionId = (New-Uuid); stage = 'PAYMENT'; status = 'ENTERED' } $token | Out-Null
    $booking = (Demo POST '/bookings' @{ holdId = $b.HoldId; paymentIdentifier = 'test-pay-shared-03' } $token).Data
    $tickets = @((Demo GET "/bookings/$($booking.id)/tickets" $null $token).Data)
    $ticket = $tickets[0].ticketId; $spare = $tickets[1].ticketId
    Check '검표: 예매 좌석마다 티켓 발급 (ISSUED, 기기 미등록)' ($tickets.Count -eq 2 -and -not ($tickets | Where-Object { $_.status -ne 'ISSUED' -or $_.device })) "booking=$($booking.id) seats=$($seats -join ',')"

    function TicketRow([string]$id) { @(Invoke-Sql demo "SELECT status, IFNULL(DATE_FORMAT(checked_in_at,'%Y-%m-%dT%H:%i:%s.%f'),'NULL') t FROM admission_tickets WHERE public_id='$id'")[0] }
    function CheckInOutbox { @(Invoke-Sql demo "SELECT o.external_event_id, o.delivery_status, o.business_transition_id, o.aggregate_id, o.bts_event_id, DATE_FORMAT(o.occurred_at_utc,'%Y-%m-%dT%H:%i:%s.%f') t FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id='$user' AND o.event_type='CHECK_IN'") }
    function Untouched { $r = TicketRow $ticket; $r.status -eq 'ISSUED' -and $r.t -eq 'NULL' -and @(CheckInOutbox).Count -eq 0 }

    # --- 기기 등록과 QR
    $device = New-TicketDevice
    $enrolled = Register-TicketDevice $device $ticket $token
    Check '검표: 기기 등록 (챌린지 서명 → TOTP 비밀키 수령)' ($device.Secret.Length -eq 20 -and $enrolled.totp.period -eq 30 -and $enrolled.changesRemaining -eq 3) "device=$($device.DeviceId)"
    $qr = New-TicketQr $device $ticket
    Check '검표: QR 형식 BTS1.<ticket>.<device>.<epoch>.<totp>.<signature>' ($qr -match '^BTS1\.[0-9a-f-]{36}\.[0-9a-f-]{36}\.\d+\.\d{6}\.[A-Za-z0-9_-]{86}$') ''

    # --- 거부 시나리오. 어느 것도 티켓 상태·입장 시각·Outbox를 바꾸지 않아야 한다.
    $r = Demo POST '/check-ins' @{ qr = $qr } $token -Expect @(401)
    Check '거부: 검표 담당자 키 없이(사용자 세션으로) 스캔 401' ($r.Code -eq 'UNAUTHORIZED') $r.Code
    $r = Gate POST '/check-ins' @{ qr = 'BTS1.not-a-ticket-qr' } -Expect @(400)
    Check '거부: 잘못된 형식의 QR 400 QR_INVALID' ($r.Code -eq 'QR_INVALID') $r.Code
    $now = Get-EpochSeconds
    $wrongTotp = if ((Get-Totp $device.Secret $now) -eq '000000') { '000001' } else { '000000' }
    $r = Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket $now $wrongTotp) } -Expect @(403)
    Check '거부: TOTP가 틀린 QR 403 QR_REJECTED' ($r.Code -eq 'QR_REJECTED') $r.Code
    $r = Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket ($now - 300)) } -Expect @(403)
    Check '거부: 만료된 TOTP(5분 전 QR) 403 QR_EXPIRED' ($r.Code -eq 'QR_EXPIRED') $r.Code
    # 등록되지 않은 기기: deviceId와 TOTP 비밀키를 복사해도 개인키가 다르다.
    $stranger = New-TicketDevice; $stranger.DeviceId = $device.DeviceId; $stranger.Secret = $device.Secret
    $r = Gate POST '/check-ins' @{ qr = (New-TicketQr $stranger $ticket) } -Expect @(403)
    Check '거부: 등록되지 않은 기기 키로 서명한 QR 403 QR_REJECTED' ($r.Code -eq 'QR_REJECTED') $r.Code
    Check '거부: 스캔 단계 실패 후 티켓 ISSUED·checked_in_at NULL·CHECK_IN 없음' (Untouched) ''

    # 스캔만으로는 입장되지 않는다(캡처한 QR). 다른 사용자는 챌린지를 볼 수 없다.
    $scan = (Gate POST '/check-ins' @{ qr = $qr }).Data
    Check '검표: 스캔은 챌린지만 발급 (PENDING, 입장 미확정)' ($scan.status -eq 'PENDING' -and -not $scan.checkedInAt -and (Untouched)) "checkIn=$($scan.checkInId)"
    $r = Demo GET "/tickets/$ticket/check-in-challenge" $null $other -Expect @(403)
    Check '거부: 다른 사용자의 챌린지 조회 403' ($r.Code -eq 'FORBIDDEN') $r.Code
    $pending = (Demo GET "/tickets/$ticket/check-in-challenge" $null $token).Data
    Check '검표: 등록 기기가 챌린지 수신' ($pending.checkInId -eq $scan.checkInId -and $pending.deviceId -eq $device.DeviceId) ''
    # 등록되지 않은 기기의 응답 서명 → 거부되고 챌린지는 소비된다.
    $r = Demo POST "/tickets/$ticket/check-in-proofs" @{ checkInId = $pending.checkInId; proof = (Get-CheckInProof $stranger $ticket $pending.checkInId $pending.challenge) } $token -Expect @(403)
    $state = (Gate GET "/check-ins/$($scan.checkInId)").Data.status
    Check '거부: 등록되지 않은 기기의 챌린지 서명 403, 챌린지 REJECTED' ($r.Code -eq 'CHECKIN_PROOF_INVALID' -and $state -eq 'REJECTED') "$($r.Code)/$state"
    $r = Demo POST "/tickets/$ticket/check-in-proofs" @{ checkInId = $pending.checkInId; proof = (Get-CheckInProof $device $ticket $pending.checkInId $pending.challenge) } $token -Expect @(403)
    Check '거부: 소비된 챌린지 재사용(올바른 서명) 403' ($r.Code -eq 'CHECKIN_PROOF_INVALID') $r.Code
    # 챌린지 만료: 응답 없이 유효 시간(e2e 6초)을 넘긴다.
    $scan = (Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket) }).Data
    $pending = (Demo GET "/tickets/$ticket/check-in-challenge" $null $token).Data
    Start-Sleep -Seconds 8
    $state = (Gate GET "/check-ins/$($scan.checkInId)").Data.status
    $r = Demo POST "/tickets/$ticket/check-in-proofs" @{ checkInId = $pending.checkInId; proof = (Get-CheckInProof $device $ticket $pending.checkInId $pending.challenge) } $token -Expect @(403)
    Check '거부: 만료된 챌린지(올바른 서명) 403, 검표기에는 EXPIRED' ($r.Code -eq 'CHECKIN_PROOF_INVALID' -and $state -eq 'EXPIRED') "$($r.Code)/$state"
    Check '거부: 응답 단계 실패 후에도 티켓 ISSUED·checked_in_at NULL·CHECK_IN 없음' (Untouched) ''

    # --- 정상 검표: 스캔 → 챌린지 → 등록 기기 서명 → 확정
    $scan = (Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket) }).Data
    $pending = (Demo GET "/tickets/$ticket/check-in-challenge" $null $token).Data
    $answer = @{ checkInId = $pending.checkInId; proof = (Get-CheckInProof $device $ticket $pending.checkInId $pending.challenge) }
    $admitted = (Demo POST "/tickets/$ticket/check-in-proofs" $answer $token).Data
    $done = (Gate GET "/check-ins/$($scan.checkInId)").Data
    Check '검표: 등록 기기 서명으로 입장 확정, 검표기 COMPLETED' ($admitted.ticketId -eq $ticket -and $done.status -eq 'COMPLETED' -and $done.seatId -eq $seats[0]) "seat=$($done.seatId)"
    $rowAfter = TicketRow $ticket
    $apiTime = ([DateTimeOffset]::Parse([string]$admitted.checkedInAt, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.ffffff')
    Check 'Demo DB: 티켓 CHECKED_IN, checked_in_at 기록 = API checkedInAt' ($rowAfter.status -eq 'CHECKED_IN' -and $rowAfter.t -eq $apiTime) "db=$($rowAfter.t) api=$apiTime"
    $apiTicket = @((Demo GET "/bookings/$($booking.id)/tickets" $null $token).Data) | Where-Object ticketId -eq $ticket
    Check 'Demo API: 티켓 조회에 CHECKED_IN·checkedInAt 반영' ($apiTicket.status -eq 'CHECKED_IN' -and [bool]$apiTicket.checkedInAt) ''

    # --- 중복 검표
    $r = Gate POST '/check-ins' @{ qr = (New-TicketQr $device $ticket) } -Expect @(409)
    $r2 = Demo POST "/tickets/$ticket/check-in-proofs" $answer $token -Expect @(409)
    Check '중복: 입장한 티켓 재스캔·응답 재전송 409' ($r.Code -eq 'TICKET_ALREADY_CHECKED_IN' -and $r2.Code -eq 'TICKET_ALREADY_CHECKED_IN') "$($r.Code)/$($r2.Code)"
    $rowAgain = TicketRow $ticket
    Check '중복: 최초 입장 시각 유지, CHECK_IN Outbox 1건' ($rowAgain.t -eq $rowAfter.t -and @(CheckInOutbox).Count -eq 1) "checked_in_at=$($rowAgain.t)"
    $spareRow = TicketRow $spare
    Check 'Demo DB: 같은 예매의 다른 좌석 티켓은 ISSUED 유지' ($spareRow.status -eq 'ISSUED' -and $spareRow.t -eq 'NULL') ''

    # --- Outbox → 실제 BTS. 전송은 Demo의 스케줄러(BookingJobs, 5초 주기)가 수행한다. 여기서는 호출하지 않고 기다리기만 한다.
    $out = @(CheckInOutbox)[0]
    Check 'Outbox: CHECK_IN 생성 (전이 ID <ticketId>:CHECK_IN, aggregate=예매 ID, 시각=checked_in_at 밀리초)' ($out.business_transition_id -eq "$($ticket):CHECK_IN" -and $out.aggregate_id -eq $booking.id -and $out.t.Substring(0, 23) -eq $rowAfter.t.Substring(0, 23)) "event=$($out.external_event_id)"
    $all = Wait-Delivered @($user)
    $out = @(CheckInOutbox)[0]
    Check 'Outbox: 스케줄러가 CHECK_IN을 전송해 SENT, BTS eventId 기록' ($out.delivery_status -eq 'SENT' -and [long]$out.bts_event_id -gt 0) "status=$($out.delivery_status) btsEventId=$($out.bts_event_id) (사용자 Outbox $(@($all).Count)건 전부 SENT)"

    $btsUser = Get-BtsUserId $user
    $stored = @(Invoke-Sql bts "SELECT event_id, user_id, service_id, external_event_id, event_type, IFNULL(booking_id,'') booking_id, IFNULL(ticket_id,'') ticket_id, DATE_FORMAT(occurred_at,'%Y-%m-%dT%H:%i:%s.%f') t, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.concertId')) concert, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.performanceStartsAt')) starts, JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.performanceEndsAt')) ends, JSON_EXTRACT(metadata,'$.deviceChanged') changed, JSON_LENGTH(metadata) n FROM behavior_event WHERE user_id='$btsUser' AND event_type='CHECK_IN'")
    Check 'BTS DB: behavior_event에 CHECK_IN 1건 저장' ($stored.Count -eq 1) "count=$($stored.Count)"
    $e = $stored[0]
    Check 'BTS DB: eventId = Outbox의 bts_event_id, externalEventId·serviceId 일치' ([long]$e.event_id -eq [long]$out.bts_event_id -and $e.external_event_id -eq $out.external_event_id -and $e.service_id -eq 'demo-ticketing') "eventId=$($e.event_id)"
    Check '매핑: 사용자 = Demo 사용자의 BTS UUID' ($e.user_id -eq $btsUser -and [bool](Invoke-Sql bts "SELECT user_id FROM user_account WHERE user_id='$btsUser' AND external_user_id='$user'")) $btsUser
    Check '매핑: ticket_id = Demo 티켓 ID, booking_id = Demo 예매 ID' ($e.ticket_id -eq $ticket -and $e.booking_id -eq $booking.id) "ticket=$($e.ticket_id) booking=$($e.booking_id)"
    $concertRow = @(Invoke-Sql bts "SELECT DATE_FORMAT(starts_at,'%Y-%m-%dT%H:%i:%sZ') s, DATE_FORMAT(ends_at,'%Y-%m-%dT%H:%i:%sZ') e FROM concert WHERE service_id='demo-ticketing' AND concert_id='$concert'")[0]
    Check '매핑: metadata.concertId = 공연 ID, 공연 시작·종료 시각 = BTS concert' ($e.concert -eq $concert -and $e.starts -eq $concertRow.s -and $e.ends -eq $concertRow.e) "concert=$($e.concert) starts=$($e.starts)"
    Check '매핑: occurred_at = Demo checked_in_at (밀리초까지)' ($e.t.Substring(0, 23) -eq $rowAfter.t.Substring(0, 23)) "bts=$($e.t.Substring(0, 23)) demo=$($rowAfter.t.Substring(0, 23))"
    Check '매핑: metadata는 concertId·공연 시각·deviceChanged=false뿐 (비밀값 없음)' ([int]$e.n -eq 4 -and "$($e.changed)" -eq 'false') "keys=$($e.n) deviceChanged=$($e.changed)"
    $bookingEvent = @(Invoke-Sql bts "SELECT DATE_FORMAT(occurred_at,'%Y-%m-%dT%H:%i:%s.%f') t FROM behavior_event WHERE user_id='$btsUser' AND event_type='BOOKING' AND booking_id='$($booking.id)'")
    Check '매핑: 같은 예매의 BOOKING 이벤트가 있고 CHECK_IN보다 앞선다' ($bookingEvent.Count -eq 1 -and $bookingEvent[0].t -lt $e.t) ''

    # --- 중복 전송 방지 (응답 유실 후 재전송 가정): Outbox에 동결된 payload를 그대로 다시 보낸다.
    $payload = (@(Invoke-Sql demo "SELECT payload FROM outbox_events WHERE external_event_id='$($out.external_event_id)'")[0].payload) | ConvertFrom-Json
    $r = Bts POST '/events' $payload -Expect @(200, 201)
    $count = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event WHERE user_id='$btsUser' AND event_type='CHECK_IN'").c
    Check '중복: 같은 CHECK_IN 재전송은 200, 같은 eventId, 저장 1건 그대로' ($r.Status -eq 200 -and [long]$r.Data.eventId -eq [long]$e.event_id -and $count -eq 1) "status=$($r.Status) count=$count"
    $payload.ticketId = $spare
    $r = Bts POST '/events' $payload -Expect @(409)
    $count = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event WHERE user_id='$btsUser' AND event_type='CHECK_IN'").c
    Check '중복: 같은 ID에 다른 티켓이면 409, 저장 1건 그대로' ($r.Status -eq 409 -and $count -eq 1) $r.Code

    # --- 조회 API. 관리자 프론트엔드(ticket-fds-admin frontend/src/api/client.ts)와 같은 경로·파라미터를 쓴다.
    $page = (Bts GET "/admin/users/$btsUser/events?page=0&size=50&sort=occurredAt,desc&eventType=CHECK_IN" -Admin).Data
    $item = @($page.content)[0]
    Check '관리자 API: 사용자 이벤트에서 CHECK_IN 조회' (@($page.content).Count -eq 1 -and $item.eventType -eq 'CHECK_IN' -and $item.ticketId -eq $ticket -and $item.bookingId -eq $booking.id -and $item.metadata.concertId -eq $concert) "eventId=$($item.eventId)"
    # 프론트엔드 타입 UserEvent(frontend/src/api/types.ts)의 필드와 응답 필드가 일치하는지 확인한다.
    $expected = 'bookingId,eventId,eventType,externalEventId,metadata,occurredAt,serviceId,ticketId,userId'
    $actual = (@($item.PSObject.Properties.Name) | Sort-Object) -join ','
    Check '관리자 API: 응답 필드 = 프론트엔드 UserEvent 타입' ($actual -eq $expected) $actual
    $apiOccurred = ([DateTimeOffset]::Parse([string]$item.occurredAt, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fff')
    Check '관리자 API: occurredAt = Demo checked_in_at (UTC, 밀리초)' ($apiOccurred -eq $rowAfter.t.Substring(0, 23)) "api=$($item.occurredAt)"
    $unfiltered = (Bts GET "/admin/users/$btsUser/events?page=0&size=50&sort=occurredAt,desc" -Admin).Data
    Check '관리자 API: 전체 이력(최신순)의 첫 항목이 CHECK_IN' (@($unfiltered.content)[0].eventType -eq 'CHECK_IN') "총 $(@($unfiltered.content).Count)건"
    $svc = (Bts GET "/users/$btsUser/events?eventType=CHECK_IN").Data
    Check '서비스 API: 사용자별 이벤트 조회에서 CHECK_IN 조회' (@($svc.content).Count -eq 1 -and @($svc.content)[0].ticketId -eq $ticket) ''
    $summary = Bts GET '/admin/summary?serviceId=demo-ticketing' -Admin -Expect @(200, 401, 403, 404)
    Check '관리자 API: 대시보드 요약 eventsByType.CHECK_IN 집계' ($summary.Status -eq 200 -and [int]$summary.Data.eventsByType.CHECK_IN -ge 1) "status=$($summary.Status) CHECK_IN=$($summary.Data.eventsByType.CHECK_IN)"
    $joined = (Bts GET "/admin/concerts/$concert/users?serviceId=demo-ticketing" -Admin).Data
    Check '관리자 API: 공연별 참여 사용자에 표시' (@($joined.content | ForEach-Object { $_.user.userId }) -contains $btsUser) ''

    # --- 미구현 확인(판정 대상 아님): BTS는 CHECK_IN을 behavior_event에만 저장한다.
    $history = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM booking_history WHERE user_id='$btsUser'").c
    $detail = (Bts GET "/admin/users/$btsUser" -Admin).Data
    Write-Output "[INFO] BTS booking_history 행 수(이 사용자) = $history  (CHECK_IN → 관람 이력 적재 미구현, 후속 이슈)"
    Write-Output "[INFO] 관리자 사용자 상세 최상위 필드: $((@($detail.PSObject.Properties.Name)) -join ',')"
}

# ---------------------------------------------------------------- 9. AI 이상도 평가 → Credit → 정책 (#62, admin #40)
if (Want 'ai') {
    if (-not $script:E2E.aiUrl) {
        Write-Output '[SKIP] ai: Start-E2E.ps1 -AiUrl <ticket-fds-ai 주소> 로 기동해야 실행됩니다.'
    } else {
        # 정상 사용자: 시도 1번 후 좌석을 보다가 포기. e2e는 모든 예매가 127.0.0.1·공용 테스트 결제수단으로 들어와
        # 예매를 하면 ipBookingDensity·cardReuseCount가 다른 시나리오 사용자 수만큼 커지므로 예매는 하지 않는다.
        $normal = "e2e-ai-n-$runId"; $tn = Login $normal
        $a = New-Uuid
        Demo PUT "/concerts/c1/booking-attempts/$a" @{} $tn | Out-Null
        Demo POST '/concerts/c1/queue' $null $tn @{ 'X-Booking-Attempt' = $a } | Out-Null
        Demo POST "/booking-attempts/$a/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ENTERED' } $tn | Out-Null
        Demo POST "/booking-attempts/$a/transitions" @{ transitionId = (New-Uuid); stage = 'SEAT_SELECTION'; status = 'ABANDONED' } $tn | Out-Null

        # 매크로형: 짧고 일정한 간격(약 0.15초 + 요청 시간)으로 시도 12번을 시작하고 곧바로 포기
        $macro = "e2e-ai-m-$runId"; $tm = Login $macro
        for ($i = 0; $i -lt 12; $i++) {
            $x = New-Uuid
            Demo PUT "/concerts/c2/booking-attempts/$x" @{} $tm | Out-Null
            Demo POST "/booking-attempts/$x/transitions" @{ transitionId = (New-Uuid); stage = 'STARTED'; status = 'ABANDONED' } $tm | Out-Null
            Start-Sleep -Milliseconds 150
        }

        Wait-Delivered @($normal, $macro) | Out-Null
        $nId = Get-BtsUserId $normal; $mId = Get-BtsUserId $macro
        # 모든 이벤트가 BTS에 도착한 뒤, 마지막 이벤트까지 평가에 반영될 때까지 기다린다 (AI_POLL_MS=5000)
        Wait-Until {
            $c = @(Invoke-Sql bts "SELECT c.user_id FROM risk_assessment_cursor c WHERE c.user_id IN ('$nId','$mId') AND c.last_event_id = (SELECT MAX(e.event_id) FROM behavior_event e WHERE e.user_id = c.user_id)")
            $c.Count -eq 2
        } 120 'AI 평가에 마지막 이벤트 반영' | Out-Null
        Start-Sleep -Seconds 2  # 커밋 후 Credit 재산출(AFTER_COMMIT) 반영 대기

        $latest = "SELECT a.anomaly_score s, a.model_version v FROM risk_assessment a WHERE a.user_id='{0}' ORDER BY a.assessment_id DESC LIMIT 1"
        $nScore = @(Invoke-Sql bts ($latest -f $nId))[0]; $mScore = @(Invoke-Sql bts ($latest -f $mId))[0]
        $cur = @(Invoke-Sql bts "SELECT user_id, last_status FROM risk_assessment_cursor WHERE user_id IN ('$nId','$mId')")
        Check 'AI: 두 사용자 모두 평가 OK (cursor)' (-not ($cur | Where-Object last_status -ne 'OK') -and $cur.Count -eq 2) (($cur.last_status) -join ',')
        $nf = (Bts GET "/admin/users/$nId/features" -Admin).Data
        Check 'AI: 정상 사용자 이상 점수 < 0.5' ($nScore -and [double]$nScore.s -lt 0.5) "score=$($nScore.s) (bookingCount=$($nf.bookingCount), cardReuseCount=$($nf.cardReuseCount), ipBookingDensity=$($nf.ipBookingDensity))"
        Check 'AI: 매크로형 사용자 이상 점수 >= 0.5 (탐지 임계값)' ($mScore -and [double]$mScore.s -ge 0.5) "score=$($mScore.s) model=$($mScore.v)"
        Check 'AI: 매크로형 점수 > 정상 사용자 점수' ($nScore -and $mScore -and [double]$mScore.s -gt [double]$nScore.s) "macro=$($mScore.s) normal=$($nScore.s)"
        $credit = "SELECT c.credit_score s, c.tier t FROM user_credit c WHERE c.user_id='{0}'"
        $nCredit = @(Invoke-Sql bts ($credit -f $nId))[0]; $mCredit = @(Invoke-Sql bts ($credit -f $mId))[0]
        Check 'Credit: 정상 사용자 NORMAL 유지' ($nCredit.t -eq 'NORMAL') "credit=$($nCredit.s) tier=$($nCredit.t)"
        Check 'Credit: 매크로형 사용자 Credit 하락·NORMAL 아님' ([int]$mCredit.s -lt [int]$nCredit.s -and $mCredit.t -ne 'NORMAL') "credit=$($mCredit.s) tier=$($mCredit.t)"
        $hist = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM credit_history WHERE user_id='$mId' AND reason='AI 이상도 평가 반영'").c
        Check 'Credit: AI 평가 반영 이력(credit_history) 기록' ($hist -ge 1) "$hist건"
        $detail = (Bts GET "/admin/users/$mId" -Admin).Data.user
        Check '관리자 API: 사용자 상세에 최신 이상 점수 표시' ([double]$detail.anomalyScore -eq [double]$mScore.s) "api=$($detail.anomalyScore)"

        $q = Demo POST '/concerts/c3/queue' $null $tm -Expect @(200, 201, 403)
        $decision = @(Invoke-Sql bts "SELECT action, anomaly_score_at_decision s FROM policy_decision WHERE user_id='$mId' AND context='QUEUE_JOIN' ORDER BY decision_id DESC LIMIT 1")[0]
        Check '정책: 매크로형 사용자 대기열 입장에 AI 점수 반영 (ALLOW 아님)' ($decision.action -ne 'ALLOW' -and [double]$decision.s -ge 0.5) "action=$($decision.action) score=$($decision.s) demo=$($q.Status) $($q.Code)"

        # 실제 AI 점수로 내려진 정책이 실제로 적용되고, 그 적용 기록이 BTS에 남는지 (#67). 위험도를 직접 넣지 않는다.
        $expected = switch ($decision.action) {
            'RESTRICT' { @('BLOCKED') }                               # 위 입장 요청이 이미 QUEUE_RESTRICTED로 거부됨
            'REQUIRE_CAPTCHA' { @('CHALLENGED', 'PASSED') }
            'DELAY' { @('DELAYED') }
            default { @() }
        }
        if ($decision.action -in @('REQUIRE_CAPTCHA', 'DELAY')) {
            $ch = New-Captcha 'c3' $tm
            $grant = (Submit-Captcha 'c3' $tm $ch (Get-CaptchaAnswer $ch)).Data.captchaToken
            Demo POST '/concerts/c3/queue' $null $tm @{ 'X-Captcha-Token' = $grant } | Out-Null
        }
        if ($expected.Count -gt 0) {
            Wait-PolicySent @($macro) $expected.Count | Out-Null
            $apps = @(Get-Applications @($mId))
            $ok = $apps.Count -eq $expected.Count -and -not ($apps | Where-Object { $_.action -ne $decision.action -or $_.d_concert -ne 'c3' -or $_.concert_id -ne 'c3' }) -and -not (Compare-Object @($apps.result | Sort-Object) @($expected | Sort-Object))
            Check '정책 적용(실제 AI): AI 점수로 내려진 조치의 실제 적용이 BTS에 기록' $ok "action=$($decision.action) results=$(($apps.result) -join ',') (model=$($mScore.v))"
        }
        $nApps = @(Get-Applications @($nId))
        Check '정책 적용(실제 AI): 정상(ALLOW) 사용자는 적용 기록 없음' ($nApps.Count -eq 0) "$($nApps.Count)건"
    }
}

# ---------------------------------------------------------------- 10. 실제 정책 적용 기록 → BTS → 관리자 통계 (#67)
# 위험도는 fixture(Set-RiskFixture)로 정한다. 실제 AI 기반 검증이 아니며, 정책별 적용 시점과 기록·집계만 검증한다.
if (Want 'policy') {
    $c1 = '/admin/concerts/c1?serviceId=demo-ticketing'; $c2 = '/admin/concerts/c2?serviceId=demo-ticketing'
    $c3 = '/admin/concerts/c3?serviceId=demo-ticketing'; $all = '/admin/summary?serviceId=demo-ticketing'
    $before = @{ c1 = (Get-Sanctions $c1); c2 = (Get-Sanctions $c2); c3 = (Get-Sanctions $c3); all = (Get-Sanctions $all) }   # fixture 주입 전 통계
    # BTS 판정 기준(PolicyDecisionService): 평가 이력 없음 → Credit 20~39 REQUIRE_CAPTCHA, 20 미만 DELAY. Credit<20 + 점수>=0.85 → RESTRICT
    $pass = New-PolicyUser "e2e-pa-pass-$runId" 30      # CAPTCHA 요구 → 실패 1회 → 통과 → 입장
    $fail = New-PolicyUser "e2e-pa-fail-$runId" 30      # CAPTCHA 요구 → 실패 후 이탈
    $idle = New-PolicyUser "e2e-pa-idle-$runId" 30      # 정책 결정만 받고 이탈
    $slow = New-PolicyUser "e2e-pa-delay-$runId" 10     # DELAY (CAPTCHA + 후순위)
    $deny = New-PolicyUser "e2e-pa-deny-$runId" 10 0.93 # RESTRICT (c3에는 이미 입장한 상태)
    $free = New-PolicyUser "e2e-pa-allow-$runId" -1     # ALLOW (fixture 없음)
    $people = @($pass, $fail, $idle, $slow, $deny, $free)

    # --- REQUIRE_CAPTCHA: 요구 → 실패 → 통과
    $r = Demo POST '/concerts/c1/queue' $null $pass.Token -Expect @(403)
    $ch = New-Captcha 'c1' $pass.Token
    $wrong = Submit-Captcha 'c1' $pass.Token $ch 'wrong' -Expect @(403)
    $grant = (Submit-Captcha 'c1' $pass.Token $ch (Get-CaptchaAnswer $ch)).Data.captchaToken
    $joined = Demo POST '/concerts/c1/queue' $null $pass.Token @{ 'X-Captcha-Token' = $grant }
    Check '적용: REQUIRE_CAPTCHA 사용자는 CAPTCHA 없이 입장 불가, 통과 후 입장' ($r.Code -eq 'CAPTCHA_REQUIRED' -and $wrong.Code -eq 'CAPTCHA_INVALID' -and $joined.Status -eq 201) "$($r.Code)/$($wrong.Code)/$($joined.Status)"
    # 같은 사용자가 다른 공연에서도 CAPTCHA를 요구받는다 (공연별 결정 분리 확인용, 검증은 하지 않음)
    New-Captcha 'c2' $pass.Token | Out-Null
    # --- REQUIRE_CAPTCHA: 요구 → 실패 후 이탈
    $ch = New-Captcha 'c1' $fail.Token
    Submit-Captcha 'c1' $fail.Token $ch 'wrong' -Expect @(403) | Out-Null
    $r = Demo POST '/concerts/c1/queue' $null $fail.Token -Expect @(403)
    Check '적용: CAPTCHA 실패 사용자는 대기열에 들어가지 못함' ($r.Code -eq 'CAPTCHA_REQUIRED' -and (Demo GET '/concerts/c1/queue/me' $null $fail.Token).Data.status -eq 'NOT_JOINED') $r.Code
    # --- 정책 결정만 받고 이탈
    Demo POST '/concerts/c1/queue' $null $idle.Token -Expect @(403) | Out-Null
    # --- DELAY: CAPTCHA 통과 후 후순위 그룹 배치
    $ch = New-Captcha 'c2' $slow.Token
    Submit-Captcha 'c2' $slow.Token $ch 'wrong' -Expect @(403) | Out-Null
    $grant = (Submit-Captcha 'c2' $slow.Token $ch (Get-CaptchaAnswer $ch)).Data.captchaToken
    $joined = Demo POST '/concerts/c2/queue' $null $slow.Token @{ 'X-Captcha-Token' = $grant }
    Demo POST '/concerts/c2/queue' $null $slow.Token | Out-Null     # 이미 등록된 사용자의 재요청: 정책 재적용 없음
    # --- RESTRICT: 좌석 선점 거부(c3, 대기열은 이미 통과), 대기열 입장 거부(c2)
    $hold = Demo POST '/concerts/c3/seat-holds' @{ seatIds = @('Y-01') } $deny.Token -Expect @(403)
    $q = Demo POST '/concerts/c2/queue' $null $deny.Token -Expect @(403)
    Check '적용: RESTRICT 사용자는 좌석 선점·대기열 입장 모두 거부' ($hold.Code -eq 'BOOKING_RESTRICTED' -and $q.Code -eq 'QUEUE_RESTRICTED') "$($hold.Code)/$($q.Code)"
    # --- ALLOW
    $r = Demo POST '/concerts/c1/queue' $null $free.Token
    Check '적용: ALLOW 사용자는 바로 입장' ($r.Data.status -in @('ADMITTED', 'WAITING')) $r.Data.status

    # --- Outbox → BTS (스케줄러가 전송한다. 여기서는 기다리기만 한다)
    $sent = @(Wait-PolicySent @($people.Name) 9)
    Check 'Outbox: 정책 적용 기록 9건 적재, 전부 SENT' ($sent.Count -eq 9) "rows=$($sent.Count)"
    $apps = @(Get-Applications @($people.Bts))
    Check 'BTS DB: policy_application 9건 저장 (누락·중복 없음)' ($apps.Count -eq 9 -and @($apps.external_application_id | Sort-Object -Unique).Count -eq 9) "bts=$($apps.Count)"
    $idMismatch = @($sent | Where-Object { $o = $_; -not ($apps | Where-Object { $_.external_application_id -eq $o.external_event_id -and [long]$_.application_id -eq [long]$o.bts_id -and $_.t.Substring(0, 23) -eq $o.t.Substring(0, 23) }) })
    Check 'BTS DB: externalApplicationId·applicationId·적용 시각(밀리초)이 Outbox와 일치' ($idMismatch.Count -eq 0) "불일치 $($idMismatch.Count)건"
    function Of($person) { @($apps | Where-Object user_id -eq $person.Bts) }
    function Results($rows) { (@($rows | ForEach-Object { "$($_.concert_id):$($_.action)/$($_.result)" }) | Sort-Object) -join ' ' }
    $p = @(Of $pass); $pc1 = @($p | Where-Object concert_id -eq 'c1')
    Check '기록: CAPTCHA 요구·실패·통과가 같은 결정에 기록 (c1)' ((Results $pc1) -eq 'c1:REQUIRE_CAPTCHA/CHALLENGED c1:REQUIRE_CAPTCHA/FAILED c1:REQUIRE_CAPTCHA/PASSED' -and @($pc1.decision_id | Sort-Object -Unique).Count -eq 1) "$(Results $pc1) decision=$(($pc1.decision_id | Sort-Object -Unique) -join ',')"
    $pc2 = @($p | Where-Object concert_id -eq 'c2')
    Check '기록: 같은 사용자의 다른 공연(c2)은 별도 결정으로 분리' ((Results $pc2) -eq 'c2:REQUIRE_CAPTCHA/CHALLENGED' -and $pc2[0].decision_id -ne $pc1[0].decision_id -and $p.Count -eq 4) "c1=$($pc1[0].decision_id) c2=$($pc2[0].decision_id)"
    Check '기록: CAPTCHA 실패 후 이탈 = CHALLENGED + FAILED' ((Results (Of $fail)) -eq 'c1:REQUIRE_CAPTCHA/CHALLENGED c1:REQUIRE_CAPTCHA/FAILED') (Results (Of $fail))
    $idleDecisions = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM policy_decision WHERE user_id='$($idle.Bts)' AND action='REQUIRE_CAPTCHA' AND concert_id='c1'").c
    Check '기록: 정책 결정만 받고 적용되지 않으면 기록 없음' (@(Of $idle).Count -eq 0 -and $idleDecisions -eq 1) "결정 ${idleDecisions}건, 적용 $(@(Of $idle).Count)건"
    Check '기록: DELAY는 후순위 배치 DELAYED 1건만 (CAPTCHA 결과는 계약상 기록 없음)' ($joined.Status -eq 201 -and (Results (Of $slow)) -eq 'c2:DELAY/DELAYED') (Results (Of $slow))
    $d = @(Of $deny)
    Check '기록: RESTRICT는 선점 거부(BOOKING_ATTEMPT)·입장 거부(QUEUE_JOIN) 각각 BLOCKED' ((Results $d) -eq 'c2:RESTRICT/BLOCKED c3:RESTRICT/BLOCKED' -and ($d | Where-Object concert_id -eq 'c3').context -eq 'BOOKING_ATTEMPT' -and ($d | Where-Object concert_id -eq 'c2').context -eq 'QUEUE_JOIN') "$(Results $d)"
    Check '기록: ALLOW 사용자는 기록 없음' (@(Of $free).Count -eq 0) ''
    Check 'decisionId: 모든 기록이 같은 사용자·같은 공연·같은 조치의 결정을 가리킴' (-not ($apps | Where-Object { $_.d_user -ne $_.user_id -or $_.d_concert -ne $_.concert_id -or $_.d_action -ne $_.action })) ''
    $noConcert = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM policy_decision WHERE user_id IN ($(($people.Bts | ForEach-Object { "'$_'" }) -join ',')) AND concert_id IS NULL").c
    Check 'decisionId: 정책 결정 요청마다 공연 ID 전달 (concert_id NULL 없음)' ($noConcert -eq 0) "NULL ${noConcert}건"
    $ids = ($people.Bts | ForEach-Object { "'$_'" }) -join ','
    $ev = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM behavior_event WHERE user_id IN ($ids)").c
    $cur = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM risk_assessment_cursor WHERE user_id IN ($ids)").c
    Check 'AI 분리: 적용 기록은 behavior_event에 없고 AI 평가 대상이 되지 않음' ($ev -eq 0 -and $cur -eq 0) "behavior_event=$ev cursor=$cur"

    # --- 중복 전송 방지: Outbox에 동결된 payload를 그대로 다시 보낸다 (응답 유실 후 재전송 가정)
    $row = @(Invoke-Sql demo "SELECT o.payload FROM outbox_events o JOIN demo_users u ON u.id=o.user_id WHERE u.public_user_id='$($pass.Name)' AND o.event_type='POLICY_APPLICATION' ORDER BY o.id LIMIT 1")[0]
    $payload = $row.payload | ConvertFrom-Json
    $r = Bts POST '/policy-applications' $payload -Expect @(200, 201)
    $count = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM policy_application WHERE user_id IN ($ids)").c
    Check '중복: 같은 기록 재전송은 200, 같은 applicationId, 저장 건수 그대로' ($r.Status -eq 200 -and $count -eq 9 -and [long]$r.Data.applicationId -eq [long]($apps | Where-Object external_application_id -eq $payload.externalApplicationId).application_id) "status=$($r.Status) count=$count"
    $payload.result = 'PASSED'
    $r = Bts POST '/policy-applications' $payload -Expect @(409)
    $count = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM policy_application WHERE user_id IN ($ids)").c
    Check '중복: 같은 ID에 다른 내용은 409, 저장 건수 그대로' ($r.Status -eq 409 -and $count -eq 9) $r.Code

    # --- 관리자 조회 API (ticket-fds-admin docs/api-spec.md의 sanctions). 다른 시나리오의 기록과 섞이지 않게 증가분으로 본다.
    $after = @{ c1 = (Get-Sanctions $c1); c2 = (Get-Sanctions $c2); c3 = (Get-Sanctions $c3); all = (Get-Sanctions $all) }
    $d1 = Get-Delta $before.c1 $after.c1; $d2 = Get-Delta $before.c2 $after.c2; $d3 = Get-Delta $before.c3 $after.c3; $da = Get-Delta $before.all $after.all
    Check '관리자 API: 실제 제재 기록 있음 (sanctions.recorded)' ($after.all.Recorded -and $after.c1.Recorded) ''
    Check '관리자 API(c1): 실제 제재 사용자 +2, REQUIRE_CAPTCHA 적용 +2' ($d1.Users -eq 2 -and $d1.CaptchaUsers -eq 2 -and $d1.CaptchaApps -eq 2 -and $d1.DelayApps -eq 0 -and $d1.RestrictApps -eq 0) (Format-Delta $d1)
    Check '관리자 API(c1): CAPTCHA 요구 +2, 통과 +1, 실패 +2' ($d1.Challenged -eq 2 -and $d1.Passed -eq 1 -and $d1.Failed -eq 2) "challenged+$($d1.Challenged) passed+$($d1.Passed) failed+$($d1.Failed)"
    Check '관리자 API(c1): CAPTCHA 결과(기록 5건)가 제재 건수로 중복 집계되지 않음' ($pc1.Count + @(Of $fail).Count -eq 5 -and $d1.CaptchaApps -eq 2) "기록 5건 → applicationCount+$($d1.CaptchaApps)"
    Check '관리자 API(c2): 사용자 +3, REQUIRE_CAPTCHA +1, DELAY +1, RESTRICT +1' ($d2.Users -eq 3 -and $d2.CaptchaApps -eq 1 -and $d2.DelayApps -eq 1 -and $d2.DelayUsers -eq 1 -and $d2.RestrictApps -eq 1 -and $d2.Passed -eq 0 -and $d2.Failed -eq 0) (Format-Delta $d2)
    Check '관리자 API(c3): 좌석 선점 거부 RESTRICT +1' ($d3.Users -eq 1 -and $d3.RestrictApps -eq 1 -and $d3.CaptchaApps -eq 0 -and $d3.DelayApps -eq 0) (Format-Delta $d3)
    Check '관리자 API(요약): 실제 제재 고유 사용자 +4 (정책별 합이 아님), 적용 CAPTCHA +3 · DELAY +1 · RESTRICT +2' ($da.Users -eq 4 -and $da.CaptchaApps -eq 3 -and $da.DelayApps -eq 1 -and $da.RestrictApps -eq 2 -and $da.Challenged -eq 3 -and $da.Passed -eq 1 -and $da.Failed -eq 2) (Format-Delta $da)
    # 예상 제재(현재 Credit·점수 기준)는 결정만 받고 이탈한 사용자도 포함한다. 실제 제재와 다른 값이다.
    Check '관리자 API(요약): 예상 제재(+5 이상)와 실제 제재(+4)는 별개 집계' ($da.Expected -ge 5 -and $da.Users -eq 4) "expectedSanctionUsers+$($da.Expected) appliedUserCount+$($da.Users)"
}

# ---------------------------------------------------------------- 11. BTS 장애 중 정책 적용 기록 → 재시도 (#67)
if (Want 'policy-outage') {
    # 정책 결정에는 BTS가 필요하므로 "적용 직후 BTS 중지"로 만든다. 전송 주기(5초)가 먼저 돌면 이미 SENT라 다시 시도한다.
    $caught = $null
    for ($try = 1; $try -le 3 -and -not $caught; $try++) {
        $u = New-PolicyUser "e2e-po$try-$runId" 10 0.93
        $hold = Demo POST '/concerts/c3/seat-holds' @{ seatIds = @('Y-02') } $u.Token -Expect @(403)
        & (Join-Path $PSScriptRoot 'Stop-E2E.ps1') -Only bts | Out-Null
        Start-Sleep -Seconds 2
        $row = @(Get-PolicyOutbox @($u.Name))[0]
        if ($row -and $row.delivery_status -ne 'SENT') { $caught = $u }
        else { & (Join-Path $PSScriptRoot 'Start-E2E.ps1') -Only bts -SkipCompose | Out-Null }
    }
    if (-not $caught) {
        Write-Output '[SKIP] policy-outage: 세 번 모두 BTS 중지 전에 전송이 끝났습니다. 다시 실행하세요.'
    } else {
        Start-Sleep -Seconds 12
        $row = @(Get-PolicyOutbox @($caught.Name))[0]
        Check '장애: BTS 중지 중 정책 적용 기록은 Outbox에 RETRY로 대기' ($row.delivery_status -in @('RETRY', 'IN_FLIGHT', 'PENDING') -and [int]$row.retries -ge 1) "status=$($row.delivery_status) error=$($row.err) retries=$($row.retries)"
        # BTS 장애 중에도 티켓팅 서비스는 동작한다: 이미 입장한 사용자의 좌석 선점은 허용되고(기록 없음), 공연 조회도 정상.
        $concerts = Demo GET '/concerts'
        $hold2 = Demo POST '/concerts/c3/seat-holds' @{ seatIds = @('Y-03') } $caught.Token -Expect @(201, 409)
        Check '장애: BTS 중지 중 Demo 동작 유지 (조회 200, 입장한 사용자의 선점은 정책 확인 없이 진행)' ($concerts.Status -eq 200 -and $hold2.Status -in @(201, 409)) "concerts=$($concerts.Status) hold=$($hold2.Status) $($hold2.Code)"
        & (Join-Path $PSScriptRoot 'Start-E2E.ps1') -Only bts -SkipCompose | Out-Null
        $sent = @(Wait-PolicySent @($caught.Name) 1 300)
        $stored = @(Get-Applications @($caught.Bts))
        Check '장애: BTS 복구 후 재전송되어 한 번만 저장, 장애 중 허용된 선점은 기록 없음' ($sent.Count -eq 1 -and $stored.Count -eq 1 -and $stored[0].result -eq 'BLOCKED' -and $stored[0].external_application_id -eq $row.external_event_id -and $stored[0].t.Substring(0, 23) -eq $row.t.Substring(0, 23)) "outbox=$($sent.Count) bts=$($stored.Count) retries=$($sent[0].retries)"
    }
}

$script:Results | Format-Table -AutoSize | Out-String -Width 220
$total = $script:Results.Count
$failed = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output "합계: PASS $($total - $failed) / FAIL $failed"
