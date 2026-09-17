-- relay-lite schema. One table. Applied by install.sh; safe to re-run.
CREATE TABLE IF NOT EXISTS commands (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  command    TEXT    NOT NULL,
  status     TEXT    NOT NULL,          -- pending | running | done | error | rejected | timeout
  output     TEXT,
  exit_code  INTEGER,
  sig        TEXT    NOT NULL,          -- HMAC-SHA256 hex over nonce "\n" command
  nonce      TEXT    NOT NULL UNIQUE,
  created_at TEXT    NOT NULL,
  updated_at TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_commands_pending ON commands (id) WHERE status = 'pending';
