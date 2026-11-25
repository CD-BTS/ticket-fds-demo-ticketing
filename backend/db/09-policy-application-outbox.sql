-- #67: 실제 정책 적용 기록(POLICY_APPLICATION)을 Outbox로 보낼 수 있게 event_type CHECK를 넓힌다.
-- MySQL 8.0.16+. 02·04가 적용된 Demo DB에 한 번만 적용한다(반복 실행용이 아니다). 기존 행과 컬럼은 바꾸지 않는다.
-- 적용 전에는 정책 적용 기록 적재가 CHECK에 걸려 실패하고 경고 로그만 남는다. 대기열·CAPTCHA·예매 동작에는 영향이 없다.
USE demo_ticketing_db;

-- CHECK replacement acquires a metadata lock. DDL statements commit independently.
ALTER TABLE outbox_events DROP CHECK ck_outbox_type;
ALTER TABLE outbox_events ADD CONSTRAINT ck_outbox_type
  CHECK (event_type IN ('BOOKING','CANCEL','CHECK_IN','BOOKING_ATTEMPT','POLICY_APPLICATION'));
