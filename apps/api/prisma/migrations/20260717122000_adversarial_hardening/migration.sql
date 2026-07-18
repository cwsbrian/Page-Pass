ALTER TABLE server_state
  ADD COLUMN pepper_check bytea
    CHECK (pepper_check IS NULL OR octet_length(pepper_check) = 32);

ALTER TABLE pairing_rate_attempts
  DROP CONSTRAINT pairing_rate_attempts_dimension_check;

ALTER TABLE pairing_rate_attempts
  ADD CONSTRAINT pairing_rate_attempts_dimension_check
  CHECK (dimension IN ('installation', 'address', 'apple_address'));
