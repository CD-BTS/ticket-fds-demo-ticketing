# #71 Showcase 검증. 두 DB와 관리자 API를 실제로 조회해 결과를 표와 PASS/FAIL로 보여 준다. 데이터를 바꾸지 않는다.
# 결과는 .run/verify-<시각>.json 에도 저장한다.
param(
    [int]$Seed = 7171,
    # 서버 재시작 후 영속성 확인: 이전에 저장한 기준값(.run/persistence-baseline.json)과 비교한다. -SaveBaseline 으로 먼저 저장.
    [switch]$SaveBaseline,
    [switch]$CompareBaseline
)
. (Join-Path $PSScriptRoot 'Showcase-Common.ps1')
Use-ShowcaseApi
$py = Get-PythonCommand
$svc = 'demo-ticketing'
$report = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o') }
# 관리자 API 조회. E2E의 Bts 함수는 15초 제한이라 전체 규모의 공연 통계(수십 초)가 시간 초과된다. 응답 시간도 기록한다.
$script:AdminTimes = New-Object System.Collections.Generic.List[object]
function AdminGet([string]$Path) {
    $t0 = Get-Date
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Headers @{ 'X-API-Key' = $E2E.adminKey } ($E2E.btsUrl + '/api/v1' + $Path)
    $script:AdminTimes.Add([pscustomobject]@{ API = ($Path -replace '\?.*', ''); 초 = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1) })
    [pscustomobject]@{ Status = [int]$r.StatusCode; Data = ([System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json).data }
}
function Table($rows, [string]$title) { Write-Output ''; Write-Output "--- $title"; $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output }

# ---------------------------------------------------------------- 환경·스키마
$health = Invoke-RestMethod "$($E2E.aiUrl)/health"
Check 'AI 서버 health: 최신 모델 로드' ($health.status -eq 'ok' -and $health.modelVersion -like 'fds-if-v4*') "model=$($health.modelVersion) features=$($health.featureDefinitionVersion) threshold=$($health.anomalyThreshold)"
$btsTables = @(Invoke-ShowcaseSql bts "SELECT table_name t FROM information_schema.tables WHERE table_schema=DATABASE()").t
$needBts = 'user_account', 'behavior_event', 'user_credit', 'credit_history', 'risk_assessment', 'policy_decision', 'booking_history', 'user_card', 'concert', 'risk_assessment_cursor', 'risk_assessment_attempt', 'credit_calculation', 'policy_application'
Check 'BTS DB: 최신 schema.sql 13개 테이블' (-not ($needBts | Where-Object { $btsTables -notcontains $_ })) "$($btsTables.Count) tables"
$ck = @(Invoke-ShowcaseSql demo "SELECT check_clause c FROM information_schema.check_constraints WHERE constraint_schema=DATABASE() AND constraint_name='ck_outbox_type'")
Check 'Demo DB: 정책 적용 기록 Outbox(09) 적용' ($ck.Count -eq 1 -and $ck[0].c -match 'POLICY_APPLICATION') ''
$vols = @(docker volume ls --filter "label=com.docker.compose.project=$($SC.Project)" --format '{{.Name}}')
Check 'Docker: Showcase named volume 3개 (데이터 영속)' ($vols.Count -eq 3) ($vols -join ', ')

# ---------------------------------------------------------------- 공연
$plan = Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir 'plan-summary.json') | ConvertFrom-Json
$state = Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir 'seed-state.json') | ConvertFrom-Json
$report.anchor = $state.anchor
$demoC = @(Invoke-ShowcaseSql demo "SELECT c.public_id id, c.title, DATE_FORMAT(c.start_at,'%Y-%m-%dT%H:%i:%sZ') s, COUNT(s.id) seats, SUM(s.state='BOOKED') booked FROM concerts c LEFT JOIN concert_seats s ON s.concert_id=c.id GROUP BY c.id ORDER BY c.public_id")
$btsC = @(Invoke-ShowcaseSql bts "SELECT concert_id id, name, DATE_FORMAT(starts_at,'%Y-%m-%dT%H:%i:%sZ') s FROM concert WHERE service_id='$svc' ORDER BY concert_id")
$mismatch = @($demoC | Where-Object { $d = $_; -not ($btsC | Where-Object { $_.id -eq $d.id -and $_.name -eq $d.title -and $_.s -eq $d.s }) })
Check '공연: Demo·BTS 공연 ID·이름·시작 시각 일치' ($demoC.Count -ge 10 -and $mismatch.Count -eq 0) "demo=$($demoC.Count) bts=$($btsC.Count) 불일치=$($mismatch.id -join ',')"

# 공연별 BTS 실측 통계 (합성 이력 + 실제 티켓팅 모두 포함)
$stats = @(Invoke-ShowcaseSql bts @"
SELECT JSON_UNQUOTE(JSON_EXTRACT(e.metadata,'$.concertId')) concert,
  COUNT(DISTINCT e.user_id) users,
  COUNT(DISTINCT CASE WHEN e.event_type='BOOKING_ATTEMPT' THEN JSON_UNQUOTE(JSON_EXTRACT(e.metadata,'$.attemptId')) END) attempts,
  COUNT(DISTINCT CASE WHEN e.event_type='BOOKING_ATTEMPT' AND JSON_UNQUOTE(JSON_EXTRACT(e.metadata,'$.stage'))='COMPLETED' THEN JSON_UNQUOTE(JSON_EXTRACT(e.metadata,'$.attemptId')) END) succeeded,
  COUNT(DISTINCT CASE WHEN e.event_type='BOOKING' THEN e.booking_id END) bookings,
  SUM(CASE WHEN e.event_type='BOOKING' THEN JSON_LENGTH(JSON_EXTRACT(e.metadata,'$.ticketIds')) ELSE 0 END) tickets,
  COUNT(DISTINCT CASE WHEN e.event_type='CANCEL' THEN e.booking_id END) cancels,
  SUM(CASE WHEN e.event_type='CANCEL' THEN JSON_LENGTH(JSON_EXTRACT(e.metadata,'$.ticketIds')) ELSE 0 END) cancelled_tickets,
  SUM(e.event_type='CHECK_IN') checkins,
  DATE_FORMAT(MIN(e.occurred_at),'%m-%d %H:%i') first_event, DATE_FORMAT(MAX(e.occurred_at),'%m-%d %H:%i') last_event
FROM behavior_event e WHERE e.service_id='$svc' GROUP BY concert ORDER BY concert
"@)
# booking_history: 티켓 1장당 1행, event_id = 공연 ID, booking_reference = 예매 ID
$hist = @(Invoke-ShowcaseSql bts "SELECT event_id concert, SUM(status='COMPLETED') attended, SUM(status='NO_SHOW') no_show, SUM(status='BOOKED') booked, SUM(status='CANCELLED') cancelled FROM booking_history GROUP BY event_id")
# 대표 계정이 Demo로 실제 예매한 매수. 합성 이력과는 별개의 좌석 상태라 좌석 수 비교에서 따로 본다.
$liveSeats = @(Invoke-ShowcaseSql demo "SELECT c.public_id concert, COUNT(*) n FROM bookings b JOIN concerts c ON c.id=b.concert_id JOIN booking_seats s ON s.booking_id=b.id WHERE b.status='CONFIRMED' GROUP BY c.public_id")
$rows = foreach ($c in $plan.concerts) {
    $s = $stats | Where-Object concert -eq $c.concertId; $h = $hist | Where-Object concert -eq $c.concertId
    $live = [int]($liveSeats | Where-Object concert -eq $c.concertId).n
    $failed = [int]$s.attempts - [int]$s.succeeded
    [pscustomobject]@{
        공연 = $c.concertId; 상태 = $c.status; 좌석 = $c.seats; 목표참여 = $c.targetParticipants; 참여자 = [int]$s.users
        시도 = [int]$s.attempts; 성공 = [int]$s.succeeded; 실패 = $failed; 예매 = [int]$s.bookings; 매수 = [int]$s.tickets
        취소 = [int]$s.cancels; 취소매수 = [int]$s.cancelled_tickets; 입장 = [int]$s.checkins; 미입장 = [int]$h.no_show
        '경쟁률' = if ($c.seats) { [Math]::Round([int]$s.users / $c.seats, 2) } else { 0 }
        유효매수 = [int]$s.tickets - [int]$s.cancelled_tickets; 실제예매매수 = $live
        합성유효매수 = [int]$s.tickets - [int]$s.cancelled_tickets - $live; 기간 = "$($s.first_event)~$($s.last_event)"
    }
}
Table $rows '공연별 결과 (BTS behavior_event·booking_history 실측)'
$report.concerts = $rows
Table ($rows | Select-Object 공연, 좌석, 매수, 취소매수, 합성유효매수, 실제예매매수, 입장, 미입장, 경쟁률, 기간) '공연별 좌석·입장 (합성 이력과 대표 계정 실제 예매 구분)'
$over = @($rows | Where-Object { $_.합성유효매수 -gt $_.좌석 })
Check '공연: 합성 이력의 유효 예매 매수(예매−취소)가 좌석 수 이하' ($over.Count -eq 0) ($over.공연 -join ',')
Write-Output '[INFO] 대표 계정의 실제 예매는 Demo 좌석 테이블 기준이라 합성 이력의 좌석 소진과 별개다 (README 10절).'
$scheduledLeak = @($rows | Where-Object { $_.상태 -eq 'SCHEDULED' -and $_.예매 -gt 0 })
Check '공연: 예매 예정 공연에 예매 완료 이력 없음' ($scheduledLeak.Count -eq 0) ''
$onSaleCheck = @($rows | Where-Object { $_.상태 -eq 'ON_SALE' -and $_.미입장 -gt 0 })
Check '공연: 진행 중 공연에 미입장 판정 없음' ($onSaleCheck.Count -eq 0) ''
$ended = @($rows | Where-Object 상태 -eq 'ENDED')
Check '공연: 종료 공연에 입장·미입장 모두 존재' ($ended.Count -gt 0 -and -not ($ended | Where-Object { $_.입장 -eq 0 -or $_.미입장 -eq 0 })) ''
$order = @(Invoke-ShowcaseSql bts @"
SELECT COUNT(*) n FROM behavior_event b JOIN behavior_event x ON x.user_id=b.user_id AND x.booking_id=b.booking_id AND x.event_type IN ('CANCEL','CHECK_IN')
JOIN concert c ON c.concert_id=JSON_UNQUOTE(JSON_EXTRACT(b.metadata,'$.concertId'))
WHERE b.event_type='BOOKING' AND (x.occurred_at < b.occurred_at OR (x.event_type='CANCEL' AND x.occurred_at >= c.starts_at) OR b.occurred_at >= c.starts_at)
"@)
Check '시각 정합성: 예매 < 취소·입장, 예매·취소는 공연 시작 전' ([int]$order[0].n -eq 0) "위반 $($order[0].n)건"

# ---------------------------------------------------------------- 사용자·이벤트
$users = Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir 'users.json') | ConvertFrom-Json
$planUsers = (& $py -X utf8 (Join-Path $PSScriptRoot 'seed\showcase_seed.py') users --seed $Seed --run-dir $RunDir) | ConvertFrom-Json
$typeOf = @{}; foreach ($u in $planUsers) { $typeOf[$u.bts] = $u.type }
$btsUsers = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM user_account WHERE service_id='$svc' AND external_user_id LIKE 'sc-u%'").n
$events = @(Invoke-ShowcaseSql bts "SELECT event_type t, COUNT(*) n FROM behavior_event WHERE service_id='$svc' GROUP BY event_type")
Check '사용자: 적재한 사용자 전원 BTS 등록' ($btsUsers -eq @($users.loaded).Count) "BTS=$btsUsers loaded=$(@($users.loaded).Count)"
$report.users = $btsUsers; $report.events = $events
Write-Output ("이벤트: " + (($events | ForEach-Object { "$($_.t)=$($_.n)" }) -join ', '))
$multi = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM (SELECT user_id FROM behavior_event WHERE event_type='BOOKING_ATTEMPT' GROUP BY user_id HAVING COUNT(DISTINCT JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.concertId')))>1) x").n
Write-Output "여러 공연에 참여한 사용자: ${multi}명"
$report.multiConcertUsers = $multi
$dupIds = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM (SELECT external_event_id FROM behavior_event GROUP BY service_id, external_event_id HAVING COUNT(*)>1) x").n
Check '중복: externalEventId 중복 저장 없음' ($dupIds -eq 0) ''

# 사용자 ID 연동: Demo에 로그인한 사용자의 bts_user_id = BTS가 같은 externalUserId로 등록한 UUID
$demoUsers = @(Invoke-ShowcaseSql demo "SELECT public_user_id ext, IFNULL(bts_user_id,'') bts FROM demo_users WHERE public_user_id LIKE 'sc-u%'")
$wrong = @($demoUsers | Where-Object { $_.bts -and $_.bts -ne $users.users.($_.ext) })
Check '사용자 연동: Demo 사용자 BTS UUID = 이력 적재 시 받은 UUID (externalUserId 동일)' ($demoUsers.Count -gt 0 -and $wrong.Count -eq 0) "demo 로그인 $($demoUsers.Count)명, 불일치 $($wrong.Count)명"

# ---------------------------------------------------------------- AI·Credit
$cur = @(Invoke-ShowcaseSql bts "SELECT last_status s, COUNT(*) n FROM risk_assessment_cursor GROUP BY last_status")
$pending = [int](Invoke-ShowcaseSql bts "SELECT COUNT(DISTINCT e.user_id) n FROM behavior_event e LEFT JOIN risk_assessment_cursor c ON c.user_id=e.user_id WHERE e.occurred_at <= UTC_TIMESTAMP() AND (e.event_id > COALESCE(c.last_event_id,0) OR e.occurred_at > c.checked_at)").n
Check 'AI: 평가 대기 사용자 0명 (cursor 기준 완료)' ($pending -eq 0) "cursor: $(($cur | ForEach-Object { "$($_.s)=$($_.n)" }) -join ', ')"
$models = @(Invoke-ShowcaseSql bts "SELECT model_version v, COUNT(*) n FROM risk_assessment GROUP BY model_version")
Check 'AI: 저장된 점수는 모두 실제 모델 버전 (fixture 없음)' (-not ($models | Where-Object { $_.v -ne $health.modelVersion })) (($models | ForEach-Object { "$($_.v)=$($_.n)" }) -join ', ')

$latest = @(Invoke-ShowcaseSql bts @"
SELECT u.user_id id, c.credit_score credit, c.tier, a.anomaly_score score,
  CASE WHEN a.anomaly_score IS NULL THEN (CASE WHEN c.credit_score>=40 THEN 'ALLOW' WHEN c.credit_score>=20 THEN 'REQUIRE_CAPTCHA' ELSE 'DELAY' END)
       WHEN c.credit_score<20 AND a.anomaly_score>=0.85 THEN 'RESTRICT' WHEN c.credit_score<20 OR a.anomaly_score>=0.70 THEN 'DELAY'
       WHEN c.credit_score<40 OR a.anomaly_score>=0.50 THEN 'REQUIRE_CAPTCHA' ELSE 'ALLOW' END expected
FROM user_account u JOIN user_credit c ON c.user_id=u.user_id
LEFT JOIN risk_assessment a ON a.assessment_id=(SELECT MAX(x.assessment_id) FROM risk_assessment x WHERE x.user_id=u.user_id)
WHERE u.service_id='$svc' AND u.external_user_id LIKE 'sc-u%'
"@)
$byType = $latest | Group-Object { $typeOf[$_.id] } | ForEach-Object {
    $g = @($_.Group); $scored = @($g | Where-Object { $_.score -ne 'NULL' -and $_.score })
    $vals = @($scored | ForEach-Object { [double]$_.score } | Sort-Object)
    [pscustomobject]@{
        유형 = $_.Name; 사용자 = $g.Count; 평가됨 = $scored.Count
        평균점수 = if ($vals) { [Math]::Round(($vals | Measure-Object -Average).Average, 3) } else { $null }
        중앙값 = if ($vals) { [Math]::Round($vals[[int][Math]::Floor($vals.Count / 2)], 3) } else { $null }
        '탐지(>=0.5)' = @($vals | Where-Object { $_ -ge 0.5 }).Count
        탐지율 = if ($vals) { '{0:P1}' -f (@($vals | Where-Object { $_ -ge 0.5 }).Count / $vals.Count) } else { '-' }
        평균Credit = [Math]::Round((@($g | ForEach-Object { [int]$_.credit }) | Measure-Object -Average).Average, 1)
        NORMAL = @($g | Where-Object tier -eq 'NORMAL').Count; SUSPICIOUS = @($g | Where-Object tier -eq 'SUSPICIOUS').Count
        HIGH_RISK = @($g | Where-Object tier -eq 'HIGH_RISK').Count; BASE = @($g | Where-Object tier -eq 'BASE').Count
        ALLOW = @($g | Where-Object expected -eq 'ALLOW').Count; CAPTCHA = @($g | Where-Object expected -eq 'REQUIRE_CAPTCHA').Count
        DELAY = @($g | Where-Object expected -eq 'DELAY').Count; RESTRICT = @($g | Where-Object expected -eq 'RESTRICT').Count
    }
} | Sort-Object 유형
Table ($byType | Select-Object 유형, 사용자, 평가됨, 평균점수, 중앙값, '탐지(>=0.5)', 탐지율) '사용자 유형(생성 시나리오)별 실제 AI 이상 점수·탐지 결과'
Table ($byType | Select-Object 유형, 평균Credit, NORMAL, SUSPICIOUS, HIGH_RISK, BASE, ALLOW, CAPTCHA, DELAY, RESTRICT) '사용자 유형별 Credit 등급·적용 예정 정책 분포'
$report.byType = $byType
$credit = @(Invoke-ShowcaseSql bts "SELECT reason, COUNT(*) n FROM credit_history GROUP BY reason")
$calc = @(Invoke-ShowcaseSql bts "SELECT kind, COUNT(*) n FROM credit_calculation GROUP BY kind")
Write-Output ("credit_history: " + (($credit | ForEach-Object { "$($_.reason)=$($_.n)" }) -join ', '))
Write-Output ("credit_calculation: " + (($calc | ForEach-Object { "$($_.kind)=$($_.n)" }) -join ', '))
$report.creditHistory = $credit; $report.creditCalculation = $calc
Check 'Credit: AI 평가 반영 이력 존재' ([bool]($credit | Where-Object reason -eq 'AI 이상도 평가 반영')) ''
Check 'Credit: 미입장(NO_SHOW) 반영 이력 존재' ([bool]($credit | Where-Object reason -like '*NO_SHOW*')) ''
$noAssess = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM user_account u WHERE u.external_user_id LIKE 'sc-u%' AND NOT EXISTS (SELECT 1 FROM risk_assessment_attempt a WHERE a.user_id=u.user_id)").n
Check '사용자: AI 평가 이력이 없는 신규 사용자 포함' ($noAssess -gt 0) "${noAssess}명"

# ---------------------------------------------------------------- 실제 정책 적용
$apps = @(Invoke-ShowcaseSql bts "SELECT action, result, COUNT(*) n, COUNT(DISTINCT user_id) users FROM policy_application GROUP BY action, result ORDER BY action, result")
$dec = @(Invoke-ShowcaseSql bts "SELECT context, action, COUNT(*) n FROM policy_decision GROUP BY context, action ORDER BY context, action")
Table $apps '실제 정책 적용 기록 (policy_application)'
Table $dec '정책 결정 (policy_decision)'
$report.policyApplications = $apps; $report.policyDecisions = $dec
foreach ($a in 'REQUIRE_CAPTCHA', 'DELAY', 'RESTRICT') { Check "정책 적용: $a 실제 적용 기록 존재" ([bool]($apps | Where-Object action -eq $a)) '' }
Check '정책 적용: CAPTCHA 통과·실패 모두 기록' ([bool]($apps | Where-Object result -eq 'PASSED') -and [bool]($apps | Where-Object result -eq 'FAILED')) ''
Check '정책 결정: ALLOW 결정 존재' ([bool]($dec | Where-Object action -eq 'ALLOW')) ''
$unsent = [int](Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM outbox_events WHERE delivery_status<>'SENT'").n
$outbox = @(Invoke-ShowcaseSql demo "SELECT event_type t, COUNT(*) n FROM outbox_events GROUP BY event_type")
Check 'Outbox: Demo의 행동 이벤트·정책 적용 기록 전부 SENT' ($unsent -eq 0) (($outbox | ForEach-Object { "$($_.t)=$($_.n)" }) -join ', ')
$appCount = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM policy_application").n
$outApp = [int](Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM outbox_events WHERE event_type='POLICY_APPLICATION'").n
Check 'Outbox→BTS: 정책 적용 기록 건수 일치' ($appCount -eq $outApp) "demo=$outApp bts=$appCount"

$livePath = Join-Path $RunDir 'live-state.json'
if (Test-Path $livePath) {
    $live = (Get-Content -Raw -Encoding UTF8 $livePath | ConvertFrom-Json).done
    $liveRows = foreach ($p in $live.PSObject.Properties) {
        $v = $p.Value
        $actual = @(Invoke-ShowcaseSql bts "SELECT action FROM policy_decision WHERE user_id='$($v.bts)' AND context='QUEUE_JOIN' ORDER BY decision_id LIMIT 1")
        [pscustomobject]@{ 계정 = $v.ext; 유형 = $v.type; 공연 = $v.concert; 예상 = $v.expected; 실제결정 = $actual[0].action; 결과 = $v.result }
    }
    Table $liveRows '대표 계정 실제 티켓팅 결과'
    $report.live = $liveRows
    $diff = @($liveRows | Where-Object { $_.실제결정 -and $_.예상 -ne $_.실제결정 })
    Write-Output "예상 정책과 실제 첫 결정이 다른 대표 계정: $($diff.Count)명 (선정 이후 재평가 등 실제 동작 결과, 수정하지 않음)"
    $ci = @($live.PSObject.Properties.Value | Where-Object { $_.checkin })
    Check '실제 티켓팅: 동적 QR 검표 입장·중복 입장 거부' ($ci.Count -gt 0 -and -not ($ci | Where-Object { $_.checkin.duplicate -ne 'TICKET_ALREADY_CHECKED_IN' })) "$($ci.Count)명"
    $checkinBts = if ($ci.Count -gt 0) { [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM behavior_event e JOIN user_account u ON u.user_id=e.user_id WHERE e.event_type='CHECK_IN' AND e.ticket_id IN ($((@($ci | ForEach-Object { "'$($_.checkin.ticket)'" })) -join ','))").n } else { 0 }
    Check '실제 티켓팅: 검표 CHECK_IN이 BTS에 저장' ($ci.Count -gt 0 -and $checkinBts -eq $ci.Count) "$checkinBts/$($ci.Count)"
}

# ---------------------------------------------------------------- 관리자 API (대시보드 화면이 쓰는 경로)
$sum = (AdminGet "/admin/summary?serviceId=$svc").Data
Check '관리자 API: 대시보드 요약' ([bool]$sum) "keys=$((@($sum.PSObject.Properties.Name) | Select-Object -First 12) -join ',')"
$report.adminSummary = $sum
$clist = (AdminGet "/admin/concerts?serviceId=$svc&page=0&size=20&sort=startsAt,desc").Data
Check '관리자 API: 공연 목록 10개 이상' (@($clist.content).Count -ge 10) "$(@($clist.content).Count)"
$detailRows = foreach ($c in @('sc01', 'sc05', 'sc08')) {
    $d = (AdminGet "/admin/concerts/$($c)?serviceId=$svc").Data
    $users = (AdminGet "/admin/concerts/$c/users?serviceId=$svc&page=0&size=5").Data
    # 버킷은 최대 500개: 1시간 단위로 최근 20일 (관리자 화면 ConcertTrendChart와 같은 파라미터 형식)
    $from = (Get-Date).ToUniversalTime().AddDays(-20).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $to = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $trend = AdminGet "/admin/concerts/$c/trends?serviceId=$svc&from=$from&to=$to&intervalSeconds=3600"
    [pscustomobject]@{ 공연 = $c; 응답필드 = (@($d.PSObject.Properties.Name) -join ','); 참여자페이지 = $users.totalElements; 추이버킷 = @($trend.Data.buckets).Count; 추이필드 = (@($trend.Data.PSObject.Properties.Name) -join ',') }
}
Table ($detailRows | Select-Object 공연, 참여자페이지, 추이버킷) '관리자 API: 공연 상세·참여자·추이'
$sample = $latest | Where-Object { $typeOf[$_.id] -eq 'macro_multi' -and $_.score -ne 'NULL' } | Select-Object -First 1
if ($sample) {
    $ud = (AdminGet "/admin/users/$($sample.id)").Data
    $ch = (AdminGet "/admin/users/$($sample.id)/credit-history").Data
    $as = (AdminGet "/admin/users/$($sample.id)/assessments").Data
    Check '관리자 API: 사용자 상세·Credit 이력·AI 평가 이력' ([bool]$ud -and @($ch.content).Count -ge 1 -and @($as.content).Count -ge 1) "user=$($sample.id) expectedPolicy=$($ud.expectedPolicy) credit이력=$(@($ch.content).Count) 평가=$(@($as.content).Count)"
}

Table $AdminTimes '관리자 API 응답 시간 (전체 규모)'
$report.adminApiSeconds = $AdminTimes

# ---------------------------------------------------------------- 영속성 (재시작 전후 비교)
$snapshot = [ordered]@{
    users = $btsUsers; events = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM behavior_event").n
    assessments = [int](Invoke-ShowcaseSql bts "SELECT COUNT(*) n FROM risk_assessment").n
    applications = $appCount; demoBookings = [int](Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM bookings").n
    checkedIn = [int](Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM admission_tickets WHERE status='CHECKED_IN'").n
    devices = [int](Invoke-ShowcaseSql demo "SELECT COUNT(*) n FROM ticket_device_bindings").n
    secretsCreatedAt = (Get-ShowcaseSecrets).createdAt; serviceKeyHash = (Get-Sha256Hex (Get-ShowcaseSecrets).serviceKey)
}
$basePath = Join-Path $RunDir 'persistence-baseline.json'
if ($SaveBaseline) { $snapshot | ConvertTo-Json | Set-Content -Encoding UTF8 $basePath; Write-Output "기준값 저장: $basePath" }
if ($CompareBaseline) {
    $b = Get-Content -Raw -Encoding UTF8 $basePath | ConvertFrom-Json
    $diffs = @($snapshot.Keys | Where-Object { "$($b.$_)" -ne "$($snapshot[$_])" -and $_ -notin @('events', 'assessments') })
    Check '영속성: 재시작 후 사용자·정책 기록·예매·검표·기기·인증 정보 유지' ($diffs.Count -eq 0) (($snapshot.Keys | ForEach-Object { "$_=$($b.$_)→$($snapshot[$_])" }) -join ' ')
    Check '영속성: 재시작 후 이벤트·평가 수 감소 없음' ([int]$snapshot.events -ge [int]$b.events -and [int]$snapshot.assessments -ge [int]$b.assessments) "events $($b.events)→$($snapshot.events), assessments $($b.assessments)→$($snapshot.assessments)"
    # 저장된 키로 실제 인증이 되는지: 서비스 키·관리자 키 호출(위의 API 검증), 재시작 전에 등록한 기기로 새 QR을 만들어 검표기(X-Gate-Key)에 스캔한다.
    # 서버는 저장된 TOTP 비밀키를 티켓 서명 키(TICKET_SECRET_KEY)로 복호화해 QR을 검증한 뒤에야 "이미 입장"(409)을 판단하므로,
    # 409 TICKET_ALREADY_CHECKED_IN이면 검표 키·티켓 서명 키·기기 등록이 모두 재시작 후에도 유효하다는 뜻이다.
    $saved = @((Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir 'live-state.json') | ConvertFrom-Json).done.PSObject.Properties.Value | Where-Object { $_.checkin.device })
    foreach ($s in $saved) {
        $dev = Restore-TicketDevice $s.checkin.device
        $r = Gate POST '/check-ins' @{ qr = (New-TicketQr $dev $s.checkin.ticket) } -Expect @(200, 201, 400, 403, 409, 500)
        Check "영속성: 재시작 전 등록 기기의 동적 QR이 검증됨 ($($s.ext))" ($r.Status -eq 409 -and $r.Code -eq 'TICKET_ALREADY_CHECKED_IN') "status=$($r.Status) code=$($r.Code)"
    }
    if (-not $saved) { Write-Output '[INFO] 저장된 기기 키가 없어 QR 재검증을 건너뜀 (live 단계에서 생성)' }
}
$report.snapshot = $snapshot

# 데이터 유효 기간: AI Feature는 평가 시각 기준 최근 30일
$oldest = (Invoke-ShowcaseSql bts "SELECT DATE_FORMAT(MIN(occurred_at),'%Y-%m-%dT%H:%i:%sZ') t FROM behavior_event").t
$valid = ([datetime]::Parse($oldest).ToUniversalTime().AddDays(30))
Write-Output ''
Write-Output "가장 오래된 행동 이벤트: $oldest → 이 이벤트는 $($valid.ToString('yyyy-MM-dd HH:mm'))Z 이후 평가부터 30일 창 밖으로 빠집니다."
$report.oldestEvent = $oldest; $report.windowUntil = $valid.ToString('o')

$fail = @($Results | Where-Object Result -eq 'FAIL')
$report.checks = $Results
$out = Join-Path $RunDir ("verify-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $out
Write-Output ''
Write-Output "검증: PASS $(@($Results | Where-Object Result -eq 'PASS').Count) / FAIL $($fail.Count)  (결과 $out)"
if ($fail.Count) { exit 1 }