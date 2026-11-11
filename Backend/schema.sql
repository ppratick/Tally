CREATE TABLE IF NOT EXISTS snapshots (
  id TEXT PRIMARY KEY,
  data TEXT NOT NULL DEFAULT '{}',
  lease TEXT,
  lease_until INTEGER NOT NULL DEFAULT 0
);

-- Credentials are encrypted with a Worker secret; disconnecting retains the financial snapshots.
CREATE TABLE IF NOT EXISTS connections (
  item_id TEXT PRIMARY KEY,
  institution_id TEXT NOT NULL,
  token_encrypted TEXT,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  disconnected_at TEXT
);
CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS balance_history (
  account_id TEXT NOT NULL,
  day TEXT NOT NULL,
  bank_id TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  current REAL,
  available REAL,
  pending REAL NOT NULL,
  currency TEXT NOT NULL,
  PRIMARY KEY (account_id, day)
);
CREATE TABLE IF NOT EXISTS link_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  payload_encrypted TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  message TEXT,
  lease_until INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS processed_public_tokens (
  hash TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  processed_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS transactions (
  id TEXT PRIMARY KEY,
  bank_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS transactions_bank ON transactions(bank_id);

CREATE TABLE IF NOT EXISTS bank_insights (bank_id TEXT PRIMARY KEY, data TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS relink_jobs (session_id TEXT PRIMARY KEY, old_bank_id TEXT NOT NULL, new_bank_id TEXT, status TEXT NOT NULL DEFAULT 'pending');
CREATE TABLE IF NOT EXISTS account_mappings (bank_id TEXT NOT NULL, source_id TEXT NOT NULL, canonical_id TEXT NOT NULL, PRIMARY KEY(bank_id,source_id));

CREATE TABLE IF NOT EXISTS chat_sessions (
  id TEXT PRIMARY KEY,
  data TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL,
  lease TEXT,
  lease_until INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS chat_sessions_updated ON chat_sessions(updated_at);

-- Usage metadata only: no prompts, financial data, API keys, or response text.
-- Independent of chat_sessions so clearing/expiring a chat preserves usage totals.
CREATE TABLE IF NOT EXISTS ai_usage (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  call_number INTEGER NOT NULL,
  model TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  status TEXT NOT NULL DEFAULT 'started' CHECK(status IN ('started','completed','failed')),
  http_status INTEGER,
  input_tokens INTEGER,
  output_tokens INTEGER
);
CREATE INDEX IF NOT EXISTS ai_usage_started ON ai_usage(started_at);
CREATE INDEX IF NOT EXISTS ai_usage_request ON ai_usage(conversation_id,request_id);

CREATE TABLE IF NOT EXISTS sync_jobs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, subject TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1, attempts INTEGER NOT NULL DEFAULT 0,
  live_balance INTEGER NOT NULL DEFAULT 0, force_insights INTEGER NOT NULL DEFAULT 0,
  due_at INTEGER NOT NULL, lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'pending', last_error TEXT
);
CREATE INDEX IF NOT EXISTS sync_jobs_due ON sync_jobs(state,due_at,lease_until);
