CREATE TABLE IF NOT EXISTS tracked_card_payments (
  transaction_id TEXT PRIMARY KEY, source_account_id TEXT NOT NULL, card_account_id TEXT NOT NULL,
  amount REAL NOT NULL CHECK(amount > 0), currency TEXT NOT NULL, payment_date TEXT NOT NULL,
  matched_transaction_id TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS tracked_card_payment_match ON tracked_card_payments(matched_transaction_id)
  WHERE matched_transaction_id IS NOT NULL;
