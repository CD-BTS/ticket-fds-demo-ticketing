-- MySQL 8.0. Apply once to an existing Demo database (#44), after 02 and 04 have been applied.
-- New volumes created by compose already have DATETIME(3); do not apply there.
-- Widens event occurrence times from seconds to milliseconds so sub-second booking attempt
-- intervals reach BTS. Existing rows keep their values with .000. Frozen outbox payloads are not rewritten.
-- Deploy the BTS (ticket-fds-admin #40) change that accepts millisecond occurredAt before enabling delivery.
USE demo_ticketing_db;

ALTER TABLE outbox_events MODIFY occurred_at_utc DATETIME(3) NOT NULL;
ALTER TABLE booking_attempt_events MODIFY occurred_at DATETIME(3) NOT NULL;
