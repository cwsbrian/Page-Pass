CREATE TABLE parent_accounts (
  id uuid PRIMARY KEY,
  issuer text NOT NULL,
  subject text NOT NULL,
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
  identity_email text,
  created_at timestamptz NOT NULL,
  UNIQUE (issuer, subject)
);

INSERT INTO parent_accounts (
  id,
  issuer,
  subject,
  display_name,
  created_at
) VALUES (
  '00000000-0000-4000-8000-000000000001',
  'pagepass:local',
  'default',
  'Local Parent',
  now()
);

ALTER TABLE children ADD COLUMN owner_parent_id uuid;

UPDATE children
SET owner_parent_id = '00000000-0000-4000-8000-000000000001';

ALTER TABLE children
  ALTER COLUMN owner_parent_id SET NOT NULL,
  ADD CONSTRAINT children_owner_parent_id_fkey
    FOREIGN KEY (owner_parent_id) REFERENCES parent_accounts(id);

CREATE INDEX children_owner_parent_id_idx ON children (owner_parent_id);

CREATE TABLE apple_auth_challenges (
  id uuid PRIMARY KEY,
  state_digest bytea NOT NULL UNIQUE CHECK (octet_length(state_digest) = 32),
  nonce_digest bytea NOT NULL CHECK (octet_length(nonce_digest) = 32),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL
);

CREATE INDEX apple_auth_challenges_expiry_idx
  ON apple_auth_challenges (expires_at);

CREATE TABLE parent_sessions (
  id uuid PRIMARY KEY,
  parent_id uuid NOT NULL REFERENCES parent_accounts(id),
  token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest) = 32),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL
);

CREATE INDEX parent_sessions_authentication_idx
  ON parent_sessions (token_digest, expires_at)
  WHERE revoked_at IS NULL;
