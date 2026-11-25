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
- **BTS 스키마:** 새 컨테이너는 ticket-fds-admin의 `backend/db/schema.sql` 하나로 초기화됩니다. 이 파일에 `risk_assessment_cursor`(#62)와 #67의 `risk_assessment_attempt`·`credit_calculation`·`policy_application`·추가 컬럼이 모두 들어 있습니다.
  - `db/manual/*.sql`은 기존 DB용이므로 e2e에는 적용하지 않습니다(적용하면 중복 컬럼 오류).
  - healthcheck가 마지막 테이블인 `policy_application`까지 확인합니다. ticket-fds-admin이 #67 이전 버전이면 기동이 실패합니다.
- **Demo 스키마:** 기존 스크립트에 더해 `09-policy-application-outbox.sql`(#67)이 적용됩니다.
- **Demo 설정:** `POLICY_DECISION_MODE=bts`, `CAPTCHA_MODE=mock`, `BOOKING_ATTEMPTS_ENABLED=true`, `BTS_CONCERT_SYNC_MS=60000`
  - CAPTCHA는 산술 문제(mock)입니다. 정책 적용 기록의 CAPTCHA 요구·통과·실패를 외부 공급자 없이 검증하려고 켭니다(#67).
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
| `ai` | (`-AiUrl`로 기동한 경우만) 정상 사용자와 매크로형 사용자(짧고 일정한 간격 시도 12번)를 만든 뒤 다음을 확인<br>· BTS가 ticket-fds-ai로 평가해 두 사용자 모두 OK<br>· 정상 사용자 점수 0.5 미만, 매크로형 0.5 이상<br>· Credit 반영과 `credit_history` 기록<br>· 관리자 사용자 상세에 최신 점수 표시<br>· 매크로형 사용자의 다음 대기열 입장이 AI 점수 근거로 ALLOW가 아님<br>· 그 조치가 실제로 적용되고 적용 기록이 BTS `policy_application`에 저장됨(#67), 정상 사용자는 기록 없음 |
| `policy` | 정책별 실제 적용 기록(#67). 위험도는 fixture로 정함(아래 참고)<br>· REQUIRE_CAPTCHA: 요구 → 실패 → 통과가 같은 결정에 `CHALLENGED`·`FAILED`·`PASSED`로 기록<br>· DELAY: 후순위 배치 `DELAYED` 1건만<br>· RESTRICT: 좌석 선점 거부·대기열 입장 거부 각각 `BLOCKED`<br>· ALLOW, 결정만 받고 이탈한 사용자는 기록 없음<br>· 사용자·공연별 decisionId 정합성, `policy_decision.concert_id` 전달<br>· Outbox 전부 SENT, BTS 저장 건수·ID·적용 시각 일치, 재전송 200·다른 내용 409<br>· `behavior_event`·AI 평가 대상에 들어가지 않음<br>· 관리자 API `sanctions`: 공연별·요약 실제 제재 사용자 수, 정책별 적용 횟수, CAPTCHA 요구·통과·실패, 예상 제재와의 구분, CAPTCHA 결과가 적용 횟수로 중복 집계되지 않음 |
| `policy-outage` | 좌석 선점 거부 직후 BTS 중지<br>· 적용 기록이 Outbox에 RETRY로 대기<br>· BTS 중지 중에도 Demo 조회·선점 동작 유지<br>BTS 재기동 후: 같은 기록이 한 번만 저장 |
| `checkin` | 예매 → 기기 등록 → QR 생성 → 스캔 → 챌린지 서명 → 입장 확정 후 다음을 확인<br>· 잘못된 QR·만료된 TOTP·미등록 기기 서명·만료/재사용 챌린지·중복 검표 거부, 실패 시 티켓 상태 불변<br>· 티켓 `CHECKED_IN`, `checked_in_at` 기록<br>· Outbox `CHECK_IN`이 스케줄러로 전송돼 SENT<br>· BTS `behavior_event` 저장, 사용자·티켓·예매·공연·발생 시각 매핑<br>· 재전송 시 중복 저장 없음<br>· 관리자·서비스 API의 CHECK_IN 조회와 프론트엔드 타입 일치 |

`checkin` 시나리오는 스크립트가 브라우저 기기 역할을 합니다. ECDSA P-256 키를 만들고 실제 API로 등록한 뒤 QR과 챌린지 응답에 직접 서명합니다(`E2E-Common.ps1`). 서버의 인증·서명 검증은 우회하지 않습니다.

`restrict` 시나리오는 RESTRICT 경계(Credit 20 미만 + 이상 점수 0.85 이상)를 확실히 만들려고 BTS DB에 위험도를 직접 넣습니다(`credit_score=10`, `anomaly_score=0.93`). 실제 AI 점수로 이어지는 흐름은 `ai` 시나리오가 검증합니다.

### fixture 기반 검증과 실제 AI 기반 검증의 구분 (#67)
| 시나리오 | 위험도 출처 | 검증 범위 |
|---|---|---|
| `restrict`, `policy`, `policy-outage` | BTS DB에 직접 넣은 값. `risk_assessment.model_version='e2e-manual'` | 정책별 적용 시점, 적용 기록, 전송, 관리자 집계. **AI 통합 검증이 아님** |
| `ai` | ticket-fds-ai가 실제 이벤트로 계산한 점수 | 이벤트 → AI 평가 → Credit → 정책 → 실제 적용 → 적용 기록 |

- `policy` fixture 값: Credit 30·평가 없음 → REQUIRE_CAPTCHA, Credit 10·평가 없음 → DELAY, Credit 10·점수 0.93 → RESTRICT (ticket-fds-admin `PolicyDecisionService` 기준).
- fixture 사용자는 `X-Booking-Attempt` 없이 진행해 `behavior_event`를 만들지 않습니다. 이벤트가 생기면 `-AiUrl` 기동 시 BTS가 재평가해 넣어 둔 값이 바뀔 수 있습니다.
- `policy-outage`는 "적용 직후 BTS 중지"라 Demo의 전송 주기(5초)와 경합합니다. 중지 전에 전송이 끝나면 새 사용자로 최대 3번 다시 시도하고, 그래도 안 되면 `[SKIP]`으로 표시합니다. 재시도 동작 자체는 `PolicyApplicationOutboxMySqlTests`가 결정적으로 검증합니다.
- 관리자 통계는 다른 시나리오의 기록과 섞이지 않도록 시나리오 전후의 **증가분**으로 판정합니다.

### AI 연동 시나리오 (`ai`, #62)
ticket-fds-ai 서버를 먼저 띄운 뒤 `-AiUrl`로 기동합니다. 그러면 BTS가 `AI_ENABLED=true`, `AI_POLL_MS=5000`으로 실행됩니다(ticket-fds-admin `docs/ai-design.md`).
```powershell
# ticket-fds-ai 저장소에서: python train_fds_model.py; uvicorn app.main:app --port 8000  (또는 Docker 이미지)
.\Start-E2E.ps1 -AiUrl http://127.0.0.1:8000
.\Run-Scenarios.ps1                 # -AiUrl 없이 기동하면 ai 시나리오는 [SKIP]
```
`booking` 시나리오는 시도 시작·화면 단계 이벤트의 `ipAddress`가 BTS에 저장되고 BOOKING의 IP와 같은지, 서버 관측 단계에는 없는지, 재요청·재전송이 중복 저장되지 않는지도 확인합니다(#68). `ai` 시나리오는 그 IP로 BTS가 산출한 Credit 근거(`credit_calculation.recent_ip_attempt_count`, `ip_penalty`)와 `ip_booking_density`가 영향받지 않는지를 확인합니다.

**공유 IP와 IP 집중도 감점 (#68):** e2e의 모든 요청은 같은 루프백 주소에서 옵니다(`localhost`가 IPv6로 풀리면 `0:0:0:0:0:0:0:1`, 아니면 `127.0.0.1`로 기록됩니다). BTS의 IP 집중도 감점은 계정이 아니라 IP 단위(최근 10분 같은 IP의 고유 시도 5건 이상 → 5점)라서, 시나리오가 이어서 돌면 평가되는 사용자 대부분이 이 감점을 받습니다. 신규 사용자는 50 → 45로 NORMAL·ALLOW 구간에 남습니다. 점수가 예상과 다르면 `credit_calculation`의 감점 내역(ai·card·ip·variance)으로 근거를 확인하세요. 감점 기준 4건·5건 경계, 서비스 간 분리, 10분 창, IP 누락 처리는 ticket-fds-admin의 `RiskAssessmentCursorMySqlTests`가 검증합니다.

e2e는 모든 예매가 127.0.0.1과 공용 테스트 결제수단으로 들어옵니다. 그래서 예매한 사용자의 `ipBookingDensity`·`cardReuseCount`는 다른 시나리오 사용자 수만큼 커지고, 이상 점수도 올라갑니다. `ai` 시나리오의 정상 사용자는 이 영향을 받지 않도록 예매하지 않고 시도만 합니다.

결과와 발견 사항:
- [docs/e2e-result-2026-11-19.md](../docs/e2e-result-2026-11-19.md) (#47)
- [docs/checkin-e2e-result-2026-11-22.md](../docs/checkin-e2e-result-2026-11-22.md) (#53 QR 검표·관람 이벤트 연동)
