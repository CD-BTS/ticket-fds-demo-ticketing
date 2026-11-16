-- MySQL 8.0.16+. Apply once to the Demo database; not safe to rerun.
-- Additive only: admission_tickets/bookings/outbox_events are not altered.
USE demo_ticketing_db;

-- 티켓별 기기 바인딩 이력. ACTIVE는 티켓당 최대 1개(active_ticket_id UNIQUE)다.
-- REVOKED 행은 암호화된 TOTP 비밀키를 보관하지 않는다.
CREATE TABLE ticket_device_bindings (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  public_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'deviceId carried in the QR',
  ticket_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  status VARCHAR(20) NOT NULL,
  generation INT NOT NULL COMMENT '1 = first registration; +1 per device change',
  public_key VARBINARY(128) NOT NULL COMMENT 'ECDSA P-256 SubjectPublicKeyInfo DER',
  totp_secret_enc VARBINARY(64) NULL COMMENT 'AES-256-GCM: IV(12) || ciphertext || tag(16)',
  created_at DATETIME(6) NOT NULL,
  revoked_at DATETIME(6) NULL,
  active_ticket_id BIGINT AS (CASE WHEN status = 'ACTIVE' THEN ticket_id END) STORED,
  CONSTRAINT uq_device_public UNIQUE (public_id),
  CONSTRAINT uq_device_active UNIQUE (active_ticket_id),
  CONSTRAINT uq_device_generation UNIQUE (ticket_id, generation),
  CONSTRAINT fk_device_ticket FOREIGN KEY (ticket_id) REFERENCES admission_tickets(id),
  CONSTRAINT fk_device_user FOREIGN KEY (user_id) REFERENCES demo_users(id),
  CONSTRAINT ck_device_generation CHECK (generation >= 1),
  CONSTRAINT ck_device_status CHECK (
    (status = 'ACTIVE' AND totp_secret_enc IS NOT NULL AND revoked_at IS NULL) OR
    (status = 'REVOKED' AND totp_secret_enc IS NULL AND revoked_at IS NOT NULL))
) ENGINE=InnoDB;

-- 기기 등록·변경용 일회성 챌린지. 사용 시 행을 삭제한다. 티켓·사용자당 미사용 챌린지는 1개만 유지한다.
CREATE TABLE ticket_device_challenges (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  public_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  ticket_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  challenge CHAR(43) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'Random nonce, not a secret',
  expires_at DATETIME(6) NOT NULL,
  CONSTRAINT uq_device_challenge_public UNIQUE (public_id),
  CONSTRAINT uq_device_challenge_owner UNIQUE (ticket_id, user_id),
  CONSTRAINT fk_device_challenge_ticket FOREIGN KEY (ticket_id) REFERENCES admission_tickets(id),
  CONSTRAINT fk_device_challenge_user FOREIGN KEY (user_id) REFERENCES demo_users(id)
) ENGINE=InnoDB;
