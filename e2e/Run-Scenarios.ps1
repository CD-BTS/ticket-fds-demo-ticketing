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
        if ([int]$pendingAttempts -eq 0 -and $rows.Count -gt 0 -and -not ($rows | Where-Object delivery_status -ne 'SENT')) { $rows }
    } $Seconds 'Outbox 전송 완료'
}

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

$script:Results | Format-Table -AutoSize | Out-String -Width 220
$total = $script:Results.Count
$failed = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output "합계: PASS $($total - $failed) / FAIL $failed"
