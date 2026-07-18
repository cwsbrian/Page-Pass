ALTER TABLE server_state
  ADD COLUMN local_data_claimed_parent_id uuid
    REFERENCES parent_accounts(id),
  ADD COLUMN local_data_claimed_children integer
    CHECK (local_data_claimed_children IS NULL OR local_data_claimed_children >= 0),
  ADD CONSTRAINT server_state_local_data_claim_check CHECK (
    (local_data_claimed_parent_id IS NULL) =
    (local_data_claimed_children IS NULL)
  );
