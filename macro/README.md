# 예매 매크로 (부정 사용자 데이터 생성)

우리 데모 사이트에서 **매크로로 예매하는 부정 사용자**의 행동 데이터를 만들기 위한 Playwright 스크립트입니다.
브라우저를 실제로 조작하므로 프론트의 행동 수집(체류 시간, 좌석 선택 시간, 요청 간격 등)이 사람이 쓸 때와 같은 경로로 동작합니다.

> 우리가 운영하는 데모 사이트(로컬 또는 팀 테스트 서버)에서만 사용합니다. 다른 사이트에는 사용하지 않습니다.

## 준비 (처음 한 번)

```
cd macro
npm install
npx playwright install chromium
```

사이트(백엔드 + 프론트)를 먼저 실행해 둡니다.

## 실행

```
node macro.js --user macro01 --mode fast
node macro.js --user macro01 --mode jitter --runs 10 --seats 2
node macro.js --user macro01 --mode human --runs 5 --headless
```

| 옵션 | 설명 | 기본값 |
|---|---|---|
| `--mode` | `fast`(대기 없이 빠르게) / `jitter`(무작위 지연) / `human`(사람처럼 느리게) | `fast` |
| `--user` | 계정 ID. `--runs`가 2 이상이면 끝 숫자를 1씩 늘려 사용(`macro01`, `macro02`, …) | `macro01` |
| `--runs` | 반복 횟수 | `1` |
| `--seats` | 좌석 수 (1~4) | `2` |
| `--concert` | 공연 순서(0부터) 또는 공연 ID | `0` |
| `--pay` | `direct`(카드번호 직접 입력) / `saved`(저장된 카드) | `direct` |
| `--card` | 직접 입력할 가상 카드번호(숫자 15자리) | `123456789012345` |
| `--base` | 사이트 주소 | `http://localhost:5173` |
| `--headless` | 브라우저 창 없이 실행 | 꺼짐 |
| `--debug` | 단계·브라우저 오류를 화면에 출력 | 꺼짐 |
| `--timeout` | 한 번의 예매에 허용하는 최대 시간(초) | `60` |
| `--out` | 결과 CSV 파일 이름 | `macro-results.csv` |
| `--cancel` | 예매 직후 마이페이지에서 취소해 좌석을 되돌림 | 꺼짐 |
| `--cancel-all` | 예매 없이 계정들의 확정 예매를 모두 취소(좌석 되돌리기) | 꺼짐 |

실행할 때마다 새 브라우저 상태로 시작하고, 결과는 CSV에 한 줄씩 쌓입니다.
컬럼: `time, user, mode, seats, result, error, ms_login, ms_to_seatmap, ms_first_seat, ms_hold, ms_paid, ms_total, ms_booking`
(CSV는 저장소에 올리지 않습니다.)

## 속도 3단계

- **fast**: 대기 없이 최대한 빠르게 (단순 매크로)
- **jitter**: 클릭·입력 사이에 무작위 지연 (지연을 섞은 매크로)
- **human**: 사람 범위에 가깝게 느리게 (경계 사례)

## 주의

- **보안 확인(CAPTCHA)**: 산술 문제(`CAPTCHA_MODE=mock`)는 매크로가 풉니다. hCaptcha 위젯은 풀 수 없어 `CAPTCHA_BLOCKED`로 기록하고 멈춥니다.
  데이터를 만들 때는 `CAPTCHA_MODE`를 `disabled` 또는 `mock`으로, 계정은 정책 계정(`susp01` 등)이 아닌 새 ID로 사용하세요.
- **좌석**: 예매할 때마다 실제 좌석이 선점·결제되어 줄어듭니다. 공연마다 96석입니다. 부족하면 `--concert`로 공연을 바꾸거나 `--cancel`/`--cancel-all`로 좌석을 되돌립니다.
  취소하면 `CANCEL` 이벤트가 데이터에 남으므로, 예매 행동만 보고 싶다면 수집이 끝난 뒤에 취소하세요.
- **예매 시도 기록**: 단계별 기록(`booking_attempts`)은 백엔드의 `BOOKING_ATTEMPTS_ENABLED=true`와 `db/04-booking-attempts.sql` 적용이 필요합니다.
- **대기열**: 서버 대기열 때문에 좌석 화면까지 걸리는 시간(`ms_to_seatmap`)에 대기 시간이 포함됩니다. 매크로 속도는 `ms_hold - ms_to_seatmap`(좌석 선택~선점 구간)로 보세요.
- 계정 ID는 `macro` 접두사로 구분해 두면 나중에 데이터를 나누기 쉽습니다.
