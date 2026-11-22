-- MySQL 8.0.16+. Apply once to the Demo database after 05-ticket-device-binding.sql; not safe to rerun.
-- Additive only: existing tables and constraints are not altered.
USE demo_ticketing_db;

-- 검표 시 등록 기기의 개인키 소유를 실시간으로 확인하는 일회성 챌린지.
-- 검표기가 QR을 스캔하면 PENDING 행이 생기고, 등록 기기의 서명이 검증되면 COMPLETED가 된다.
-- 티켓당 PENDING은 최대 1개(pending_ticket_id UNIQUE)이며 새 스캔은 이전 PENDING을 SUPERSEDED로 바꾼다.
-- 만료는 행을 바꾸지 않고 expires_at으로 판단한다. 검표기가 결과를 조회하므로 사용 후에도 행을 남긴다.
CREATE TABLE ticket_checkin_challenges (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  public_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'checkInId',
  ticket_id BIGINT NOT NULL,
  binding_id BIGINT NOT NULL COMMENT 'Device binding whose QR was scanned; must still be active at confirmation',
  challenge CHAR(43) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'Random nonce, not a secret',
  status VARCHAR(20) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  expires_at DATETIME(6) NOT NULL,
  resolved_at DATETIME(6) NULL,
  pending_ticket_id BIGINT AS (CASE WHEN status = 'PENDING' THEN ticket_id END) STORED,
  CONSTRAINT uq_checkin_challenge_public UNIQUE (public_id),
  CONSTRAINT uq_checkin_challenge_pending UNIQUE (pending_ticket_id),
  CONSTRAINT fk_checkin_challenge_ticket FOREIGN KEY (ticket_id) REFERENCES admission_tickets(id),
  CONSTRAINT fk_checkin_challenge_binding FOREIGN KEY (binding_id) REFERENCES ticket_device_bindings(id),
  CONSTRAINT ck_checkin_challenge_status CHECK (
    (status = 'PENDING' AND resolved_at IS NULL) OR
    (status IN ('COMPLETED','REJECTED','SUPERSEDED') AND resolved_at IS NOT NULL))
) ENGINE=InnoDB;
