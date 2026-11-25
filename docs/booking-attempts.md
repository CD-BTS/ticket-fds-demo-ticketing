# 예매 시도 이벤트 명세

## 식별자와 권한

attemptId는 소문자 정규 UUID이며 사용자·공연·서비스에 고정된다. 동일 ID의 같은 시작 요청은 재사용하고 다른 사용자나 공연에 붙일 수 없다. 선택 clientOccurredAt은 offset 포함 ISO 8601 문자열이며 최대 40자다. 클라이언트 시각과 서버의 started_at/recordedAt을 혼동하지 않는다.

transitionId는 클라이언트 전이·CAPTCHA 검증 재전송을 구분하는 UUID다. 서버 전이는 의미 있는 문자열 식별자를 생성한다. 같은 attempt/transition의 같은 내용은 기존 결과를 반환하고 다른 내용은 DATA_CONFLICT다. 각 새 전이는 attempt 행 잠금 아래 sequence를 증가시킨다.

## 단계와 상태

| 단계 | 기록 근거 |
|---|---|
| STARTED/ENTERED | 시작 API, sequence=1 |
| CAPTCHA/ENTERED | 서버 challenge 발급 |
| CAPTCHA/REJECTED | 식별자가 있는 검증 실패 요청 |
| CAPTCHA/SUCCEEDED | 서버 CAPTCHA 검증 성공 |
| QUEUE/ENTERED | 서버 관측 WAITING |
| QUEUE/SUCCEEDED | 서버 관측 ADMITTED |
| SEAT_SELECTION/ENTERED | 입장 후 클라이언트 화면 관측 |
| SEAT_HOLD/SUCCEEDED | 실제 hold 생성·연결 성공 |
| SEAT_HOLD/REJECTED | 좌석/입장 오류가 확인된 요청 |
| PAYMENT/ENTERED | 유효한 연결 hold를 가진 클라이언트 결제 화면 관측 |
| COMPLETED/SUCCEEDED | 실제 예매 확정·연결 bookingId |
| SEAT_HOLD/EXPIRED | DB에서 hold 만료 상태 확인 |

클라이언트는 SEAT_SELECTION/ENTERED와 PAYMENT/ENTERED를 보고할 수 있다. 좌석 화면은 QUEUE/SUCCEEDED 또는 기존 SEAT_SELECTION 상태에서, 결제 화면은 hold 연결이 있을 때 허용한다. 현재 단계의 ABANDONED도 가능하지만 연결 hold가 ACTIVE/CONVERTED이면 먼저 실제 업무 상태를 정리해야 한다. 클라이언트가 COMPLETED·업무 성공·FAILED를 임의로 보고할 수 없다.

COMPLETED 또는 FAILED/ABANDONED/EXPIRED는 terminal 상태다. terminal 이후 새 전이는 거부하지만 기존 같은 transition의 재전송은 허용한다. 취소 완료는 별도 CANCEL 이벤트이며 이미 완료된 attempt를 다시 진행 상태로 돌리지 않는다. 탭 종료·무응답·시간 경과만으로 이탈·실패를 추정하지 않는다.

## journal과 업무 연결

booking_attempts는 현재 stage/status/sequence와 nullable hold/booking을 저장한다. booking_attempt_events는 불변 metadata·fingerprint·sequence를 보관하고 outbox_id로 전송 원천을 연결한다. 같은 hold/booking을 여러 attempt에 붙이지 않도록 UNIQUE가 있다.

예약 확정·hold 연결·단계 저장은 로컬 트랜잭션의 일관성을 유지한다. Redis 성공과 MySQL 관측 기록은 분산 트랜잭션이 아니므로 단계 기록 실패가 입장을 되돌리지는 않는다. 다음 조회로 현재 상태를 다시 관측할 수 있으나 사라진 과거 상태의 완전 복원을 보장하지 않는다. DB의 booking/expired hold를 확인한 조회·주기 작업은 실제 상태로 reconcile한다.

## BTS metadata

필수 필드는 `attemptId,transitionId,concertId,stage,status,sequence,source,recordedAt`이다. source는 SERVER 또는 CLIENT_REPORT, sequence는 1 이상 정수다. STARTED/ENTERED는 sequence 1이며 COMPLETED는 SUCCEEDED와 실제 bookingId를 요구한다.

연결에 따라 holdId/bookingId, 확인된 실패 reasonCode, 시작 시 clientOccurredAt, 클라이언트 요청 전이의 ipAddress를 추가한다. 사용자 UUID는 최상위 userId, 서비스는 최상위 serviceId에 넣는다. BOOKING_ATTEMPT에는 가짜 top-level bookingId를 넣지 않는다. API Key·CAPTCHA 답/토큰·원문 카드번호·deviceId를 단계 metadata에 저장하지 않는다.

### ipAddress (#68)

클라이언트 요청으로 생긴 전이에만 `ipAddress`를 싣는다.

| 전이 | ipAddress |
|---|---|
| STARTED/ENTERED (시작 API) | 그 요청의 클라이언트 IP |
| SEAT_SELECTION·PAYMENT/ENTERED, ABANDONED (단계 보고 API) | 그 요청의 클라이언트 IP |
| 서버 관측 전이(CAPTCHA, QUEUE, SEAT_HOLD, COMPLETED)와 주기 작업 전이(만료·reconcile) | 없음 |

- 값은 예매 확정(BOOKING)과 같은 `ClientIpResolver` 기준이다. 연결 peer를 쓰고, TRUSTED_PROXIES에 지정한 프록시를 거친 요청만 X-Forwarded-For에서 신뢰 프록시가 아닌 첫 주소를 쓴다. 요청마다 관측한 값이므로 시작과 단계 보고의 IP가 다를 수 있다.
- 주소를 해석하지 못하면 예매 시도와 단계 기록은 그대로 진행하고 `ipAddress` 키만 뺀다(빈 값을 넣지 않는다). 서버에는 경고 로그 한 줄만 남기며 요청 헤더나 인증 정보는 남기지 않는다. 예매 확정은 지금처럼 해석 실패를 400으로 거부한다.
- 요청 지문에는 넣지 않는다. 같은 attempt/transition을 다른 네트워크에서 다시 보내도 같은 요청으로 보고 기존 결과를 반환하며, 새 이벤트를 만들지 않으므로 처음 기록한 IP가 그대로 남는다. 단계·상태·clientOccurredAt이 실제로 다르면 지금처럼 DATA_CONFLICT다.
- journal metadata가 Outbox로 그대로 옮겨지고 payload가 동결되므로 재전송에서도 IP가 바뀌지 않는다. #68 이전에 기록된 이벤트에는 소급하지 않는다.

BTS는 이 값을 Credit 룰 감점(IP 집중도)에만 쓴다. AI Feature와는 다른 값이다.

| | Credit IP 집중도 감점 | AI Feature ip_booking_density |
|---|---|---|
| 원천 이벤트 | BOOKING_ATTEMPT의 metadata.ipAddress | BOOKING의 metadata.ipAddress |
| 기간 | 평가 시각 직전 10분 | 최근 30일 |
| 값 | 사용자가 쓴 IP마다 같은 서비스·같은 IP의 **고유 attemptId 수**의 최댓값 | 사용자가 예매에 쓴 IP마다 같은 IP로 예매한 **고유 계정 수**의 최댓값 |
| 사용 | 5 이상이면 Credit 5점 감점 | AI 모델 입력 |
| IP 없음 | 판단하지 않음(감점 없음) | 1 |

한 시도의 단계 이벤트가 여러 건이어도 1건으로 세고, 같은 IP를 쓰는 다른 계정의 시도도 함께 센다. 기준과 계산은 BTS(ticket-fds-admin)에 있다. 프록시·NAT 뒤에서 TRUSTED_PROXIES를 설정하지 않으면 모든 사용자가 프록시 주소 하나로 기록되어 함께 감점될 수 있다.

## 브라우저 재전송

브라우저는 사용자·공연별 sessionStorage에 attemptId·클릭 시각·transition ID·미확정 stage 요청을 전송 전에 저장한다. 동일 브라우저 탭의 새로고침과 응답 유실에는 같은 body로 재시도한다. 네트워크 오류·5xx·429는 최대 3회, 100/200ms 간격으로 시도하며 그 밖의 4xx를 자동 반복하지 않는다. 실패한 전이는 저장소에 남겨 다음 조회에서 다시 전송한다. 같은 attempt의 전송은 한 번에 하나씩 이어서 실행하며, 전송 중에 추가된 단계도 그 호출이 끝나기 전에 보낸다(#58: 결제 화면에서 PAYMENT/ENTERED가 미전송으로 남던 문제). 남은 단계가 409로 거부되면 서버 상태를 조회해 attempt가 terminal일 때만 그 단계를 정리하고, 다음 예매는 새 attemptId로 시작한다.

CAPTCHA 검증은 challenge/입력 SHA-256 digest에 transition UUID를 연결한다. 답 원문을 sessionStorage에 저장하지 않는다. 원래 grant TTL을 넘겨 재전송하더라도 유효 기간을 연장하거나 grant를 재발급하지 않는다.

화면은 서버 attempt·본인 hold·booking 조회를 통해 복원한다. SEAT_SELECTION/PAYMENT 기록 응답을 확인한 뒤 다음 동작을 허용한다. 명시적인 종료 후 새 예매는 새 attemptId를 사용한다. 저장소 삭제·탭 종료 후 브라우저에만 있던 미전송 요청 복구는 보장하지 않는다.

## BTS 조회

`GET /api/v1/events/booking-attempts?concertId=...&userId=...&page=0&size=20`은 X-API-Key의 서비스 범위에서 조회한다. userId는 BTS UUID다. page는 0~100000, size는 1~100이다.

data는 `{bookingAttemptCount,items}`이며 items에 attemptId/concertId/userId/startedAt/sequence/stage/status/bookingAttemptCount를 반환한다. count는 STARTED/ENTERED가 있는 고유 attemptId 기준이다. STARTED보다 뒤 단계가 먼저 도착하면 시작 이벤트가 올 때까지 집계·목록에서 제외하고, 현재 단계는 도착 순서가 아니라 가장 큰 sequence로 복원한다. 개별 전체 이력은 BTS 사용자 이벤트 조회의 BOOKING_ATTEMPT 필터를 사용한다.

## 활성화

BOOKING_ATTEMPTS_ENABLED 기본값은 true다(#44: BTS Feature가 시도 기준으로 확정됨). attempt 스키마(04)가 없는 기존 DB는 04를 적용하거나 false로 명시해야 한다. false에서는 capability=false, attempt API=503이며 attempt를 보내지 않는 기존 예매·대기열·CAPTCHA 경로는 유지한다. true는 [DB 명세](erd.md)의 attempt 스키마가 필요하다. 단계 Outbox 생성·전송은 DEMO_JOBS_ENABLED, 원격 전송은 BTS_ENABLED와 서버 인증 설정도 필요하다.
