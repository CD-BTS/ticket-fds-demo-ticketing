# 최종 시연용 Showcase 환경 (#71)

발표 시연에 쓰는 별도 환경입니다. 실제 티켓팅 서비스와 비슷한 규모의 데이터를 만들고, 서버를 껐다 켜도 데이터가 남습니다.

기존 E2E 환경(`e2e/`)의 실행 방식(Docker DB + `gradlew bootRun`)과 스크립트를 그대로 재사용합니다. 차이는 두 가지입니다.
- DB를 tmpfs가 아니라 Docker named volume에 저장합니다.
- 인증 정보를 실행마다 새로 만들지 않고 계속 유지합니다.

> **이 문서의 데이터는 합성 데이터입니다.**
> - 과거 행동 이력은 BTS 행동 이벤트 API로 직접 넣은 것입니다.
> - 티켓팅 사이트(Demo) DB에는 실제 예매로 존재하지 않습니다.
> - 마이페이지에는 대표 계정이 이 환경에서 실제로 예매한 건만 보입니다.
> - 관리자 대시보드의 공연별 통계와 Demo의 좌석 판매 상태는 서로 다릅니다.

## 1. 구조

```
  브라우저 ─ 티켓팅 화면 :5183 (Vite) ─┐                ┌─ 관리자 대시보드 :5184 (Vite)
                                      ▼                ▼
                         Demo 백엔드 :28081 ──Outbox──▶ BTS 백엔드 :28080 ──▶ AI 서버 :8010
                           │      │                       │      (ticket-fds-ai Docker 이미지)
                Demo MySQL :3328  Redis :6391        BTS MySQL :3327
                                                         ▲
             Seed-Showcase.ps1 ── 과거 28일 합성 행동 이력 ─┘  (POST /api/v1/events)
```

| 구성 | 실행 방식 | 포트 | 데이터 |
|---|---|---|---|
| Demo Ticketing 백엔드 | `gradlew bootRun` | 28081 | |
| Demo Ticketing 프론트엔드 | `npm run dev` | 5183 | |
| BTS 백엔드 (ticket-fds-admin) | `gradlew bootRun` | 28080 | |
| BTS 관리자 프론트엔드 | `npm run dev` | 5184 | |
| AI 추론 서버 (ticket-fds-ai) | Docker (`compose.yaml`, 저장소의 Dockerfile 그대로 빌드) | 8010 | |
| Demo MySQL | Docker | 3328 | volume `cdbts-showcase_demo-mysql-data` |
| BTS MySQL | Docker | 3327 | volume `cdbts-showcase_bts-mysql-data` |
| Redis | Docker (AOF) | 6391 | volume `cdbts-showcase_demo-redis-data` |

**기존 환경과의 분리**

| 환경 | Docker 프로젝트 | MySQL | Redis | 백엔드 | 데이터 |
|---|---|---|---|---|---|
| Dev | (각 저장소) | 3307 / 3308 | 6380 | 8080 / 8081 | 개발용 볼륨 |
| E2E | `cdbts-e2e` | 3317 / 3318 | 6390 | 18080 / 18081 | tmpfs (종료 시 삭제) |
| **Showcase** | `cdbts-showcase` | 3327 / 3328 | 6391 | 28080 / 28081 | named volume (유지) |

- Showcase 스크립트는 `cdbts-showcase` 프로젝트의 컨테이너와 볼륨만 다룹니다.
- 모든 포트는 `127.0.0.1`에만 열립니다.

## 2. 사전 준비

| 항목 | 버전 |
|---|---|
| Docker Desktop | 실행 중이어야 함 |
| JDK | 17 |
| Node.js | 20 이상. 처음 실행할 때 `node_modules`가 없으면 `npm ci`를 자동 실행 |
| Python | 3.10 이상. 표준 라이브러리만 사용 |
| PowerShell | Windows PowerShell 5.1 또는 PowerShell 7 |

### 저장소

세 저장소를 **같은 상위 폴더**에 체크아웃하고 각각 `dev` 브랜치 최신으로 맞춥니다.

```
<상위 폴더>\
  ticket-fds-demo-ticketing\   ← 이 저장소 (showcase\)
  ticket-fds-admin\            ← BTS 백엔드·관리자 프론트엔드
  ticket-fds-ai\               ← AI 모델·추론 서버
```

폴더 이름이 다르거나 위치가 다르면 환경변수나 매개변수로 지정합니다.

```powershell
$env:ADMIN_REPO = 'D:\work\ticket-fds-admin'; $env:AI_REPO = 'D:\work\ticket-fds-ai'
# 또는 .\Start-Showcase.ps1 -AdminRepo D:\work\ticket-fds-admin -AiRepo D:\work\ticket-fds-ai
```

`ticket-fds-admin`, `ticket-fds-ai` 대신 `admin`, `ai`라는 폴더 이름도 자동으로 찾습니다.

### 인증 정보

**직접 만들 필요가 없습니다.** 처음 `Start-Showcase.ps1`을 실행할 때 다음 값을 무작위로 만들어 `showcase/.run/secrets.json`에 저장합니다.
- 서비스 API Key
- 관리자 API Key
- 검표 키
- 티켓 서명 키

이 값의 처리 방식은 다음과 같습니다.
- `.run/`은 `.gitignore`에 포함되어 커밋되지 않습니다.
- BTS에는 SHA-256 해시만 전달합니다.
- 재시작해도 같은 값을 씁니다. 그래서 등록된 기기·발급된 QR·관리자 로그인이 계속 유효합니다.

키를 바꾸려면 `Reset-Showcase.ps1 -RotateKeys`를 실행합니다.

## 3. 실행·종료

PowerShell을 `showcase` 폴더에서 엽니다.

```powershell
.\Start-Showcase.ps1        # 컨테이너 + BTS + Demo + 두 프론트엔드 기동 (처음에는 AI 이미지 빌드로 수 분)
.\Stop-Showcase.ps1         # 프로세스 종료 + 컨테이너 중지. 데이터·키는 유지
.\Start-Showcase.ps1        # 다시 켜면 이전 데이터 그대로
```

**자주 쓰는 옵션**

| 명령 | 용도 |
|---|---|
| `.\Start-Showcase.ps1 -Only bts -Restart` | BTS만 다시 기동 |
| `.\Start-Showcase.ps1 -NoWeb` | 프론트엔드 없이 기동 |
| `.\Stop-Showcase.ps1 -KeepContainers` | 프로세스만 종료 |

- 로그는 `showcase/.run/*.log`에 남습니다.
- 처음 실행하면 BTS DB에 Showcase 전용 성능 인덱스(`ix_showcase_event_type_time`)를 만듭니다. 이유는 9절을 참고하세요.

## 4. 데이터 생성

```powershell
.\Seed-Showcase.ps1                  # 전체: 공연 → 과거 이력 적재 → 실제 AI 평가 → 대표 계정 실제 티켓팅
```

단계적으로 검증하며 늘릴 때는 다음 순서로 실행합니다. 앞 단계 사용자는 다시 보내지 않습니다.

```powershell
.\Seed-Showcase.ps1 -Users 30 -LivePerPolicy 3   # 1차: 약 30명으로 전체 연동 검증
.\Seed-Showcase.ps1 -Users 300 -Steps load,evaluate
.\Seed-Showcase.ps1 -Users 1000 -Steps load,evaluate
.\Seed-Showcase.ps1                              # 전체 목표 규모 (약 1만 4천 명, 이벤트 약 39만 건)
.\Verify-Showcase.ps1                            # 결과 검증·통계
```

### 단계

| 단계 (`-Steps`) | 하는 일 |
|---|---|
| `concerts` | 시연 공연 10개와 좌석을 Demo DB에 넣습니다. `seed.sql`과 같은 등급·가격 구조이고, 없는 행만 추가합니다. 공연은 Demo의 공연 동기화와 같은 API(`PUT /api/v1/concerts/{id}`)로 BTS에 등록합니다. |
| `load` | 과거 28일 합성 행동 이력을 BTS 행동 이벤트 API로 보냅니다. 사용자 등록에는 `POST /api/v1/users`, 이벤트에는 `POST /api/v1/events`를 씁니다. |
| `evaluate` | BTS를 AI 평가가 켜진 상태로 되돌립니다. 그다음 **실제 평가 스케줄러**가 Feature 집계, AI 추론, 점수 저장, Credit 산출, 미입장 판정을 끝낼 때까지 기다립니다. |
| `live` | 평가가 끝난 사용자 중 정책별 대표 계정이 **실제 Demo API**로 예매합니다. 자세한 내용은 6절에 있습니다. |

### 중복 방지

- 사용자 ID(`sc-u00001`…), 시도·예매·티켓·이벤트 ID, 발생 시각은 seed와 기준 시각에서 결정적으로 만들어집니다. 처음 실행한 시각이 `.run/seed-state.json`에 기준 시각으로 고정됩니다.
- 재실행해도 같은 값이 나옵니다. BTS는 같은 `externalEventId`에 같은 내용이 오면 200(재전송)으로 처리하고 새로 저장하지 않습니다. 사용자 등록도 `externalUserId` 기준으로 멱등입니다.
- 이미 적재한 사용자는 `.run/users.json`에 기록되어 다시 보내지 않습니다. `-Replay`를 주면 일부러 다시 보내 중복이 생기지 않는지 확인합니다. 예: `.\Seed-Showcase.ps1 -Users 300 -Steps load -Replay`
- 대표 계정 실행 결과는 `.run/live-state.json`에 기록됩니다. 재실행하면 이미 실행한 계정은 건너뜁니다.

## 5. 공연별 데이터 규모

기준 시각을 T(처음 Seed 실행 시각)라고 할 때의 일정입니다. 예매 오픈은 20:00 KST, 공연은 19:00 KST에 시작해 3시간입니다.

| ID | 공연 | 좌석 | 목표 참여자 | 매크로 비율 | 예매 오픈 | 공연일 | 상태 |
|---|---|---:|---:|---:|---|---|---|
| sc01 | 인디 아티스트 단독 공연 | 200 | 300 | 3% | T−27일 | T−18일 | 종료 |
| sc02 | 어쿠스틱 라이브 콘서트 | 350 | 450 | 4% | T−26일 | T−14일 | 종료 |
| sc03 | 뮤지컬 갈라 콘서트 | 600 | 800 | 5% | T−25일 | T−10일 | 종료 |
| sc04 | 재즈 뮤직 페스티벌 | 700 | 1,000 | 6% | T−24일 | T−6일 | 종료 |
| sc05 | 가을 음악 축제 | 1,000 | 1,500 | 7% | T−22일 | T−3일 | 종료 |
| sc06 | 밴드 전국 투어 — 서울 | 1,500 | 3,000 | 8% | T−12일 | T+10일 | 예매 진행 중 |
| sc07 | 연말 스페셜 콘서트 | 2,000 | 5,000 | 10% | T−7일 | T+25일 | 예매 진행 중 |
| sc08 | 인기 아이돌 단독 콘서트 | 3,000 | 10,000 | 12% | T−2일 | T+18일 | 예매 진행 중 |
| sc09 | 클래식 오케스트라 공연 | 800 | 0 | – | T+5일 | T+40일 | 예매 예정 |
| sc10 | 신년 뮤직 페스티벌 | 2,500 | 0 | – | T+8일 | T+36일 | 예매 예정 |

**참여자 수**
- 전체 고유 사용자는 약 1만 4천 명이고, 그중 약 4,900명이 여러 공연에 참여합니다. 공연별 참여자 합(약 2만 2천)보다 적습니다.
- 이전 공연 참여자는 일정 확률로 다음 공연에 다시 참여합니다. 사람은 38%, 매크로는 55%입니다.

**좌석과 예매**
- 공연마다 좌석 수를 가진 시간 순서 시뮬레이션으로 만듭니다.
- 좌석 선점은 그 시각에 남은 좌석이 있을 때만 성공합니다. 오픈 직후에는 동시 선택 충돌로 거부(`SEAT_ALREADY_TAKEN`)될 수 있습니다.
- 선점 만료(5분)나 취소로 풀린 좌석은 이후 시도에 다시 팔립니다(재판매).
- 그래서 **(예매 매수 − 취소 매수)는 좌석 수를 넘지 않습니다.**

**시각 정합성**
- 예매 시도는 공연 시작 2시간 전까지만 합니다.
- 취소는 공연 시작 1시간 전까지만 합니다.
- 입장(CHECK_IN)은 공연 시작 90분 전부터 시작 전까지입니다.
- 기준 시각 이후의 이벤트는 만들지 않습니다.

**종료 공연의 입장과 미입장**
- 종료 공연의 유효 티켓은 입장(CHECK_IN 이벤트)하거나 미입장합니다.
- 미입장은 새 이벤트 타입을 만들지 않습니다. CHECK_IN이 없는 티켓을 BTS의 기존 `NoShowScheduler`가 공연 종료 1시간 뒤 `NO_SHOW`로 판정합니다.

**예매 예정 공연**(sc09, sc10)에는 이력을 만들지 않습니다.

## 6. 사용자 유형과 생성 방식

**참고한 기준**
- 행동 유형과 수치는 ticket-fds-ai의 v4 합성 데이터 정의를 참고했습니다. 파일은 `experiments/issue17-event-based-dummy/config/scenarios_v3.json`, `v4`, `generate_events_v3/v4.py`입니다.
- 학습·검증 데이터 파일은 읽지 않습니다.
- seed는 7171을 씁니다. 학습(2026), 검증(100~109), #17(0~9, 42)과 겹치지 않습니다.

| 유형 | 생성 시나리오 |
|---|---|
| 일반 사용자 | 사람 속도(단계별 수 초~수십 초). 성공 80%, 좌석 화면 이탈 12%, 선점 만료 8%. 취소율 Beta(1,9) |
| 빠른 정상 사용자 | 같은 흐름이지만 단계 시간이 짧고(속도 0.1~0.32) 오픈 직후 도착이 빠름. 2매 예매 비율이 높음 |
| IP 공유 정상 사용자 | 4~6명이 한 IP를 공유하고, 결제수단은 각자 다름 |
| 잦은 취소 사용자 | 취소율 50~80% |
| 미입장 사용자 | 종료 공연 티켓의 90%를 입장하지 않음 |
| 고정 간격 매크로 | 오픈 0~3초 안에 도착. 약 2.9초의 일정한 간격으로 6~32회 시도 |
| 랜덤 지연 매크로 | 3.9~6.3초의 불규칙한 간격으로 반복 시도 |
| 다중 계정 매크로 | 5~11개 계정이 같은 IP를 쓰고 결제수단을 공유(카드 1장당 최대 7계정). 도구는 고정·랜덤·사람 속도 중 하나 |
| 선점·취소 매크로 | 10~29회 좌석을 선점. 대부분은 결제하지 않고 만료시키고, 결제한 건도 약 20분 뒤 취소 |
| 신규 가입 | BTS에 가입만 하고 행동 이력이 없음. AI 평가 이력이 없는 사용자 |

**공연별 차이**
- 공연마다 매크로 비율과 오픈 직후 몰림 비율(`rush`)이 다릅니다. 인기 공연일수록 높습니다.
- 사람 유형의 비율은 일반 60%, 빠른 정상 12%, IP 공유 11%, 잦은 취소 8%, 미입장 9%입니다.

**IP와 결제수단**
- 사용자마다 IP(100.64.0.0/10)와 결제 식별자(`sc-pay-NNNNN`)가 있습니다.
- 이 값은 BOOKING의 `ipAddress`·`paymentIdentifier`와, 시도 이벤트 중 클라이언트 보고 단계의 `ipAddress`에 들어갑니다.

**사용자 유형과 실제 탐지 결과**

사용자 유형은 **데이터 생성 시나리오**일 뿐입니다. 실제 AI 탐지 결과와 같다고 가정하지 않습니다. 실제 결과는 `Verify-Showcase.ps1`의 "유형별 실제 AI 점수" 표로 확인합니다. 모델이 예상과 다르게 판정한 사례도 그대로 둡니다. 예를 들어 IP 공유 정상 사용자가 탐지되거나, 여러 공연에 나눠 시도한 매크로가 미탐지될 수 있습니다.

**이벤트 형식**

demo-ticketing이 실제로 보내는 것과 같습니다. 기준 코드는 `AttemptService`, `ReservationService`, `CheckInService`, `OutboxDeliveryService`입니다.

| 이벤트 | 형식 |
|---|---|
| BOOKING_ATTEMPT | `attemptId`(UUID), `transitionId`, `concertId`, `stage`, `status`, `sequence`, `source`, `recordedAt`.<br>클라이언트 보고 단계에는 `ipAddress`가 붙습니다. 선점 뒤에는 `holdId`, 예매 뒤에는 `bookingId`가 붙습니다.<br>단계는 `STARTED → QUEUE → SEAT_SELECTION → SEAT_HOLD(SUCCEEDED/REJECTED/EXPIRED) → PAYMENT → COMPLETED` 순서입니다. |
| BOOKING | `bookingId`(`b_…`), `concertId`, `performanceStartsAt/EndsAt`, `ticketIds`, `attemptId`, `bookingDurationSeconds`, `paymentIdentifier`, `ipAddress` |
| CANCEL | 같은 `bookingId`, `concertId`, 공연 시각, `ticketIds`, `attemptId` |
| CHECK_IN | 최상위 `ticketId`·`bookingId`, `concertId`, 공연 시각, `deviceChanged=false` |

**사용자 식별자 연동**

합성 사용자의 `externalUserId`(`sc-u00001`)는 Demo 로그인 ID와 같습니다. 그 사용자가 Demo에 로그인해 대기열에 들어가면, Demo가 같은 `externalUserId`로 BTS에 등록을 요청합니다. BTS는 기존 UUID를 돌려주므로 두 기록이 하나로 이어집니다. `Verify-Showcase.ps1`이 이 연결을 확인합니다.

## 7. 실제 AI 평가와 정책 적용

**AI 평가**

```
행동 이벤트 → BTS RiskAssessmentScheduler(5초 주기) → Feature 집계(최근 30일)
  → ticket-fds-ai /predict/batch (실제 모델) → risk_assessment 저장
  → Credit 산출(credit_history, credit_calculation) → 위험 등급 · 예상 정책
```

- AI 점수, Credit, 정책은 **DB에 직접 넣지 않습니다.**
- 모델, Feature 정의, Credit 계산식, 정책 임계값도 바꾸지 않았습니다.
- `Verify-Showcase.ps1`이 AI 서버 `/health`의 모델 버전과 저장된 점수의 모델 버전이 같은지 확인합니다.

바꾼 것은 BTS의 기존 환경변수뿐입니다.

| 환경변수 | Showcase 값 | 기본값 |
|---|---|---|
| `AI_POLL_MS` | 5000 | 60000 |
| `AI_MAX_USERS_PER_RUN` | 1000 | 500 |

**적재 중에는 AI 평가를 잠시 끕니다**

이력 적재(`load`) 중에는 BTS를 `AI_ENABLED=false`로 띄웁니다. 그렇지 않으면 한 사용자의 이벤트가 일부만 들어온 상태로 평가되어, 실제와 다른 Feature로 점수가 매겨집니다. 적재가 끝나면 AI 평가를 켜고 실제 스케줄러가 평가합니다.

**평가 완료 판정**

일정 시간을 기다리는 방식이 아닙니다. BTS 스케줄러의 평가 대상 조건(`RiskAssessmentCursorRepository`)을 같은 SQL로 확인해 남은 사용자가 0명이 되면 완료로 봅니다. 미입장 판정 대상 티켓이 0건인지도 함께 확인합니다.

**실제 티켓팅과 정책 적용 (`live` 단계)**

평가가 끝난 사용자 중에서 BTS가 내릴 조치별로 대표 계정을 고릅니다. 기본값은 조치별 10명입니다. 고른 계정은 예매 진행 중 공연(sc06~sc08)에 실제 Demo API로 들어갑니다.

| 예상 조치 | 실제 동작 |
|---|---|
| ALLOW | 대기열 → 좌석 선택 → 선점 → 결제 → 예매. 일부는 기기 등록 → 동적 QR → 검표 → 입장 → 재입장 거부까지 진행 |
| REQUIRE_CAPTCHA | CAPTCHA 요구 → 통과 / 한 번 틀린 뒤 통과 / 틀린 뒤 이탈 |
| DELAY | CAPTCHA 통과 → 대기열 후순위 배치 |
| RESTRICT | 대기열 입장 거부(`QUEUE_RESTRICTED`) |

- 실제 조치는 Demo가 BTS에 요청해 받은 결정(`policy_decision`)입니다.
- 적용 기록(`policy_application`)은 Demo Outbox를 거쳐 BTS로 전달됩니다.
- 예상과 실제가 다르면 그대로 기록합니다.
- 대표 계정의 실제 요청은 각자의 IP를 `X-Forwarded-For`로 보냅니다(아래 IP 설정 참고).

**IP와 결제 식별자 설정 (Showcase 전용)**

| 설정 | 값 | 이유 |
|---|---|---|
| `TRUSTED_PROXIES` (Demo) | `127.0.0.1,::1` | 로컬에서는 모든 요청이 루프백 IP 하나로 기록됩니다. 그러면 정상 사용자도 IP 밀집 감점을 받습니다. 이 PC에서 온 요청에 한해서만 `X-Forwarded-For`를 믿게 해 사용자별 IP를 분리합니다. 브라우저 요청은 그대로 루프백 IP입니다. |
| `TEST_PAYMENT_IDENTIFIERS` (Demo) | 기본 3개 + `sc-live-pay-001`~`300` | 대표 계정마다 서로 다른 결제 식별자를 씁니다. 기본값 3개만 쓰면 정상 사용자끼리 결제수단을 공유하게 됩니다. |
| `CHECKIN_OPENS_BEFORE` (Demo) | `P60D` | 예매 진행 중 공연의 티켓으로 QR 검표를 보여 주기 위해서입니다. E2E는 `P365D`를 씁니다. |
| `POLICY_DECISION_MODE`, `CAPTCHA_MODE` (Demo) | `bts`, `mock` | E2E와 같습니다. CAPTCHA는 산술 문제입니다. |

## 8. 시연 방법

### 관리자 대시보드

1. http://localhost:5184 에 접속합니다.
2. 서비스 ID에 `demo-ticketing`을 입력합니다.
3. 관리자 키에 `showcase/.run/secrets.json`의 `adminKey` 값을 입력합니다.

```powershell
(Get-Content -Raw -Encoding UTF8 .run\secrets.json | ConvertFrom-Json).adminKey
```

### 티켓팅 사이트

1. http://localhost:5183 에 접속합니다.
2. 로그인 ID에 대표 계정 ID(`sc-u…`)를 입력합니다.

### 대표 계정

`live` 단계가 고른 계정입니다. `Verify-Showcase.ps1`의 "대표 계정 실제 티켓팅 결과" 표와 `.run/live-state.json`에서 확인합니다.
- 사용자 ID와 유형은 seed가 같으면 같습니다.
- 조치별 대표는 실제 AI 평가 결과로 정해집니다. 재생성하면 달라질 수 있습니다.

| 시나리오 | 쓰는 계정 | 보여 줄 것 |
|---|---|---|
| 정상 예매 (ALLOW) | `live-state.json`의 `expected=ALLOW` 계정 | 마이페이지 예매 내역과 동적 QR, 관리자 사용자 상세의 Credit·AI 점수 |
| 추가 인증 | `expected=REQUIRE_CAPTCHA` 계정 | 대기열 입장 시 CAPTCHA. 관리자 공연 상세의 CAPTCHA 통과·실패 |
| 대기열 후순위 | `expected=DELAY` 계정 | CAPTCHA 후 대기 순번이 뒤로 감 |
| 예매 제한 | `expected=RESTRICT` 계정 (주로 다중 계정 매크로) | 대기열 입장 거부. 관리자에서 같은 IP·결제수단을 쓰는 계정들 |

**검표 화면**: 티켓팅 사이트의 검표 페이지에 검표 키(`secrets.json`의 `gateKey`)를 입력합니다.

### 주요 시연 순서

1. **대시보드 요약**: 전체 사용자, AI 평가·이상 사용자, Credit 분포, 예상 정책과 실제 제재
2. **공연 목록**: 10개 공연의 규모와 상태 차이
3. **sc08 인기 아이돌 공연 상세**
   - 오픈 직후 몰림(추이)과 실패 원인(좌석 경합)
   - 이상 사용자 비율, 실제 제재
4. **sc01~05 종료 공연**: 입장과 미입장 수
5. **사용자 상세**: 다중 계정 매크로 1명
   - AI 분석(Feature 6개, 점수)
   - Credit 산출 근거(AI·결제수단·간격 감점)
   - Credit 이력
6. **티켓팅 사이트**: 정상 계정과 제한 계정으로 각각 대기열에 입장해 차이 확인
7. **동적 QR 검표**: ALLOW 대표 계정의 티켓으로 시연

## 9. 데이터 유효 기간과 재생성

**30일 창**
- AI Feature는 **평가 시각 기준 최근 30일** 이벤트로 계산합니다.
- 가장 오래된 이력은 T−27.5일 무렵입니다. 그래서 T+2일쯤부터 새로 평가되는 사용자는 오래된 이력이 창 밖으로 빠집니다.
- 이미 저장된 점수와 Credit은 그대로입니다.
- 관리자 사용자 상세의 "현재 Feature"는 조회할 때마다 계산하므로 값이 줄어듭니다.

**공연 상태**도 T 기준입니다. 시간이 지나면 예매 진행 중 공연의 공연일이 다가오고, 예매 예정 공연의 오픈일이 지나갑니다.

**권장**: 발표 1~2일 전에 다시 생성합니다.

```powershell
.\Reset-Showcase.ps1     # 확인 문구로 'cdbts-showcase' 입력. Showcase 컨테이너·볼륨·시드 상태만 삭제(키는 유지)
.\Start-Showcase.ps1
.\Seed-Showcase.ps1      # 전체 규모 실측: 적재 약 20분(약 290건/s) + AI 평가 약 45분 + 대표 계정 약 4분 (PC 성능에 따라 다름)
.\Verify-Showcase.ps1
```

`Verify-Showcase.ps1`이 마지막에 "가장 오래된 이벤트가 30일 창에서 빠지는 시각"을 알려 줍니다.

**Showcase 전용 성능 인덱스**
- BTS의 결제수단 공유·IP 밀집도·최근 IP 시도 집계 쿼리는 `behavior_event`를 서비스 단위로 전부 훑습니다(`BehaviorEventRepository`).
- 이벤트 39만 건 규모에서는 사용자 1명 평가에 수 초가 걸려, 전체 평가가 하루 가까이 걸립니다.
- 그래서 Showcase BTS DB에만 인덱스 두 개를 추가했습니다. 인덱스는 조회 결과를 바꾸지 않습니다.

| 인덱스 | 대상 쿼리 | 효과 |
|---|---|---|
| `ix_showcase_event_type_time (service_id, event_type, occurred_at)` | 결제수단 공유·IP 밀집도 | 0.25초 → 0.007초 (이벤트 3만 건 기준) |
| `ix_showcase_type_time (event_type, occurred_at)` | 최근 10분 IP 시도 (`service_id`가 조인 조건이라 위 인덱스를 쓰지 못함) | 0.74초 → 0.004초 (이벤트 39만 건 기준) |
- admin 저장소의 `schema.sql`은 바꾸지 않았습니다. 운영에 적용할지는 BTS 팀이 판단할 사항입니다.

**MySQL 커밋 동기화 완화 (Showcase 전용)**
- Showcase의 두 MySQL은 `--innodb-flush-log-at-trx-commit=2 --sync-binlog=0`으로 실행합니다(`compose.yaml`).
- Docker Desktop 볼륨에서는 커밋마다 디스크 동기화를 기다리느라 이벤트 적재가 약 60건/s에 머뭅니다. 이 설정을 쓰면 약 260건/s로 올라갑니다.
- 정상 종료와 재시작에서는 데이터가 모두 남습니다. OS가 비정상 종료되면 마지막 약 1초 분량만 잃을 수 있습니다.
- BTS MySQL의 버퍼 풀을 1GB(`--innodb-buffer-pool-size=1G`)로 잡습니다. 기본값 128MB로는 `behavior_event`(약 430MB)가 들어가지 않아, 관리자 공연 통계가 매번 디스크를 읽습니다.
- MySQL 컨테이너에는 `stop_grace_period: 90s`를 줍니다. 기본 10초 안에 정상 종료하지 못하면 강제 종료되기 때문입니다.
- Docker Desktop에 메모리를 4GB 이상 할당하는 것을 권장합니다.

**관리자 공연 화면 응답 시간 (전체 규모 실측)**

공연 상세 API는 sc01 약 11초, sc08 약 22초가 걸립니다.

| 원인 | 설명 |
|---|---|
| 쿼리 | BTS의 공연별 집계 쿼리는 `hex(JSON_UNQUOTE(JSON_EXTRACT(metadata,'$.concertId')))`로 공연을 거릅니다. 이 형태는 인덱스로 줄일 수 없어, 요청마다 예매 시도 이벤트 약 38만 건을 읽습니다. |
| 해결 위치 | admin 저장소의 쿼리를 바꿔야 해결됩니다. 예: 공연 ID 컬럼 또는 생성 컬럼에 인덱스를 두는 방식. 이번 작업에서는 바꾸지 않았습니다. |

**시연 팁**: 발표 직전에 시연할 공연 상세 화면을 한 번씩 열어 두면 MySQL 캐시가 데워져 응답이 빨라집니다.

| API | 응답 시간 |
|---|---|
| 요약 | 1.6초 |
| 공연 목록 | 4.6초 |
| 참여자 목록 | 2~3초 |
| 추이 | 5~7초 |
| 사용자 화면 | 0.1초 |

## 10. 알려진 제한 사항

- **합성 이력과 실제 좌석 상태는 별개입니다.** BTS에만 있는 과거 이력은 Demo의 좌석·예매 테이블에 반영되지 않습니다. Demo 좌석 화면은 대표 계정이 실제로 예매한 좌석만 판매됨으로 보입니다.
- **Demo에는 예매 오픈 시각 개념이 없습니다.** "예매 예정"·"종료"는 이 환경의 일정상 구분입니다. 티켓팅 사이트에서는 sc09·sc10과 종료 공연도 예매 화면이 열립니다. 시연에서는 예매 진행 중 공연(sc06~sc08)을 사용하세요.
- **평가 시각이 모두 같습니다.** AI 평가 시각·Credit 변경 시각은 BTS가 `now()`로 기록합니다. 그래서 평가 이력과 Credit 이력은 Seed를 실행한 시각에 몰립니다. 관리자 공연 추이의 "이상 평가"도 평가 시각 기준이라 실행 시각에 몰립니다. 예매 시도 추이는 실제 발생 시각으로 분포합니다.
- **IP 집중도 감점(최근 10분 같은 IP 시도 5건 이상)은 과거 이력에는 나타나지 않습니다.** 이 감점은 평가 시각 직전 10분만 봅니다. 대표 계정의 실제 요청에서만 생길 수 있습니다.
- **대표 계정의 실제 요청은 새 행동 이벤트를 만듭니다.** 그래서 BTS가 그 계정을 다시 평가합니다(실제 동작). 선정할 때의 예상 정책과 이후 화면의 정책이 다를 수 있습니다.
- **브라우저 결제는 공용 결제 식별자를 씁니다.** 브라우저에서 직접 결제하면 프론트엔드가 공용 테스트 결제 식별자(`test-pay-shared-01~02`)를 씁니다. 그러면 해당 계정의 결제수단 공유 수가 늘어납니다.

## 11. 문제 해결

| 증상 | 확인 |
|---|---|
| `Start-Showcase.ps1`이 BTS·Demo 응답 대기 중 실패 | `.run\bts.log`, `.run\demo.log`(`.err`)를 확인. 포트 28080/28081/3327/3328/6391/8010을 다른 프로세스가 쓰는지 확인 |
| `ticket-fds-ai 경로가 올바르지 않거나…` | ai 저장소가 최신 dev인지 확인(`train_fds_model.py` 필요) |
| 평가 대기가 줄지 않음 | `.run\bts.log`에서 AI 호출 오류 확인, `http://127.0.0.1:8010/health` 확인. 성능 인덱스가 있는지 `Start-Showcase.ps1` 출력으로 확인 |
| `이미 seed …로 생성된 데이터가 있습니다` | 다른 seed로 바꾸려면 `Reset-Showcase.ps1` 후 다시 생성 |
| 관리자 화면 로그인 실패 | `secrets.json`의 `adminKey`를 쓰는지, BTS가 실행 중인지 확인 |
| 한글이 깨짐 | 스크립트는 UTF-8(BOM)입니다. 편집기에서 다른 인코딩으로 저장하지 마세요. |
| 적재·평가가 중간에 멈춤 | PC가 절전 모드에 들어가면 멈춥니다. 대량 적재 중에는 절전을 끄세요. 다시 실행하면 이미 적재한 사용자는 건너뛰고 이어서 진행합니다. |
| 관리자 공연 상세가 느림 | 위의 "관리자 공연 화면 응답 시간" 참고. 처음 한 번 연 뒤에는 빨라집니다. |
