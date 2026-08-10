CREATE FUNCTION reject_submission_review_mutation()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'submission_reviews is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER "submission_reviews_append_only_update"
BEFORE UPDATE ON "submission_reviews"
FOR EACH ROW EXECUTE FUNCTION reject_submission_review_mutation();

CREATE TRIGGER "submission_reviews_append_only_delete"
BEFORE DELETE ON "submission_reviews"
FOR EACH ROW EXECUTE FUNCTION reject_submission_review_mutation();
