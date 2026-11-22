# QR 검표·관람 이벤트 연동 검증 결과 (2026-11-22, #53)

기존에 구현한 QR 검표가 정상 동작하는지, 그리고 검표 결과가 Demo DB와 BTS DB에 올바르게 반영되는지 실제 서버 두 대와 DB 두 개로 검증했습니다. 새 기능은 추가하지 않았습니다.

**요약**
- 예매 → 기기 등록 → QR → 스캔 → Challenge-Response → `CHECKED_IN` → Outbox → BTS `behavior_event` → 관리자 API 조회까지 **검증 41개가 모두 통과**했습니다.
- 제품 코드에서 발견된 오류는 없어 Demo 코드는 수정하지 않았습니다.
- **BTS의 "관람 이력"(`booking_history`)에는 CHECK_IN이 반영되지 않습니다.** 미구현이며 후속 이슈로 분리합니다.
- BTS 관리자 프론트엔드가 호출하는 요약 API 경로가 백엔드와 달라 404가 납니다(발견 사항 1).

## 대상

| 구성 | 버전 |
|---|---|
| Demo | `test/#53/checkin-history-integration` (기준 5acf7d0, #52 Challenge-Response 검표 포함) |
| BTS (ticket-fds-admin) | `feat/#40/risk-assessment-credit-pipeline` @ 46f8c67 |
| DB | MySQL 8.0 ×2, Redis 7.4 (`e2e/compose.yaml`, tmpfs) |
| JVM | OpenJDK 17, 시간대 Korea Standard Time (개발 PC 기본값) |

## 실행 방법

```powershell
cd e2e
.\Start-E2E.ps1                    # DB 컨테이너 + BTS(18080) + Demo(18081)
.\Run-Scenarios.ps1 -Only checkin  # 이번 이슈의 시나리오. 인자 없이 실행하면 전체
.\Stop-E2E.ps1                     # 백엔드 종료 + 컨테이너 삭제
```

- **격리:** `cdbts-e2e` 컨테이너(BTS MySQL 3317, Demo MySQL 3318, Redis 6390)만 사용합니다. 데이터는 tmpfs에 있어 종료하면 사라집니다. 개발용 DB(`demo-ticketing-mysql`, `fairticket-mysql`)는 건드리지 않았습니다.
- **검표 설정:** e2e Demo DB에 05·07 스크립트를 추가로 적용하고 `CHECKIN_ENABLED=true`로 띄웁니다. 검표 담당자 키와 TOTP 암호화 키는 실행마다 새로 만듭니다.
- **기본값과 다른 설정:** `CHECKIN_OPENS_BEFORE=P365D`(seed 공연이 미래 날짜), `CHECKIN_CHALLENGE_TTL=PT6S`(만료를 빨리 확인. 기본 15초).
- **인증·서명:** 우회하지 않았습니다. 스크립트가 브라우저 기기 역할을 하며 ECDSA P-256 키를 만들어 실제 API로 등록하고, QR과 챌린지 응답에 직접 서명합니다(`e2e/E2E-Common.ps1`).
- **전송 주체:** Outbox 전송은 Demo의 스케줄러(`BookingJobs`, 5초 주기)가 수행했습니다. 스크립트는 전송 함수를 호출하지 않고 SENT가 될 때까지 기다리기만 합니다.

자동 테스트(Demo 단독):

```powershell
cd backend
.\gradlew.bat test                             # 단위 테스트
.\scripts\Invoke-Backend.ps1 -Task MySqlTest   # TicketCheckInMySqlTests 포함. 05·07이 적용된 DB 필요
```

## 검증한 데이터 흐름

| # | 단계 | 구현 위치 | 구현 | 이번 검증 |
|---|---|---|---|---|
| 1 | 예매 | Demo `ReservationService` → `bookings`, `admission_tickets` | O | 통과 |
| 2 | 기기 등록·QR 생성 | Demo `TicketDeviceService` → `ticket_device_bindings` | O | 통과 |
| 3 | QR 스캔 | Demo `POST /check-ins` → `ticket_checkin_challenges` | O | 통과 |
| 4 | Challenge-Response | Demo `GET …/check-in-challenge`, `POST …/check-in-proofs` | O | 통과 |
| 5 | 티켓 상태·입장 시각 | Demo `admission_tickets.status`, `checked_in_at` | O | 통과 |
| 6 | Outbox `CHECK_IN` 생성 | Demo `outbox_events` (5와 같은 트랜잭션) | O | 통과 |
| 7 | BTS로 전송 | Demo `BookingJobs` → `OutboxDeliveryService` → `POST /api/v1/events` | O | 통과 (실제 BTS) |
| 8 | BTS DB 저장 | BTS `behavior_event` | O | 통과 |
| 8' | 관람 이력 저장 | BTS `booking_history` | **X** | 미구현 확인 (0행) |
| 9 | 사용자별 이벤트 조회 | BTS `GET /users/{id}/events`, `GET /admin/users/{id}/events` | O | 통과 |
| 9' | 관람 이력 전용 조회 | 없음 | **X** | 미구현 |
| 10 | 관리자 대시보드 | BTS 프론트 "예매 및 행동 이력", 요약 `eventsByType` | 일부 | API·타입 통과, 화면은 수동 확인 필요 |

6과 7·8은 별개로 확인했습니다. Outbox 행 생성(6)은 Demo DB에서, 실제 전달(7)은 Outbox의 `SENT`·`bts_event_id`로, 저장(8)은 BTS DB의 `behavior_event` 행으로 각각 조회했습니다.

## 결과: e2e `checkin` 41 / 41 통과

마지막 실행(전체 시나리오, 새 환경) 기준입니다. 전체 시나리오는 기존 29개를 포함해 70 / 70 통과했습니다.

### QR 검표

| 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|
| 예매 좌석마다 티켓 발급 | 2석 → 티켓 2장, ISSUED, 기기 미등록 | PASS |
| 기기 등록 | 챌린지 서명 후 TOTP 비밀키(20바이트) 수령, 변경 가능 3회 | PASS |
| QR 생성 | `BTS1.<ticket>.<device>.<epoch>.<totp>.<signature>` 형식 | PASS |
| 검표 담당자 키 없이 스캔 | 401 `UNAUTHORIZED` | PASS |
| 잘못된 형식의 QR | 400 `QR_INVALID` | PASS |
| TOTP가 틀린 QR | 403 `QR_REJECTED` | PASS |
| 만료된 TOTP (5분 전 QR) | 403 `QR_EXPIRED` | PASS |
| 등록되지 않은 기기 키로 서명한 QR | 403 `QR_REJECTED` | PASS |
| 스캔 단계 실패 후 티켓 상태 | ISSUED, `checked_in_at` NULL, CHECK_IN 없음 | PASS |
| 유효한 QR 스캔 | 챌린지만 발급(PENDING), 입장 미확정 | PASS |
| 다른 사용자의 챌린지 조회 | 403 `FORBIDDEN` | PASS |
| 등록 기기의 챌린지 수신 | 스캔한 checkInId·deviceId와 일치 | PASS |
| 등록되지 않은 기기의 챌린지 서명 | 403 `CHECKIN_PROOF_INVALID`, 챌린지 REJECTED | PASS |
| 소비된 챌린지 재사용 (올바른 서명) | 403 `CHECKIN_PROOF_INVALID` | PASS |
| 만료된 챌린지 (올바른 서명) | 403 `CHECKIN_PROOF_INVALID`, 검표기에는 EXPIRED | PASS |
| 응답 단계 실패 후 티켓 상태 | ISSUED, `checked_in_at` NULL, CHECK_IN 없음 | PASS |
| 등록 기기 서명으로 확정 | 200, 검표기 조회 COMPLETED | PASS |
| 입장한 티켓 재스캔·응답 재전송 | 409 `TICKET_ALREADY_CHECKED_IN` | PASS |
| 중복 시도 후 | 최초 입장 시각 유지, CHECK_IN Outbox 1건 | PASS |

### Demo DB

| 검증 | 실제 결과 |
|---|---|
| 티켓 `CHECKED_IN`, `checked_in_at` = API `checkedInAt` (마이크로초까지) | PASS |
| 티켓 조회 API에 `CHECKED_IN`·`checkedInAt` 반영 | PASS |
| 같은 예매의 다른 좌석 티켓은 ISSUED 유지 | PASS |
| Outbox `CHECK_IN` 생성: 전이 ID `<ticketId>:CHECK_IN`, aggregate = 예매 ID, 시각 = `checked_in_at`(밀리초) | PASS |
| 스케줄러 전송 후 `SENT`, `bts_event_id` 기록 (사용자 Outbox 8건 전부 SENT) | PASS |

### BTS DB (`behavior_event`)

| 검증 | 실제 결과 |
|---|---|
| CHECK_IN 1건 저장 | PASS |
| `event_id` = Outbox `bts_event_id`, `external_event_id`·`service_id` 일치 | PASS |
| `user_id` = Demo 사용자의 BTS UUID (`user_account.external_user_id`로 역확인) | PASS |
| `ticket_id` = Demo 티켓 ID, `booking_id` = Demo 예매 ID | PASS |
| `metadata.concertId` = 공연 ID, 공연 시작·종료 시각 = BTS `concert` 행 | PASS |
| `occurred_at` = Demo `checked_in_at` (밀리초까지) | PASS |
| metadata는 `concertId`·공연 시각 2개·`deviceChanged=false`뿐 (비밀값 없음) | PASS |
| 같은 예매의 BOOKING 이벤트가 있고 CHECK_IN보다 앞선다 | PASS |

### 중복 전송 방지

| 검증 | 실제 결과 |
|---|---|
| Outbox에 동결된 payload를 그대로 재전송 → 200, 같은 `eventId`, 저장 1건 그대로 | PASS |
| 같은 이벤트 ID에 다른 티켓 ID → 409 `DATA_CONFLICT`, 저장 1건 그대로 | PASS |

### 조회 API

| 검증 | 실제 결과 |
|---|---|
| 관리자 `GET /admin/users/{id}/events?eventType=CHECK_IN` (프론트와 같은 파라미터)에서 조회 | PASS |
| 응답 필드 = 프론트엔드 `UserEvent` 타입의 9개 필드 | PASS |
| `occurredAt` = Demo `checked_in_at` (UTC, 밀리초) | PASS |
| 전체 이력(최신순)의 첫 항목이 CHECK_IN | PASS |
| 서비스 `GET /users/{id}/events?eventType=CHECK_IN`에서 조회 | PASS |
| `GET /dashboard/summary`의 `eventsByType.CHECK_IN` 집계 | PASS |
| 공연별 참여 사용자(`/admin/concerts/{id}/users`)에 표시 | PASS |

### 자동 테스트

| 테스트 | 결과 |
|---|---|
| Demo 단위 테스트 (`gradlew test`) | 통과 |
| `TicketCheckInMySqlTests` 8개 (e2e Demo DB에서 실행) | 8 / 8 통과 |

이번에 `TicketCheckInMySqlTests`에 추가한 검증:
- 스캔·거부된 응답까지는 `checked_in_at`이 NULL이다.
- 확정 후 `checked_in_at` = 서버 확정 시각 = 응답 `checkedInAt`, Outbox `occurred_at_utc`는 그 밀리초 값이다.
- 같은 예매의 다른 좌석은 `checked_in_at`이 NULL로 남는다.
- 중복 검표 시도는 최초 입장 시각과 이벤트 건수를 바꾸지 않는다.

## 통과 / 실패 / 미검증

- **통과:** 위 41개 검증과 자동 테스트 전부.
- **실패:** 없음.
- **미구현 확인 (판정 제외):** BTS `booking_history` 적재, 관람 이력 전용 조회, 출석률 Feature.
- **미검증 (수동 확인 필요):**
  - BTS 관리자 화면에서 사용자 상세의 "예매 및 행동 이력"에 "체크인" 배지와 시각이 실제로 표시되는지.
  - Demo 프론트엔드의 실제 카메라 스캔과 QR 화면의 자동 응답(#52에서 개발 서버로 수동 확인했고 이번 자동 검증에는 포함하지 않음).
  - 기기 변경 후 검표 시 `deviceChanged=true`가 BTS까지 전달되는지(Demo 통합 테스트는 Outbox까지만 확인).
  - BTS 장애 중 발생한 CHECK_IN의 재전송(기존 `outage` 시나리오는 BOOKING·BOOKING_ATTEMPT만 다룸. 전송 경로는 같음).

## 발견 사항

### 1. BTS 관리자 프론트엔드의 요약 API 경로 불일치 (BTS 저장소, 미수정)
- **증상:** 프론트엔드는 `GET /api/v1/admin/summary`를 호출하지만(`frontend/src/api/client.ts`) 백엔드에는 `GET /api/v1/dashboard/summary`만 있습니다. e2e에서 앞의 경로는 404, 뒤의 경로는 200이었습니다.
- **영향:** 이 브랜치 기준으로 관리자 대시보드의 요약(이벤트 유형별 건수 포함)이 화면에서 로드되지 않을 것으로 보입니다. 사용자 상세의 이벤트 이력은 다른 경로라 영향이 없습니다.
- **조치:** BTS 저장소 변경이라 수정하지 않았습니다. ticket-fds-admin에 이슈 등록이 필요합니다. 다른 브랜치에서 이미 고쳐졌는지는 확인하지 못했습니다.

### 2. BTS는 CHECK_IN을 `behavior_event`에만 저장한다 (BTS 저장소, 미구현)
- **증상:** 검표 후에도 해당 사용자의 `booking_history`는 0행입니다. 이 테이블에 쓰는 코드가 없습니다.
- **영향:**
  - `CreditEvaluationService`는 `booking_history`의 관람·노쇼 건수를 읽으므로 검표 결과가 신용 점수에 반영되지 않습니다.
  - `FeatureAggregationService`는 CHECK_IN을 집계하지 않아 관리자 화면의 "출석률" 값이 채워지지 않습니다.
  - "어떤 공연을 관람했는가"는 이벤트 목록에서 CHECK_IN을 필터링해야만 알 수 있습니다.
- **조치:** 이번 이슈 범위 밖으로 합의했습니다. 후속 이슈로 분리합니다.

### 3. e2e 스크립트 작성 중 수정한 검증 코드 오류 (제품 오류 아님)
- 첫 실행에서 5개가 실패했는데 모두 시나리오 스크립트의 문제였습니다. Windows PowerShell 5.1에서 단일 행 결과의 `.Count`가 비어 있고, 빈 문자열 컬럼이 `$null`로 읽혔습니다.
- 결과를 `@()`로 감싸고 NULL을 `'NULL'` 문자열로 받도록 고친 뒤 41개가 모두 통과했습니다.

## 수정 내역

| 파일 | 내용 |
|---|---|
| `backend/src/test/.../TicketCheckInMySqlTests.java` | `checked_in_at` 검증 추가 |
| `e2e/compose.yaml` | e2e Demo DB에 05·07 스크립트 적용, healthcheck 대상 변경 |
| `e2e/Start-E2E.ps1` | 검표 활성화, 검표 담당자 키·TOTP 암호화 키 생성 |
| `e2e/E2E-Common.ps1` | 기기 역할 함수(키 생성, TOTP, QR, 챌린지 서명, 검표기 요청) |
| `e2e/Run-Scenarios.ps1` | `checkin` 시나리오 |
| `e2e/README.md` | 시나리오·환경 설명 |

Demo 제품 코드와 BTS 저장소는 수정하지 않았습니다.

## 남은 한계와 후속 작업

- **후속 이슈 (BTS):**
  - CHECK_IN을 `booking_history`에 반영(COMPLETED)하고, 공연 종료 후 미입장을 NO_SHOW로 처리.
  - 관람 이력을 신용 평가에 반영.
  - `attendanceRate` Feature 집계.
  - 관람 이력 전용 조회 API와 관리자 화면.
  - 관리자 프론트엔드 요약 API 경로 수정(발견 사항 1).
- **검표 자체의 한계 (#52에서 합의):** 챌린지 응답은 자동이라, 등록 기기가 QR 화면을 켜 둔 채 다른 사람이 캡처본을 제시하면 입장이 확정됩니다. 입장 시 등록 기기가 온라인이어야 합니다.
- **시각 저장 (기존 발견 사항, ticket-fds-admin#47):** BTS는 JVM 시간대와 `serverTimezone`이 다르면 시각이 밀려 저장됩니다. 이번 검증은 README 기본값(KST JVM + `serverTimezone=Asia/Seoul`)에서만 했습니다.
- **프론트엔드 화면:** 두 프론트엔드 모두 API 수준까지만 자동 검증했습니다.
