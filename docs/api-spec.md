# Demo Ticketing API 명세

## 인증과 응답

브라우저는 Demo 백엔드의 `/api/v1`을 호출한다. BTS API Key는 서버 간 인증에만 사용한다. Demo 사용자 공개 ID와 BTS 사용자 UUID는 서로 다른 식별자다.

`POST /api/v1/users`는 `{ "userId": "demo-user" }`를 받아 `{userId,token,expiresAt}`을 반환한다. userId는 영문·숫자·밑줄·하이픈 3~30자다. 새로운 ID는 등록하고 기존 ID에는 새 세션을 발급한다. 세션은 24시간 유효하며 보호된 API에는 `Authorization: Bearer <token>`을 전달한다. DB에는 원문 토큰 대신 SHA-256 hash를 저장한다. ID 입력은 시연용 식별 방식이며 실제 사용자 소유권 인증을 대신하지 않는다.

응답 envelope는 `{success,code,data,message}`다. 성공은 HTTP 200/COMMON_200 또는 201/COMMON_201이며 실패의 data는 null이다. 입력 오류 400, 미인증 401, 권한 오류 403, 없는 리소스 404, 상태 충돌 409, 만료 hold 410, 의존 서비스 장애 503을 사용한다.

## 공연과 좌석 조회

| API | 인증 | data |
|---|---|---|
| GET /api/v1/concerts | 불필요 | Concert[] |
| GET /api/v1/concerts/{concertId} | 불필요 | Concert |
| GET /api/v1/concerts/{concertId}/seats | 선택 | Seat[] |

- Concert: `id,title,artist,venue,startAt,priceFrom,tagline,hue`.
- Seat: `id,row,number,grade,price,status,heldByMe`. id는 공연 내 seat_code다. 상태는 AVAILABLE/HELD/BOOKED다.
- `heldByMe`는 유효한 인증 주체와 hold 소유자를 서버에서 비교한다. 만료된 HELD는 정리 작업 지연 중에도 AVAILABLE로 조회된다.
- 공연 ID가 없으면 CONCERT_NOT_FOUND이며 좌석을 임의 생성하지 않는다.

## 대기열과 CAPTCHA

대기열·CAPTCHA API는 Bearer 세션을 요구한다. 선택적 `X-Booking-Attempt`는 본인·공연에 연결된 attempt UUID다.

| API | 요청 | 응답 |
|---|---|---|
| POST /api/v1/concerts/{concertId}/queue | body 없음, 선택 X-Captcha-Token | 생성 201, 기존 등록 200; QueueSnapshot |
| GET /api/v1/concerts/{concertId}/queue/me | body 없음 | 200; QueueSnapshot |
| DELETE /api/v1/concerts/{concertId}/queue/me | body 없음 | 200; data=null |
| POST /api/v1/concerts/{concertId}/queue/captcha-challenges | body 없음 | 200; challengeId,question,expiresAt,provider,siteKey |
| POST /api/v1/concerts/{concertId}/queue/captcha-verifications | challengeId,answer; 선택 X-Attempt-Transition | 200; captchaToken,expiresAt |

captcha-challenges 응답의 provider는 mock 또는 hcaptcha이며, siteKey는 hcaptcha일 때만 값이 있다(mock은 null). hcaptcha 모드에서는 브라우저 위젯이 발급한 토큰을 captcha-verifications의 answer로 전달하고(최대 8192자), 서버가 hCaptcha 검증 API로 확인한다. 검증에 쓰인 captchaToken은 한 번만 사용할 수 있다.
QueueSnapshot은 `{status,position,expiresAt}`다. status는 NOT_JOINED/WAITING/ADMITTED/EXPIRED이며 WAITING 순번은 1부터, ADMITTED는 0이다. 날짜는 ISO 8601이다. 실제 API는 ticketId나 뒤 인원 수를 반환하지 않는다. 프론트엔드 adapter는 concertId를 ticketId로 사용하고 behind=0으로 채운다.

정책은 서버가 인증된 사용자 기준으로 결정한다. ALLOW와 REQUIRE_CAPTCHA는 일반 그룹, DELAY는 후순위 그룹이며 REQUIRE_CAPTCHA/DELAY는 CAPTCHA 증명이 필요하다. RESTRICT는 403/QUEUE_RESTRICTED다. 일반 그룹이 우선이고 그룹 안에서는 FIFO다. 빈 자리가 있으면 즉시 입장하며 엄격한 우선순위로 후순위가 대기 만료될 수 있다.

Redis TIME을 기준으로 만료·승격·정원을 처리한다. 동일 사용자·공연의 활성 등록은 정책 재평가나 새 순번 발급 없이 재사용한다. 이탈·만료 후 재등록에는 정책을 다시 적용한다. 브라우저 캐시를 입장 권한으로 사용하지 않는다.

CAPTCHA challenge는 기본 2분, 답 제출 최대 5회이며 grant도 기본 2분이다. 잘못된 답은 403/CAPTCHA_INVALID다. 인증 증명이 없으면 CAPTCHA_REQUIRED, 만료·소비·다른 사용자/공연/action의 grant는 CAPTCHA_INVALID다. grant 검증·일회용 소비·대기열 삽입은 Lua에서 원자적으로 수행한다. 인증 전에는 대기열 등록 멤버·순번·입장 권한을 만들지 않는다.

같은 X-Attempt-Transition의 동일 challenge/입력 재전송은 grant TTL 동안 원래 성공·실패 결과를 반환하며 실패 횟수를 다시 차감하지 않는다. 같은 ID의 다른 입력은 409/DATA_CONFLICT다. CAPTCHA 답 원문은 재전송 식별용 브라우저 저장소나 이벤트 metadata에 보관하지 않는다. 원래 grant가 만료되거나 소비된 뒤 재전송해도 grant 유효 기간을 연장하지 않는다.

POLICY_DECISION_MODE는 disabled(ALLOW), mock(서버 설정), bts(원격 정책 호출)다. bts 모드는 BTS UUID를 매핑한 뒤 `POST /api/v1/users/{uuid}/policy-decisions`에 `{context:"QUEUE_JOIN"}`을 전송하고 data.action을 읽는다. 원격 endpoint의 제공은 BTS 배포에 달려 있다. 장애·알 수 없는 action을 ALLOW로 우회하지 않는다. CAPTCHA_MODE는 disabled/mock/hcaptcha를 지원한다. mock 산술 문제는 실제 봇 방지 공급자가 아니며 로컬 시연용이다. hcaptcha는 외부 공급자(hCaptcha)의 위젯과 서버 검증을 사용하고, 검증 API 장애 시 통과시키지 않고 503으로 응답한다.

## 좌석 선점과 예매

아래 API는 모두 Bearer 세션을 요구한다. 요청의 userId나 브라우저 입장 캐시는 권한 근거가 아니다.

| API | 요청 | 성공 |
|---|---|---|
| POST /api/v1/concerts/{concertId}/seat-holds | seatIds, 선택 attemptId/transitionId | 201; HoldResponse. BTS 정책이 RESTRICT면 403/BOOKING_RESTRICTED |
| GET /api/v1/seat-holds/{holdId} | 없음 | 200; HoldResponse |
| DELETE /api/v1/seat-holds/{holdId} | 없음 | 200; data=null |
| POST /api/v1/bookings | holdId,paymentIdentifier | 신규 201, 재확정 200; BookingResponse |
| POST /api/v1/bookings/{bookingId}/cancel | 없음 | 200; BookingResponse |
| GET /api/v1/bookings/me | 없음 | 200; BookingResponse[] |

HoldResponse는 `{holdId,concertId,seatIds,expiresAt}`다. BookingResponse는 `{id,concertId,concertTitle,venue,startAt,seatIds,totalPrice,status,createdAt}`다. 가격·공연 정보는 예매 당시 snapshot을 사용한다.

좌석은 중복 없이 1~4개 선택한다. 선점 생성·교체·재요청에는 해당 공연의 현재 Redis ADMITTED가 필요하다. 미입장은 QUEUE_NOT_ADMITTED, Redis 장애는 SERVICE_UNAVAILABLE이며 우회하지 않는다. 선점 만료 기본값은 5분이다. 유효한 본인 hold로 예매를 확정하며 선점 후 입장 TTL 만료·대기열 이탈·Redis 장애가 hold를 무효화하지 않는다.

사용자·공연별 guard와 정렬된 좌석 행 잠금으로 경쟁 요청을 직렬화한다. hold_id UNIQUE로 같은 선점에서 중복 예매를 방지한다. 예매·좌석·티켓·BOOKING Outbox는 같은 트랜잭션으로 commit한다. 취소는 CONFIRMED→CANCELLED 때만 CANCEL을 생성하며 재취소가 재판매 좌석을 풀지 않는다. 해제·만료는 CANCEL 이벤트가 아니다. 만료 시각은 expires_at <= 서버 현재 시각이며 주기 작업과 예약 경로에서 정리한다.

paymentIdentifier는 TEST_PAYMENT_IDENTIFIERS의 서버 허용 목록 값이며 실제 카드번호나 hash가 아니다. 서버 관측 peer IP를 사용한다. TRUSTED_PROXIES에 지정한 프록시에서 온 요청만 X-Forwarded-For의 클라이언트 IP를 쓰고(#64), 그 외에는 Forwarded/X-Forwarded-For를 신뢰하지 않는다.

## 예매 시도

| API | 인증 | 요청 / 응답 |
|---|---|---|
| GET /api/v1/booking-attempts/capabilities | 불필요 | 200; {enabled:boolean} |
| PUT /api/v1/concerts/{concertId}/booking-attempts/{attemptId} | 필수 | 선택 clientOccurredAt; 200; AttemptSnapshot |
| GET /api/v1/booking-attempts/{attemptId} | 필수 | 200; AttemptSnapshot |
| POST /api/v1/booking-attempts/{attemptId}/transitions | 필수 | transitionId,stage,status; 200; AttemptSnapshot |

AttemptSnapshot은 `{attemptId,concertId,stage,status,sequence,holdId,bookingId}`다. BOOKING_ATTEMPTS_ENABLED=false이면 capability만 false를 반환하고 attempt API는 503이며 기존 attempt 없는 예매는 유지한다. 상세 전이와 멱등성은 [예매 시도 명세](booking-attempts.md)를 따른다.

## 티켓과 동적 QR

예매 좌석 1개가 티켓 1장(`admission_tickets`)이다. 티켓마다 활성 기기를 1대 등록하고, 등록된 기기가 30초마다 QR을 직접 만든다. 서버는 QR을 발급하지 않는다. 검표는 QR 스캔 뒤 등록 기기가 서버 챌린지에 개인키로 서명해야 확정된다. CHECKIN_ENABLED=false이면 아래 API는 모두 503/SERVICE_UNAVAILABLE이며 기존 예매·취소는 영향이 없다.

| API | 인증 | 요청 | 성공 |
|---|---|---|---|
| GET /api/v1/bookings/{bookingId}/tickets | Bearer, 예매 소유자 | 없음 | 200; Ticket[] |
| POST /api/v1/tickets/{ticketId}/device-challenges | Bearer, 티켓 소유자 | body 없음 또는 `{}` | 201; `{challengeId,challenge,expiresAt}` |
| POST /api/v1/tickets/{ticketId}/device | Bearer, 티켓 소유자 | `{challengeId,publicKey,proof}` | 201; Enrollment (최초 등록) |
| POST /api/v1/tickets/{ticketId}/device/change | Bearer, 티켓 소유자 | `{challengeId,publicKey,proof}` | 200; Enrollment (기기 변경) |
| POST /api/v1/check-ins | X-Gate-Key | `{qr}` | 201; CheckInScan (status=PENDING, 입장 미확정) |
| GET /api/v1/check-ins/{checkInId} | X-Gate-Key | 없음 | 200; CheckInScan |
| GET /api/v1/tickets/{ticketId}/check-in-challenge | Bearer, 티켓 소유자 | 없음 | 200; CheckInChallenge 또는 대기 중인 챌린지가 없으면 null |
| POST /api/v1/tickets/{ticketId}/check-in-proofs | Bearer, 티켓 소유자 | `{checkInId,proof}` | 200; CheckInResult (입장 확정) |

- Ticket: `{ticketId,seatId,status,checkedInAt,device}`. status는 ISSUED/CHECKED_IN/CANCELLED. device는 `{deviceId,registeredAt,changesRemaining}` 또는 미등록이면 null이다. 공개키·비밀키는 조회 응답에 없다.
- Enrollment: `{ticketId,deviceId,totp:{secret,algorithm:"SHA1",digits:6,period:30},registeredAt,serverTime,changesRemaining}`. `totp.secret`(20바이트의 base64url)은 이 응답에서 한 번만 전달되며 다시 조회할 수 없다. `serverTime`은 기기 시계 보정용이다.
- publicKey는 ECDSA P-256 공개키 SPKI DER의 base64url(패딩 없음)이다. 다른 곡선·형식은 400/DEVICE_KEY_INVALID다.

### 기기 등록과 변경

1. 클라이언트가 Web Crypto로 non-extractable ECDSA P-256 키 쌍을 만든다. 개인키는 서버로 보내지 않는다.
2. `device-challenges`로 일회성 챌린지를 받는다. 유효 시간은 기본 2분이며 티켓·사용자당 미사용 챌린지는 최신 1개만 유효하다.
3. 개인키로 `<목적>.<ticketId>.<challenge>.<publicKey>` 문자열(UTF-8)에 서명(SHA-256, r‖s 64바이트의 base64url)해 `proof`로 보낸다. 목적은 최초 등록 `BTS-DEVICE-REGISTER`, 변경 `BTS-DEVICE-CHANGE`다.
4. 서버는 소유자·티켓 상태·챌린지·서명을 검증하고 챌린지를 소비한 뒤 티켓별 TOTP 비밀키를 새로 만들어 AES-256-GCM으로 암호화 저장한다.

최초 등록과 변경은 별도 endpoint다. 이미 등록된 티켓의 `device` 호출은 409/DEVICE_ALREADY_REGISTERED, 미등록 티켓의 `device/change`는 409/DEVICE_NOT_REGISTERED다. 등록된 기기에서 QR 화면을 다시 여는 것은 서버 호출 없이 저장된 키를 그대로 쓰며 등록·변경이 아니다. 변경은 기존 바인딩을 즉시 폐기하고 저장된 비밀키를 삭제하며, 티켓당 최대 3회(DEVICE_MAX_CHANGES)다. 초과는 409/DEVICE_CHANGE_LIMIT다. 만료·소비·다른 티켓/사용자의 챌린지와 잘못된 서명은 403/DEVICE_PROOF_INVALID다. 입장 완료·취소된 티켓은 409/TICKET_NOT_ADMITTABLE다.

브라우저 저장소 삭제·기기 분실·등록 응답 유실은 모두 "기기 변경"으로 복구하며 횟수를 차감한다. 횟수를 다 쓰면 API로는 복구할 수 없다.

### QR 형식과 검표

QR 내용은 `BTS1.<ticketId>.<deviceId>.<epochSeconds>.<totp>.<signature>`다. totp는 RFC 6238(HMAC-SHA1, 6자리, 30초), signature는 앞 다섯 필드 문자열에 대한 기기 개인키 서명이다. QR은 등록 기기가 30초마다 직접 만들며 QR 생성·갱신에는 서버 호출이 없다. 검표기는 내용을 해석하지 않고 그대로 `qr`에 담아 보낸다. `X-Gate-Key`는 서버 설정 GATE_API_KEY와 일치해야 하며 Demo 사용자 세션은 검표 권한이 아니다.

QR 속 서명은 "등록 기기가 그 시각에 이 QR을 만들었다"는 것만 증명한다. 캡처해 다른 사람에게 보낸 QR도 유효 시간 안에는 같은 값이므로, 검표는 **스캔 시점에 등록 기기가 개인키를 갖고 있는지**를 따로 확인하는 2단계로 진행한다.

| 단계 | 호출 | 동작 |
|---|---|---|
| 1. 스캔 | 검표기 `POST /check-ins` | QR 검증 후 일회성 챌린지를 발급한다. **입장 처리는 하지 않는다.** 응답 status는 PENDING |
| 2. 챌린지 수신 | 등록 기기 `GET /tickets/{ticketId}/check-in-challenge` | QR 화면이 열려 있는 동안 약 1초 간격으로 조회한다. 관객 조작은 없다 |
| 3. 응답 | 등록 기기 `POST /tickets/{ticketId}/check-in-proofs` | `BTS-CHECKIN.<ticketId>.<deviceId>.<checkInId>.<challenge>` 문자열(UTF-8)에 기기 개인키로 서명(SHA-256, r‖s 64바이트의 base64url)해 `proof`로 보낸다 |
| 4. 확정 | 서버 | 등록된 공개키로 서명을 검증하고 성공했을 때만 CHECKED_IN 전환과 CHECK_IN Outbox 저장을 한 트랜잭션에서 수행한다 |
| 5. 결과 | 검표기 `GET /check-ins/{checkInId}` | status가 PENDING이 아닐 때까지 조회해 화면에 표시한다 |

- CheckInScan: `{checkInId,status,ticketId,concertTitle,seatId,expiresAt,checkedInAt}`. 챌린지 값은 검표기에 내려가지 않는다. checkedInAt은 COMPLETED일 때만 있다.
- CheckInChallenge: `{checkInId,deviceId,challenge,expiresAt}`. deviceId는 QR이 스캔된 활성 기기이며, 다른 기기는 응답하지 않는다.
- CheckInResult: `{ticketId,concertTitle,seatId,checkedInAt}`.

스캔 시 서버는 예매 행을 잠근 뒤 순서대로 검증한다: 활성 바인딩의 deviceId 일치 → 기기 서명 → `epochSeconds`가 서버 시각 기준 ±1 step → TOTP 일치 → 티켓 ISSUED·예매 CONFIRMED → 입장 가능 시간(예매 snapshot의 공연 시작 − CHECKIN_OPENS_BEFORE 이상, 공연 종료 미만). 통과하면 32바이트 난수 챌린지를 만든다.

챌린지 규칙:

- 유효 시간은 CHECKIN_CHALLENGE_TTL(기본 15초)이다. 지나면 올바른 서명도 거부되고 검표기에는 EXPIRED로 보인다.
- 일회성이다. 서명 검증에 성공하면 COMPLETED, 잘못된 서명·확정 시점에 사용할 수 없게 된 티켓이면 REJECTED로 소비되며 같은 챌린지로는 다시 시도할 수 없다.
- 티켓당 미완료 챌린지는 1개다. 같은 티켓을 다시 스캔하면 이전 챌린지는 SUPERSEDED가 되고 새 챌린지만 유효하다. 여러 검표기가 동시에 스캔해도 유효한 챌린지는 하나다.
- 챌린지는 스캔된 기기 바인딩에 묶인다. 스캔 후 기기를 변경하면 이전·새 기기 모두 그 챌린지에 응답할 수 없다.
- 확정 시점에도 예매 행을 잠그고 티켓 상태·입장 시간을 다시 확인하며 `status='ISSUED'` 조건부 UPDATE로 한 번만 전환한다. 같은 응답이 동시에 여러 번 와도 한 건만 성공한다.
- 만료·실패 후에는 QR을 다시 스캔하면 새 챌린지로 재시도된다. 유효 시간 안의 같은 QR도 다시 스캔할 수 있다(QR 자체는 입장 권한이 아니다).

| 결과 | 응답 |
|---|---|
| 스캔: 형식 오류 | 400 / QR_INVALID |
| 검표 담당자 키 없음·불일치 | 401 / UNAUTHORIZED |
| 스캔: 폐기된·다른 기기, 서명 불일치, TOTP 불일치 | 403 / QR_REJECTED |
| 스캔: 시각이 허용 범위 밖 | 403 / QR_EXPIRED |
| 스캔·응답: 입장 가능 시간 아님 | 403 / CHECKIN_NOT_OPEN |
| 응답: 만료·소비·대체·다른 티켓의 챌린지, 잘못된 서명, 스캔 후 기기 변경 | 403 / CHECKIN_PROOF_INVALID |
| 챌린지 조회·응답: 티켓 소유자가 아님 | 403 / FORBIDDEN |
| 없는 티켓 | 404 / TICKET_NOT_FOUND |
| 결과 조회: 없는 checkInId | 404 / CHECKIN_NOT_FOUND |
| 스캔·응답: 이미 입장 | 409 / TICKET_ALREADY_CHECKED_IN |
| 스캔·응답: 취소된 예매·티켓 | 409 / TICKET_NOT_ADMITTABLE |

### 보안 한계

- TOTP 비밀키만 복사해서는 QR을 만들 수 없다. 서버는 활성 바인딩의 공개키에 대응하는 개인키 서명을 요구한다.
- 캡처한 QR만 전달받은 사람은 입장할 수 없다. 스캔은 통과해도 챌린지에 서명할 개인키가 없어 검표가 확정되지 않는다.
- **챌린지 응답은 자동이며 "개인키를 지금 갖고 있다"는 것만 증명한다. 기기가 검표기 앞에 있다는 것은 증명하지 않는다.** 판매자가 QR 화면을 켜 둔 채 구매자가 캡처본을 제시하면(실시간 공모), 또는 줄 서 있는 관객의 QR을 몰래 촬영해 먼저 제시하면 등록 기기가 자동으로 응답해 입장이 확정된다. 이번 범위에서는 방어하지 않는다. 방어하려면 검표기 표시 코드를 관객이 확인·입력하게 하거나 NFC/BLE 등 근접 통신이 필요하다.
- 입장 시 등록 기기가 온라인이어야 한다. 네트워크가 안 되는 기기는 챌린지를 받을 수 없어 EXPIRED가 되며, 이를 대신할 오프라인 검표 경로는 없다.
- 캡처본을 가진 사람이 반복해서 스캔하면 그때마다 소유자의 진행 중인 챌린지가 대체된다. 입장은 못 하지만 유효 시간 동안 소유자의 검표를 지연시킬 수 있다.
- non-extractable 키는 키 원문 유출만 막는다. XSS나 같은 브라우저 프로필에 접근한 공격자는 키를 "사용"해 QR과 챌린지 응답을 만들 수 있다. 하드웨어 증명(attestation)이 없어 "기기"는 사실상 "브라우저 프로필"이다.
- Demo 로그인은 ID 입력만으로 세션을 발급하므로 ID를 아는 사람은 기기 변경을 호출할 수 있다. 계정을 넘겨받은 구매자는 기기 변경(티켓당 3회)으로 자기 기기를 등록할 수 있으며, 변경 횟수 제한과 `deviceChanged` 이벤트 필드로 흔적만 남긴다.
- 검표 담당자 키는 공유 정적 키다. 담당자별 계정·권한 회수·시도 횟수 제한은 없다.
- 비밀키 전달은 TLS에 의존한다. 운영 환경은 HTTPS가 필수이며 Web Crypto와 카메라도 보안 컨텍스트(HTTPS 또는 localhost)에서만 동작한다.
- TOTP 비밀키, 서명, QR 원문, 챌린지, 검표 담당자 키는 로그·이벤트 payload에 남기지 않는다. 로그에는 ticketId·deviceId·checkInId·결과 코드만 기록한다.

## 프론트엔드 연동 경계

실제 Demo 로그인과 예매에는 VITE_USE_MOCK_BTS=false와 VITE_USE_MOCK_TICKETING=false를 설정한다. 실제 예매 설정에서는 대기열도 실제 API를 사용한다. 단계 관측은 sessionStorage에 attempt/transition 식별자와 미확정 전이를 먼저 저장한 뒤 재전송한다. 화면 새로고침은 서버의 attempt·hold·booking 상태로 복원한다.

카드 관리·사용자 신용 화면에는 Mock 또는 미구현 API adapter가 남아 있다. Demo에는 카드 등록·BTS 사용자 상세 프록시 API가 없다. 실제 API 모드의 QR 모달은 기기 키(IndexedDB의 non-extractable CryptoKey)로 동적 QR을 만들고, Mock 모드는 VITE_MOCK_QR의 정적 mock QR만 표시한다. QR 화면은 검표 챌린지를 약 1초 간격으로 조회해 자동으로 서명하며, 이 조회는 QR 생성과 무관하다. 검표기 화면은 `/gate`이며 로그인 없이 검표 담당자 키로 사용하고, 스캔 후 "기기 확인 중" 상태로 등록 기기의 응답을 기다린다. QR 표시나 브라우저 텔레메트리를 CHECK_IN으로 보내지 않는다. CHECK_IN은 서버 검표 성공으로만 생성된다. BTS UUID/Key를 브라우저 세션 식별자로 대체하지 않는다.

서버 간 계약은 [BTS 연동 명세](bts-integration.md), 저장 구조는 [DB 명세](erd.md)를 따른다.
