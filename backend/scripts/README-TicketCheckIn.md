# Issue #40: TOTP 동적 QR · 기기 바인딩 · 검표

계약은 [API 명세](../../docs/api-spec.md)의 "티켓과 동적 QR", 저장 구조는 [DB 명세](../../docs/erd.md), 이벤트는 [BTS 연동 명세](../../docs/bts-integration.md)를 따른다.

## 1. 스키마 적용 (한 번만)

`db/05-ticket-device-binding.sql`은 `ticket_device_bindings`, `ticket_device_challenges` 두 테이블을 추가한다. 기존 테이블·제약은 바꾸지 않는다. 반복 실행용이 아니므로 먼저 적용 여부를 확인한다.

```powershell
# backend 폴더에서. 데모 MySQL 컨테이너(demo-ticketing-mysql)가 떠 있어야 한다.
. .\scripts\MySql-Tools.ps1
Invoke-DemoMySql -Sql "SHOW TABLES LIKE 'ticket_device%'"          # 결과가 없을 때만 다음 줄 실행
Invoke-DemoMySql -Sql (Get-Content -Raw -Encoding UTF8 .\db\05-ticket-device-binding.sql)
Invoke-DemoMySql -Sql "SHOW TABLES LIKE 'ticket_device%'"          # 두 테이블 확인
```

- 적용 전에 백엔드를 멈추고, 보존할 데이터가 있으면 먼저 백업한다.
- 두 CREATE는 각각 자동 commit된다. 첫 테이블만 만들어지고 실패했다면 재실행하지 말고 남은 CREATE 문만 적용한다.
- 새 빈 볼륨으로 Compose를 처음 띄울 때도 04·05는 자동 적용되지 않는다(기존 04와 같은 방식).
- 되돌릴 때는 CHECKIN_ENABLED=false로 끈 뒤 `DROP TABLE ticket_device_challenges, ticket_device_bindings;`. 등록된 기기 정보는 모두 사라진다.

## 2. 환경변수 (backend/.env)

```
CHECKIN_ENABLED=true
TICKET_SECRET_KEY=<32바이트 난수의 Base64>
GATE_API_KEY=<16자 이상 난수>
CHECKIN_OPENS_BEFORE=PT2H
```

키 생성 예: `openssl rand -base64 32`(Git Bash) 또는 PowerShell 7의
`[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))`.

- 활성 상태에서 키가 없거나 형식이 틀리면 서버가 기동하지 않는다. 값은 로그에 출력하지 않는다.
- TICKET_SECRET_KEY를 바꾸면 이미 등록된 기기의 비밀키를 복호화할 수 없다. 해당 티켓은 기기 변경(횟수 차감)이 필요하다.
- **시연 시 입장 가능 시간**: seed 공연은 2026-12-12 이후라 기본값(PT2H)으로는 `CHECKIN_NOT_OPEN`이 된다. 시연에서는 `CHECKIN_OPENS_BEFORE=P90D`처럼 넓히거나 곧 시작하는 공연을 추가한다.

## 3. 테스트

```powershell
.\gradlew.bat test                             # TOTP(RFC 6238 벡터)·AES-GCM·서명·BTS CHECK_IN 계약
.\scripts\Invoke-Backend.ps1 -Task MySqlTest   # TicketCheckInMySqlTests 포함. 05가 적용된 DB 필요
```

`TicketCheckInMySqlTests`는 스키마를 바꾸지 않으며 05가 없으면 안내 메시지와 함께 실패한다. 무작위 공연·사용자만 만들고 정리한다. 검증 범위: 소유자·챌린지·소유 증명, 최초 등록과 변경의 구분, 변경 3회 한도와 이전 기기 폐기, 서명/TOTP/만료/입장 시간, 취소된 예매, 동시 스캔 1회 성공, CHECK_IN Outbox 전송 payload.

프론트엔드: `npm run test:totp` (브라우저 코드의 TOTP·QR 형식이 서버와 같은지 검증).

## 4. 시연

1. 백엔드를 위 환경변수로 실행하고 프론트엔드는 `VITE_USE_MOCK_BTS=false`, `VITE_USE_MOCK_TICKETING=false`로 `npm run dev`.
2. 관객: 로그인 → 예매 → 마이페이지 "QR 보기" → "이 기기를 입장 기기로 등록". 30초마다 QR이 바뀐다. 좌석이 여러 개면 탭으로 전환하며 좌석마다 등록한다.
3. 검표: 다른 창에서 `http://localhost:5173/gate` → 검표 담당자 키(GATE_API_KEY) 입력 → "카메라로 스캔"으로 관객 화면의 QR을 비추거나 QR 문자열을 붙여넣는다.
4. 확인할 장면: 입장 가능 → 같은 QR 재스캔 시 "이미 입장" → 관객 화면이 "입장 완료"로 전환 → 마이페이지에서 예매 취소 불가.
5. 기기 바인딩: 다른 브라우저(또는 시크릿 창)에서 같은 ID로 로그인하면 "다른 기기에 등록됨"이 보인다. "이 기기로 변경" 후 원래 브라우저의 QR은 `QR_REJECTED`가 된다.
6. 캡처 재사용: QR을 캡처해 두고 90초 뒤 스캔하면 `QR_EXPIRED`.

휴대폰으로 시연하려면 HTTPS가 필요하다. Web Crypto와 카메라는 `http://192.168.x.x`에서 동작하지 않는다(HTTPS 터널 또는 localhost 사용). 카메라 없이도 QR 문자열 입력으로 검표할 수 있다.

직접 호출 예(검표):

```powershell
$base = 'http://localhost:8080/api/v1'
Invoke-RestMethod -Method Post -Uri "$base/check-ins" -ContentType 'application/json' `
  -Headers @{ 'X-Gate-Key' = $env:GATE_API_KEY } -Body (@{ qr = '<QR 문자열>' } | ConvertTo-Json)
```

## 5. 한계

- 유효 시간(최대 약 90초) 안에 캡처본을 다른 사람이 먼저 제시하는 공격은 막지 못한다. 최초 1회만 성공한다.
- 브라우저 기기 바인딩은 하드웨어 보증이 없다. 같은 브라우저 프로필을 쓰는 공격자·XSS는 키를 사용할 수 있다.
- Demo 로그인은 ID 입력만으로 가능하므로 기기 변경의 "소유자 인증"도 그 수준이다.
- 검표 담당자 키는 공유 정적 키이며 시도 횟수 제한이 없다.
- 변경 횟수를 모두 쓴 티켓과 FAILED가 된 CHECK_IN 이벤트를 복구하는 운영 API는 없다.
