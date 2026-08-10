ALTER TABLE "push_outbox_events"
    DROP CONSTRAINT "push_outbox_events_state_check";

ALTER TABLE "push_outbox_events"
    ADD CONSTRAINT "push_outbox_events_state_check"
    CHECK ("state" IN ('pending', 'processing', 'sent', 'failed'));
