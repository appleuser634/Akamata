-- Mobus D1 schema. Run once via:
--   wrangler d1 execute mobus --file=deploy/mobus/worker/d1_schema.sql --remote

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    login_id TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    short_id TEXT NOT NULL UNIQUE,
    friend_code TEXT NOT NULL UNIQUE,
    friend_code_updated_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS friends (
    id TEXT PRIMARY KEY,
    requester_id TEXT NOT NULL,
    receiver_id TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(requester_id, receiver_id)
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    sender_id TEXT NOT NULL,
    receiver_id TEXT NOT NULL,
    content TEXT NOT NULL,
    is_read INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS user_devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_type TEXT NOT NULL,
    device_token TEXT NOT NULL,
    mqtt_client_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(user_id, device_token)
);
CREATE TABLE IF NOT EXISTS call_logs (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    caller_id TEXT NOT NULL,
    receiver_id TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    accepted_at INTEGER,
    ended_at INTEGER
);
CREATE TABLE IF NOT EXISTS envelopes (
    id TEXT PRIMARY KEY,
    sender_id TEXT NOT NULL,
    receiver_id TEXT NOT NULL,
    receiver_device_id TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    one_time_prekey_id TEXT,
    sender_ephemeral_pub TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS device_one_time_prekeys (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    public_key TEXT NOT NULL,
    used_at INTEGER,
    created_at INTEGER NOT NULL,
    UNIQUE(device_id, public_key)
);
CREATE INDEX IF NOT EXISTS idx_users_login_id ON users(login_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_receiver ON messages(receiver_id);
CREATE INDEX IF NOT EXISTS idx_friends_status ON friends(status);
CREATE INDEX IF NOT EXISTS idx_calls_session ON call_logs(session_id);
