# Demo–BTS 실서버 통합 시나리오 (#47, #53)

Demo(ticket-fds-demo-ticketing)와 BTS(ticket-fds-admin)를 실제 MySQL·Redis로 함께 띄우고, Demo HTTP API로 행동을 만든 뒤 **두 DB를 직접 조회해** 연동 결과를 검증합니다.

## 준비
- Docker Desktop 실행 중
- JDK 17
- 두 저장소를 같은 상위 폴더에 체크아웃 (예: `C:\dev\CD-BTS\ticket-fds-admin`, `C:\dev\CD-BTS\ticket-fds-demo-ticketing`)
  - 다른 위치라면 `Start-E2E.ps1 -AdminRepo <경로>`로 지정합니다.
- 검증 대상 브랜치
  - BTS: 밀리초 `occurredAt`을 받는 버전 (ticket-fds-admin#45 이후)
  - Demo: #44, #46 반영 버전

## 실행 (PowerShell)
```powershell
cd e2e
.\Start-E2E.ps1          # DB 컨테이너 + BTS(18080) + Demo(18081) 기동
.\Run-Scenarios.ps1      # 전체 시나리오. 일부만: -Only booking,outage
.\Stop-E2E.ps1           # 백엔드 종료 + 컨테이너 삭제
```

## 환경
- **격리:** `compose.yaml`은 `cdbts-e2e` 프로젝트로 컨테이너를 따로 만듭니다.
  - BTS MySQL 3317, Demo MySQL 3318, Redis 6390
  - 기존 개발용 컨테이너·볼륨(`fairticket-mysql`, `demo-ticketing-*`)은 건드리지 않습니다.
- **데이터:** tmpfs에만 저장되므로 `Stop-E2E.ps1`을 실행하면 모두 사라집니다.
- **API 키:** 실행할 때마다 테스트용 서비스 키와 관리자 키를 새로 만듭니다.
  - 키는 `e2e/.run/keys.json`에만 저장되고 커밋에서 제외됩니다.
  - BTS에는 SHA-256 해시만 전달합니다.
- **로그:** `e2e/.run/bts.log`, `e2e/.run/demo.log`
- **BTS DB URL:** admin README의 URL(`serverTimezone=Asia/Seoul`)을 그대로 씁니다. 결과 문서의 발견 사항 3을 참고하세요.
- **Demo 설정:** `POLICY_DECISION_MODE=bts`, `CAPTCHA_MODE=disabled`, `BOOKING_ATTEMPTS_ENABLED=true`, `BTS_CONCERT_SYNC_MS=60000`
- **검표 설정 (#53):** `CHECKIN_ENABLED=true`. e2e Demo DB에는 05(기기 바인딩)·07(검표 챌린지) 스크립트도 적용됩니다.
  - 검표 담당자 키와 TOTP 비밀키 암호화 키도 실행할 때마다 새로 만들어 `e2e/.run/keys.json`에만 둡니다.
  - seed 공연이 미래 날짜라 `CHECKIN_OPENS_BEFORE=P365D`로 입장 가능 시간을 넓힙니다.
  - 챌린지 만료를 빨리 확인하려고 `CHECKIN_CHALLENGE_TTL=PT6S`를 씁니다(기본값은 15초).

## 시나리오
| 이름 (`-Only`) | 검증 내용 |
|---|---|
| `concert` | 공연 동기화: 개수, ID·이름·장소, 시작·종료 시각(UTC)이 BTS DB·관리자 API·Demo API에서 일치 |
| `booking` | 시도 → 대기열 → 선점 → 결제 → 확정 → 취소 후 다음을 확인<br>· 사용자 UUID 매핑<br>· Outbox 전부 SENT<br>· BTS 저장 건수가 Outbox와 같음(누락·중복 없음)<br>· 밀리초 `occurredAt` 일치<br>· concertId·attemptId·bookingId 매핑<br>· 관리자 공연별 참여자 조회<br>· QUEUE_JOIN·BOOKING_ATTEMPT 정책 기록 |
| `abandon` | 예매 없이 포기한 시도도 BOOKING_ATTEMPT로 저장되고, BOOKING은 생기지 않음 |
| `restrict` | BTS에서 RESTRICT 판정을 받은 사용자<br>· 대기열 통과 후 위험도가 올라간 경우: 좌석 선점 403 `BOOKING_RESTRICTED`<br>· 처음부터 RESTRICT인 경우: 대기열 403 `QUEUE_RESTRICTED` |
| `outage` | BTS 프로세스 중지 중<br>· 신규 대기열 입장 503<br>· 이미 입장한 사용자의 좌석 선점은 허용<br>· 이벤트는 Outbox에 RETRY로 남음<br>BTS 재기동 후: 전부 재전송, 유실·중복 없음 |
| `replay` | 같은 이벤트를 다시 보내면 200이고 저장 건수는 그대로. 같은 ID에 다른 내용이면 409 |
| `concurrency` | 8명이 같은 좌석을 동시에 선점<br>· 1명만 201, 나머지 409<br>· 모든 이벤트가 BTS에 1회씩 저장<br>· 실패한 7건이 SEAT_HOLD/REJECTED로 기록 |
| `ai` | (`-AiUrl`로 기동한 경우만) 정상 사용자와 매크로형 사용자(짧고 일정한 간격 시도 12번)를 만든 뒤 다음을 확인<br>· BTS가 ticket-fds-ai로 평가해 두 사용자 모두 OK<br>· 정상 사용자 점수 0.5 미만, 매크로형 0.5 이상<br>· Credit 반영과 `credit_history` 기록<br>· 관리자 사용자 상세에 최신 점수 표시<br>· 매크로형 사용자의 다음 대기열 입장이 AI 점수 근거로 ALLOW가 아님 |
| `checkin` | 예매 → 기기 등록 → QR 생성 → 스캔 → 챌린지 서명 → 입장 확정 후 다음을 확인<br>· 잘못된 QR·만료된 TOTP·미등록 기기 서명·만료/재사용 챌린지·중복 검표 거부, 실패 시 티켓 상태 불변<br>· 티켓 `CHECKED_IN`, `checked_in_at` 기록<br>· Outbox `CHECK_IN`이 스케줄러로 전송돼 SENT<br>· BTS `behavior_event` 저장, 사용자·티켓·예매·공연·발생 시각 매핑<br>· 재전송 시 중복 저장 없음<br>· 관리자·서비스 API의 CHECK_IN 조회와 프론트엔드 타입 일치 |

`checkin` 시나리오는 스크립트가 브라우저 기기 역할을 합니다. ECDSA P-256 키를 만들고 실제 API로 등록한 뒤 QR과 챌린지 응답에 직접 서명합니다(`E2E-Common.ps1`). 서버의 인증·서명 검증은 우회하지 않습니다.

`restrict` 시나리오는 RESTRICT 경계(Credit 20 미만 + 이상 점수 0.85 이상)를 확실히 만들려고 BTS DB에 위험도를 직접 넣습니다(`credit_score=10`, `anomaly_score=0.93`). 실제 AI 점수로 이어지는 흐름은 `ai` 시나리오가 검증합니다.

### AI 연동 시나리오 (`ai`, #62)
ticket-fds-ai 서버를 먼저 띄운 뒤 `-AiUrl`로 기동합니다. 그러면 BTS가 `AI_ENABLED=true`, `AI_POLL_MS=5000`으로 실행됩니다(ticket-fds-admin `docs/ai-design.md`).
```powershell
# ticket-fds-ai 저장소에서: python train_fds_model.py; uvicorn app.main:app --port 8000  (또는 Docker 이미지)
.\Start-E2E.ps1 -AiUrl http://127.0.0.1:8000
.\Run-Scenarios.ps1                 # -AiUrl 없이 기동하면 ai 시나리오는 [SKIP]
```
e2e는 모든 예매가 127.0.0.1과 공용 테스트 결제수단으로 들어옵니다. 그래서 예매한 사용자의 `ipBookingDensity`·`cardReuseCount`는 다른 시나리오 사용자 수만큼 커지고, 이상 점수도 올라갑니다. `ai` 시나리오의 정상 사용자는 이 영향을 받지 않도록 예매하지 않고 시도만 합니다.

결과와 발견 사항:
- [docs/e2e-result-2026-11-19.md](../docs/e2e-result-2026-11-19.md) (#47)
- [docs/checkin-e2e-result-2026-11-22.md](../docs/checkin-e2e-result-2026-11-22.md) (#53 QR 검표·관람 이벤트 연동)
