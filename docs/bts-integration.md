# BTS 연동 명세

## 서비스 경계

브라우저는 Demo 세션으로 예매하고 Demo 서버가 BTS 사용자·이벤트 API를 호출한다. BTS API Key는 서버 런타임에서만 사용하며 브라우저·이벤트 payload·로그에 넣지 않는다. Demo DB는 demo_ticketing_db, BTS DB는 fairticket_db로 분리한다.

| 구분 | 브라우저 → Demo | Demo → BTS |
|---|---|---|
| 사용자 등록 | POST /api/v1/users, {userId} | POST /api/v1/users, {serviceId,externalUserId,accountStatus} |
| 사용자 식별 | 공개 ID와 Bearer 세션 | BTS가 반환한 UUID |
| 인증 | Authorization: Bearer | X-API-Key |
| 이벤트 원천 | 화면 단계 보고와 실제 예약 요청 | 서버 journal·업무 트랜잭션·Outbox |

## 사용자 매핑

demo_users.public_user_id를 bts_external_user_id로 고정하고 bts_service_id로 namespace를 구분한다. 최초 전송 또는 원격 정책 조회 시 BTS 등록 API를 호출해 bts_user_id에 UUID를 저장한다. 로컬 로그인은 BTS 연결 없이 가능하다. 등록된 UUID는 자동으로 다른 값으로 덮어쓰지 않는다.

등록 serviceId는 공백이 아닌 최대 50자 문자열이고 인증 서비스와 같아야 한다. externalUserId는 공백이 아닌 최대 100자 문자열이다. accountStatus는 ACTIVE로 보낸다. BTS의 신규 201/COMMON_201과 기존 매핑 재사용 200/COMMON_200을 모두 허용한다. 응답 UUID와 serviceId/externalUserId를 검증한다.

Demo의 UNIQUE(service,external ID)·UNIQUE(BTS UUID)와 BTS의 서비스별 외부 ID 유일성을 이용한다. BTS 등록 성공 후 로컬 매핑 저장이 실패해도 같은 외부 ID로 재시도하며 새로운 사용자를 임의 생성하지 않는다.

## 이벤트 API

`POST /api/v1/events`에 단일 X-API-Key와 JSON body를 전달한다. 필드명은 camelCase이며 내부 metadata 키를 자동 변환하지 않는다.

| 필드 | 계약 |
|---|---|
| serviceId | 공백 불가, 최대 50자, 인증 서비스 일치 |
| externalEventId | 공백 불가, 최대 100자, 생성 후 고정 |
| userId | 같은 서비스에 속한 BTS UUID, 최대 50자 |
| eventType | BOOKING/CANCEL/CHECK_IN/BOOKING_ATTEMPT |
| bookingId | BOOKING/CANCEL에서 필수, 최대 100자; BOOKING_ATTEMPT는 top-level에서 생략 |
| ticketId | CHECK_IN에서 필수, 최대 100자 |
| occurredAt | offset 포함 ISO 8601, UTC 기준 1000~9999년, 밀리초 단위(밀리초가 0이면 소수 생략); Demo는 Z 사용. BTS가 밀리초를 받는 버전(ticket-fds-admin #40) 이후에 배포 |
| metadata | JSON object; 일반 이벤트는 null 허용, BOOKING_ATTEMPT는 단계 필드 필수 |

BTS는 `(serviceId,externalEventId)`로 중복을 구분한다. 같은 ID·같은 정규화 내용은 기존 eventId와 200, 신규는 201, 같은 ID·다른 내용은 409다. Demo는 성공 envelope와 eventId, 사용자·서비스·외부 ID·이벤트 타입·bookingId를 검증한 뒤 SENT로 기록한다.

## 이벤트 매핑

| 이벤트 | 생성 근거 | metadata |
|---|---|---|
| BOOKING | 유효한 hold로 예매 확정 commit | concertId,performanceStartsAt,performanceEndsAt,ticketIds,bookingDurationSeconds,paymentIdentifier,ipAddress, 연결된 경우 attemptId |
| CANCEL | CONFIRMED→CANCELLED commit | concertId,performanceStartsAt,performanceEndsAt,ticketIds, 연결된 경우 attemptId |
| BOOKING_ATTEMPT | 예매 시작·클라이언트 관측·서버 확인 단계 journal | attemptId,transitionId,concertId,stage,status,sequence,source,recordedAt 및 문맥 필드. 시작·단계 보고 요청에서 생긴 이벤트는 ipAddress 포함(#68) |
| CHECK_IN | 서버 검표 확정(등록 기기의 챌린지 서명 검증 후 ISSUED→CHECKED_IN) commit | concertId,performanceStartsAt,performanceEndsAt,deviceChanged; top-level ticketId와 bookingId |

bookingDurationSeconds는 hold 생성~서버 확정의 0 이상 number다. paymentIdentifier는 허용된 테스트 식별자이며 카드번호/hash를 대신 수집하지 않는다. ipAddress는 서버가 관측한 요청 peer다. TRUSTED_PROXIES에 지정한 프록시를 거친 요청은 X-Forwarded-For에서 신뢰 프록시가 아닌 첫 주소(오른쪽부터)를 쓴다(#64). 그 외에는 Forwarded/X-Forwarded-For를 사용하지 않는다. 공연 시각·ticketIds는 예매 snapshot에서 얻으며 실제 참석 사실을 의미하지 않는다.

일반 이벤트의 metadata.bookingDurationSeconds는 제공되면 0 이상 숫자, metadata.deviceChanged는 제공되면 boolean이어야 한다. Feature 원천 전달과 BTS Feature 계산은 별개다. 브라우저 클릭·QR 표시·선점 만료를 BOOKING/CANCEL/CHECK_IN으로 만들어 보내지 않는다.

CHECK_IN은 검표 API가 티켓을 최초로 CHECKED_IN으로 바꾼 트랜잭션에서만 생성한다. QR 스캔(챌린지 발급)만으로는 생성되지 않으며, 등록 기기가 챌린지에 올바르게 서명해 입장이 확정된 때에만 생성된다. 거부된 스캔·중복 스캔·응답 없는(만료된) 스캔·잘못된 응답·QR 표시는 이벤트가 아니다. payload 형식은 바뀌지 않았다. occurredAt은 서버 검표 시각(밀리초 단위)이다. Outbox의 aggregate_id는 예매 ID라서 같은 예매의 BOOKING이 SENT된 뒤 전송되고, business_transition_id는 `<ticketId>:CHECK_IN`이라 좌석별로 한 건씩 생성된다. 전송 시 원천 metadata의 ticketId를 top-level로 옮기고 응답의 ticketId도 검증한다. `deviceChanged`는 검표에 쓰인 기기가 최초 등록 기기가 아니면 true다. TOTP 비밀키·서명·QR 원문·챌린지는 싣지 않는다.

BOOKING_ATTEMPT의 ipAddress는 BOOKING과 같은 기준(ClientIpResolver)으로 정하되, 시작 API와 단계 보고 API 요청에서 생긴 이벤트에만 싣는다(#68). 서버 관측·주기 작업 이벤트에는 없다. 주소를 해석하지 못하면 BOOKING은 400으로 거부하지만 BOOKING_ATTEMPT는 이벤트를 그대로 기록하고 ipAddress만 뺀다. BTS는 BOOKING_ATTEMPT의 IP를 Credit IP 집중도 감점(최근 10분 같은 IP의 고유 시도 5건 이상)에, BOOKING의 IP를 AI Feature ip_booking_density(30일 같은 IP 고유 예매 계정 수)에 쓴다. 두 값은 서로 대신하지 않는다. 자세한 기록 범위와 멱등성은 [예매 시도 명세](booking-attempts.md)에 있다.

BOOKING_ATTEMPT는 [예매 시도 명세](booking-attempts.md)를 따른다. COMPLETED/SUCCEEDED는 metadata.bookingId로 실제 확정 예매를 연결한다. BOOKING/CANCEL은 top-level bookingId를 유지하고 metadata.attemptId만 추가한다. 기존에 동결된 payload를 소급 수정하지 않는다.

## Outbox와 재시도

업무 상태 변경과 BOOKING/CANCEL Outbox 저장은 같은 로컬 트랜잭션이다. 단계는 journal에 저장한 뒤 별도 주기 작업에서 Outbox로 materialize한다. 원격 네트워크 I/O는 예약 잠금·DB 트랜잭션 밖에서 수행한다. 작업 기본 주기는 5초다.

1. READ COMMITTED 트랜잭션에서 해당 serviceId의 due 이벤트를 SELECT FOR UPDATE SKIP LOCKED로 claim한다.
2. IN_FLIGHT, 임의 lease token, 60초 locked_until을 기록하고 시도 횟수를 증가시킨다.
3. 사용자 UUID를 매핑하고 payload가 NULL일 때만 원천 metadata와 고정 ID·시각을 결합해 최종 body를 동결한다.
4. BTS에 같은 payload를 전송하고 lease token이 일치하는 행만 SENT/RETRY/FAILED로 갱신한다.

| 결과 | 처리 |
|---|---|
| 검증된 200/201 | SENT, bts_event_id·sent_at 저장 |
| 연결 실패·timeout·5xx | RETRY, 지수 backoff: 2초부터 최대 300초, 총 8회 시도 후 FAILED |
| 400/401/403/404/409 등 비재시도 오류 | 즉시 FAILED |
| 중단된 IN_FLIGHT | lease 만료 후 재claim |

HTTP 연결 timeout은 2초, 요청 timeout은 3초이며 redirect를 따라가지 않는다. 응답 형식 오류는 응답 상태와 검증 지점에 따라 재시도 또는 실패 처리한다. 오류 원문 대신 제한된 안전 코드만 저장한다.

같은 예매의 앞선 이벤트가 SENT가 되어야 CANCEL을 보낸다. FAILED BOOKING을 새 ID로 우회하지 않는다. BOOKING_ATTEMPT와 POLICY_APPLICATION은 업무 그룹 선행 실패에 막히지 않고 독립 전송한다. 도착 순서는 보장하지 않으며 조회에서 sequence로 현재 단계를 복원한다. 재시도로 externalEventId·occurredAt·metadata·동결 payload를 바꾸지 않는다.

운영 재처리는 원인과 기존 BTS 레코드를 확인한 뒤 같은 ID/payload를 유지해야 한다. 공개 재처리 API는 없다. API Key 교체·UUID 초기화·BTS DB 직접 수정으로 오류를 우회하지 않는다.

## 원격 정책 API

POLICY_DECISION_MODE=bts는 BTS UUID를 확보하고 `POST /api/v1/users/{uuid}/policy-decisions`에 `{ "context": "QUEUE_JOIN", "concertId": "<공연 public_id>" }`를 전송한다(#67). X-API-Key는 서버 설정을 사용하며 `data.action`은 ALLOW/REQUIRE_CAPTCHA/DELAY/RESTRICT 중 하나여야 한다. `data.decisionId`는 적용 기록에 쓰려고 함께 읽는다. 응답에 없으면(이전 BTS) 정책은 그대로 적용하고 적용 기록만 만들지 않는다. latestAction 조회를 신규 결정 대신 사용하지 않는다.

정책 호출 코드와 원격 endpoint 배포는 별개의 조건이다. 배포 대상 BTS가 endpoint를 제공해야 bts 모드를 사용할 수 있다. 원격 장애·알 수 없는 응답은 입장 허용으로 바꾸지 않고 503으로 처리한다. disabled는 ALLOW, mock은 인증된 Demo 공개 ID에 대한 서버 설정을 사용한다. 활성 WAITING/ADMITTED는 정책을 재적용하지 않는다.

좌석 선점(`POST /api/v1/concerts/{concertId}/seat-holds`) 직전에도 같은 API를 `{ "context": "BOOKING_ATTEMPT", "concertId": ... }`로 호출한다(#46, #67). CAPTCHA·후순위는 대기열에서 이미 적용했으므로 예매 단계에서는 RESTRICT만 403/BOOKING_RESTRICTED로 거부한다. 사용자는 대기열 정책을 이미 통과했으므로 예매 단계의 원격 장애·알 수 없는 응답은 선점을 허용하고 로그만 남긴다. 호출은 좌석 잠금·DB 트랜잭션 밖에서 한다. disabled/mock 모드는 대기열과 같은 결정을 쓴다.

## 정책 적용 기록 (#67)

BTS는 정책을 결정만 하고, 그 정책이 실제로 적용됐는지는 Demo만 안다. Demo는 정책이 **실제로 적용된 순간**에만 `POST /api/v1/policy-applications`로 기록을 보낸다(ticket-fds-admin `docs/policy-application-integration.md`). 정책 응답을 받은 것만으로는 보내지 않는다. 이 기록은 행동 이벤트가 아니다. `/api/v1/events`로 보내지 않으므로 BTS behavior_event·AI 평가 대상·Credit 산출에 들어가지 않는다.

| action | result | 기록 시점 | 쓰는 decisionId |
|---|---|---|---|
| REQUIRE_CAPTCHA | CHALLENGED | captcha-challenges가 challenge를 발급한 때 | 그 발급 요청의 결정 |
| REQUIRE_CAPTCHA | PASSED / FAILED | captcha-verifications가 성공 / CAPTCHA_INVALID로 끝난 때 | challenge를 발급한 결정(challenge HASH의 decision) |
| DELAY | DELAYED | 대기열 입장이 후순위 그룹(waiting-delayed)에 새로 배치한 때. 빈자리가 있어 곧바로 입장해도 배치는 기록한다 | 그 입장 요청의 결정 |
| RESTRICT | BLOCKED | 대기열 입장이 QUEUE_RESTRICTED로, 또는 좌석 선점이 BOOKING_RESTRICTED로 거부된 때 | 그 요청의 결정 |

기록하지 않는 경우는 다음과 같다.

- ALLOW, 그리고 정책 결정만 받고 사용자가 이탈한 경우(입장이 CAPTCHA_REQUIRED로 거부됐을 뿐 challenge를 받지 않은 경우 포함).
- 이미 WAITING/ADMITTED인 사용자의 재요청, 동시 요청으로 Lua가 정책을 다시 적용하지 않은 경우(created=false).
- BTS 장애로 좌석 선점을 그대로 허용한 경우.
- DELAY 결정의 CAPTCHA 요구·통과·실패. BTS는 적용 기록의 action이 결정의 action과 같아야 하고 DELAY에는 DELAYED만 받으므로, 현재 계약으로는 기록할 수 없다. DELAY 사용자가 CAPTCHA에서 이탈하면 기록이 없다.
- 답을 실제로 판정받지 않은 검증 요청: 다른 사용자의 challenge, 만료된 challenge, 이미 소비된 challenge(정답의 동시 중복 제출 포함), 같은 X-Attempt-Transition 재전송. 응답은 CAPTCHA_INVALID 또는 원래 결과지만 오답이 아니므로 FAILED가 아니다. 판정 여부와 귀속할 decisionId는 검증과 같은 Lua 실행에서 정한다.
- captcha API가 QUEUE_RESTRICTED로 거부한 경우.
- mock/disabled 모드(decisionId가 없다).

CAPTCHA 발급·검증·재입장은 각각 정책을 다시 요청해 서로 다른 decisionId를 받는다. CHALLENGED와 PASSED/FAILED는 모두 challenge를 발급한 결정에 붙이므로 BTS 통계에서 적용 1회로 집계된다. challenge는 공연 namespace 안에 있고 사용자에게 묶여 있어 같은 사용자의 여러 공연·여러 시도가 섞이지 않는다.

적재와 전송은 기존 Outbox를 쓴다.

- 적용이 확정된 뒤 `outbox_events`에 `POLICY_APPLICATION` 행을 별도 트랜잭션으로 넣는다. externalApplicationId는 `pa-{decisionId}-{result}`로 적재할 때 한 번 정한다.
- 같은 결정의 같은 결과는 한 행만 남는다. 재전송·중복 요청·같은 challenge의 반복 실패는 합쳐지고, 실제 반복 적용은 새 결정이라 새 행이 된다. BTS 관리자 통계의 CAPTCHA 결과도 "고유 결정 수"라서 의미가 같다: `captcha.failed`는 오답 제출 횟수가 아니라 한 번 이상 실패한 challenge(결정) 수이고, 실패 후 통과한 결정은 passed와 failed에 모두 잡힌다.
- 전송 본문은 `{serviceId, externalApplicationId, userId, decisionId, concertId, action, result, appliedAt}`이고 appliedAt은 밀리초까지의 UTC ISO 8601 Z다. payload 동결·lease·재시도는 이벤트와 같다. 응답의 식별 필드와 applicationId를 검증한 뒤 SENT로 기록하고 bts_event_id에 applicationId를 저장한다.
- BOOKING_ATTEMPT처럼 업무 그룹 순서에 묶이지 않고 독립 전송한다.
- BTS가 같은 키의 재전송에 200을 주면 성공이다. 404·409 등은 즉시 FAILED로 두고 다시 보내지 않는다.

Redis의 정책 적용과 MySQL 적재는 한 트랜잭션이 아니다. 적재는 적용 결과를 확인한 뒤에만 하므로 적용 없이 기록만 남는 일은 없다. 반대로 적용 뒤 적재가 실패하거나 프로세스가 중단되면 그 기록은 빠지고(경고 로그), 통계가 그만큼 적게 집계된다. 적재·전송 실패는 대기열·CAPTCHA·예매 응답을 바꾸지 않는다.

## 공연 동기화

BTS_ENABLED=true이고 DEMO_JOBS_ENABLED=true이면 기동 직후와 BTS_CONCERT_SYNC_MS(기본 10분)마다 전체 공연을 `PUT /api/v1/concerts/{concertId}`로 보낸다(#46, ticket-fds-admin `docs/concert-integration.md`). concertId는 이벤트 metadata.concertId와 같은 공연 public_id이며, body는 name(title)·venue·startsAt·endsAt(초 단위 UTC ISO 8601)이다. BTS PUT은 멱등이라 재전송해도 중복이 생기지 않는다. 실패는 공연 단위로 격리하고 다음 주기에 재시도하며 이벤트 전송·예매를 막지 않는다. 공연 생성 API가 없으므로 seed·DB 변경은 다음 주기에 반영된다.

## 설정

| 설정 | 기본값 / 의미 |
|---|---|
| BOOKING_ATTEMPTS_ENABLED | true(기본값); attempt 스키마(04)가 없는 기존 DB는 04 적용 전까지 false |
| DEMO_JOBS_ENABLED | true; 만료 정리·단계 materialize·Outbox 전송 |
| BTS_ENABLED | false; false이면 이벤트 원천을 보존하고 네트워크 호출하지 않음 |
| BTS_BASE_URL | 활성 시 필수; HTTPS, 루프백 테스트만 HTTP 허용 |
| BTS_SERVICE_ID | demo-ticketing; 사용자/이벤트 namespace |
| BTS_API_KEY | 활성 시 필수; 런타임 비밀정보 |
| CHECKIN_ENABLED | false; 05·07 스키마 적용 후 true. 동적 QR·검표 API와 CHECK_IN 생성 |
| TICKET_SECRET_KEY | 활성 시 필수; 32바이트의 Base64. TOTP 비밀키 암호화 키, 런타임 비밀정보 |
| GATE_API_KEY | 활성 시 필수; 16자 이상. 검표 담당자 인증, 런타임 비밀정보 |
| CHECKIN_OPENS_BEFORE | PT2H; 공연 시작 전 입장 허용 시간 |
| DEVICE_CHALLENGE_TTL / DEVICE_MAX_CHANGES | PT2M / 3 |
| CHECKIN_CHALLENGE_TTL | PT15S; 검표 스캔 후 등록 기기가 챌린지에 응답해야 하는 시간 |
| POLICY_DECISION_MODE | disabled/mock/bts; bts는 대기열(QUEUE_JOIN)과 좌석 선점(BOOKING_ATTEMPT) 두 시점에 호출. 정책 적용 기록은 bts 모드에서만 생성하며 09 스키마 적용이 필요 |
| BTS_CONCERT_SYNC_MS | 600000; 공연 BTS 동기화 주기(ms) |
| CAPTCHA_MODE | disabled/mock/hcaptcha; hcaptcha는 HCAPTCHA_SITE_KEY·HCAPTCHA_SECRET 필수 |
| HCAPTCHA_SITE_KEY | hcaptcha 모드에서 필수; 브라우저 위젯에 전달되는 공개 키 |
| HCAPTCHA_SECRET | hcaptcha 모드에서 필수; 서버 검증용 비밀 키, 런타임 비밀정보 |
| HCAPTCHA_VERIFY_URL | 선택; 기본값 https://api.hcaptcha.com/siteverify |

새 serviceId는 사용자·이벤트 생성 전에 결정한다. 이미 매핑된 기존 사용자의 namespace를 임의 변경하지 않는다. 스키마·마이그레이션은 [DB 명세](erd.md), 브라우저 계약은 [Demo API 명세](api-spec.md)를 따른다.
