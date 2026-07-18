CREATE TABLE server_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  server_instance_id uuid NOT NULL,
  parent_token_hash bytea NOT NULL CHECK (octet_length(parent_token_hash) = 32),
  ledger_revision bigint NOT NULL DEFAULT 0 CHECK (ledger_revision >= 0)
);

CREATE TABLE children (
  id uuid PRIMARY KEY,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100)
);

CREATE TABLE pairing_sessions (
  id uuid PRIMARY KEY,
  child_profile_id uuid NOT NULL REFERENCES children(id),
  qr_token_hash bytea NOT NULL UNIQUE CHECK (octet_length(qr_token_hash) = 32),
  numeric_code_hash bytea NOT NULL UNIQUE CHECK (octet_length(numeric_code_hash) = 32),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz
);

CREATE TABLE active_devices (
  child_profile_id uuid PRIMARY KEY REFERENCES children(id),
  installation_id text NOT NULL UNIQUE,
  device_name text NOT NULL CHECK (length(device_name) BETWEEN 1 AND 100),
  credential_hash bytea NOT NULL UNIQUE CHECK (octet_length(credential_hash) = 32)
);

CREATE TABLE credit_grants (
  id uuid PRIMARY KEY,
  child_profile_id uuid NOT NULL REFERENCES children(id),
  seconds integer NOT NULL CHECK (seconds > 0),
  reason text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  fingerprint text NOT NULL,
  created_at timestamptz NOT NULL,
  balance_seconds bigint NOT NULL CHECK (balance_seconds >= 0)
);

CREATE TABLE earned_time_spends (
  id uuid PRIMARY KEY,
  child_profile_id uuid NOT NULL REFERENCES children(id),
  installation_id text NOT NULL,
  local_session_id text NOT NULL,
  consumed_seconds integer NOT NULL CHECK (consumed_seconds >= 0),
  balance_seconds bigint NOT NULL CHECK (balance_seconds >= 0),
  settled_at timestamptz NOT NULL,
  idempotency_key text NOT NULL,
  fingerprint text NOT NULL,
  UNIQUE (child_profile_id, idempotency_key),
  UNIQUE (child_profile_id, local_session_id)
);

CREATE TABLE pairing_rate_attempts (
  dimension text NOT NULL CHECK (dimension IN ('installation', 'address')),
  key_hash bytea NOT NULL CHECK (octet_length(key_hash) = 32),
  attempted_at timestamptz NOT NULL
);

CREATE INDEX pairing_rate_attempts_lookup_idx
  ON pairing_rate_attempts (dimension, key_hash, attempted_at);

CREATE FUNCTION reject_ledger_row_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'ledger rows are immutable';
END;
$$;

CREATE TRIGGER credit_grants_are_immutable
BEFORE UPDATE OR DELETE ON credit_grants
FOR EACH ROW EXECUTE FUNCTION reject_ledger_row_mutation();

CREATE TRIGGER earned_time_spends_are_immutable
BEFORE UPDATE OR DELETE ON earned_time_spends
FOR EACH ROW EXECUTE FUNCTION reject_ledger_row_mutation();
