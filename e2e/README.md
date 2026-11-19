# Demo–BTS 실서버 통합 시나리오 (#47)

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

`restrict` 시나리오는 실제 AI 점수 대신 BTS DB에 직접 위험도를 넣습니다(`credit_score=10`, `anomaly_score=0.93`). ticket-fds-admin#40의 AI 추론 연동이 끝나면 이 부분을 실제 점수로 바꿔야 합니다.

결과와 발견 사항: [docs/e2e-result-2026-11-19.md](../docs/e2e-result-2026-11-19.md)
