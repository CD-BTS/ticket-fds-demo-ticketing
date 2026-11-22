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
    $summary = Bts GET '/dashboard/summary?serviceId=demo-ticketing' -Admin -Expect @(200, 401, 403, 404)
    Check '관리자 API: 대시보드 요약 eventsByType.CHECK_IN 집계' ($summary.Status -eq 200 -and [int]$summary.Data.eventsByType.CHECK_IN -ge 1) "status=$($summary.Status) CHECK_IN=$($summary.Data.eventsByType.CHECK_IN)"
    $joined = (Bts GET "/admin/concerts/$concert/users?serviceId=demo-ticketing" -Admin).Data
    Check '관리자 API: 공연별 참여 사용자에 표시' (@($joined.content | ForEach-Object { $_.user.userId }) -contains $btsUser) ''

    # --- 미구현 확인(판정 대상 아님): BTS는 CHECK_IN을 behavior_event에만 저장한다.
    $history = [int](Invoke-Sql bts "SELECT COUNT(*) c FROM booking_history WHERE user_id='$btsUser'").c
    $detail = (Bts GET "/admin/users/$btsUser" -Admin).Data
    Write-Output "[INFO] BTS booking_history 행 수(이 사용자) = $history  (CHECK_IN → 관람 이력 적재 미구현, 후속 이슈)"
    Write-Output "[INFO] 관리자 사용자 상세 최상위 필드: $((@($detail.PSObject.Properties.Name)) -join ',')"
    $adminSummary = Bts GET '/admin/summary?serviceId=demo-ticketing' -Admin -Expect @(200, 400, 401, 403, 404, 500)
    Write-Output "[INFO] 프론트엔드가 호출하는 GET /api/v1/admin/summary 응답 상태 = $($adminSummary.Status)"
}

$script:Results | Format-Table -AutoSize | Out-String -Width 220
$total = $script:Results.Count
$failed = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output "합계: PASS $($total - $failed) / FAIL $failed"
