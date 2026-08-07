#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

projects="$TEST_HOME/.claude/projects/example"
mkdir -p "$projects"

timestamp="$(date +%Y-%m-%d)T12:00:00Z"
cat >"$projects/session.jsonl" <<EOF
{"timestamp":"$timestamp","type":"assistant","sessionId":"session-1","uuid":"event-1","message":{"id":"message-1","role":"assistant","model":"claude-test","usage":{"input_tokens":2,"cache_creation_input_tokens":28857,"cache_read_input_tokens":0,"output_tokens":231}}}
{"timestamp":"$timestamp","type":"assistant","sessionId":"session-1","uuid":"event-2","message":{"id":"message-1","role":"assistant","model":"claude-test","usage":{"input_tokens":2,"cache_creation_input_tokens":28857,"cache_read_input_tokens":0,"output_tokens":231}}}
{"timestamp":"$timestamp","type":"assistant","sessionId":"session-1","uuid":"event-3","message":{"id":"message-2","role":"assistant","model":"claude-test","usage":{"input_tokens":2,"cache_creation_input_tokens":454,"cache_read_input_tokens":28857,"output_tokens":390}}}
EOF

result=$(HOME="$TEST_HOME" XDG_CACHE_HOME="$TEST_HOME/.cache" XDG_DATA_HOME="$TEST_HOME/.local/share" \
  "$ROOT/bin/omarchy-agent-usage-claude" --force)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "58793" ]] ||
  fail "Claude collector counts each API message once" "$result"
pass "Claude collector counts each API message once"

[[ $(jq -c '.modelUsage["claude-test"]' <<<"$result") == '{"cacheCreationInputTokens":29311,"cacheReadInputTokens":28857,"inputTokens":4,"outputTokens":621}' ]] ||
  fail "Claude collector keeps mutually exclusive token categories" "$result"
pass "Claude collector keeps mutually exclusive token categories"

[[ $(jq -r '.id + "/" + .usageStatusText' <<<"$result") == "claude/Waiting for auth" ]] ||
  fail "Claude collector identifies itself and reports missing auth" "$result"
pass "Claude collector identifies itself and reports missing auth"

# A machine with no transcripts and no stats-cache still gets today's counts
# from history.jsonl alone.
HISTORY_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$HISTORY_HOME"' EXIT
mkdir -p "$HISTORY_HOME/.claude"

now_ms=$(($(date +%s) * 1000))
cat >"$HISTORY_HOME/.claude/history.jsonl" <<EOF
{"timestamp":86400000,"sessionId":"old","display":"ancient"}
{"timestamp":$now_ms,"sessionId":"s1","display":"one"}
{"timestamp":$now_ms,"sessionId":"s2","display":"two"}
EOF

result=$(HOME="$HISTORY_HOME" XDG_CACHE_HOME="$HISTORY_HOME/.cache" XDG_DATA_HOME="$HISTORY_HOME/.local/share" \
  "$ROOT/bin/omarchy-agent-usage-claude" --force)

[[ $(jq -r '(.todayPrompts|tostring) + "/" + (.todaySessions|tostring)' <<<"$result") == "2/2" ]] ||
  fail "Claude collector falls back to history.jsonl without a stats-cache" "$result"
pass "Claude collector falls back to history.jsonl without a stats-cache"

# A subscription burned entirely through opencode has no ~/.claude transcripts;
# usage must come from opencode's message database, filtered to Anthropic.
OPENCODE_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$HISTORY_HOME" "$OPENCODE_HOME"' EXIT

python3 - "$OPENCODE_HOME/.local/share/opencode/opencode.db" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

db = Path(sys.argv[1])
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
now_ms = int(time.time() * 1000)

def message(id, provider, model, role="assistant", input=0, output=0, read=0, write=0):
  return (id, "ses_1", now_ms, now_ms, json.dumps({
    "role": role,
    "providerID": provider,
    "modelID": model,
    "tokens": {"input": input, "output": output, "reasoning": 0, "cache": {"read": read, "write": write}},
    "time": {"created": now_ms},
  }))

conn.executemany("INSERT INTO message VALUES (?, ?, ?, ?, ?)", [
  message("msg_1", "anthropic", "claude-opus-5", input=100, output=50, read=25, write=10),
  message("msg_2", "fireworks-ai", "accounts/fireworks/models/kimi-k3", input=999, output=999),
  message("msg_3", "openai", "gpt-5.2-codex", input=999, output=999),
  message("msg_4", "anthropic", "claude-opus-5", role="user"),
])
conn.commit()
conn.close()
PY

result=$(HOME="$OPENCODE_HOME" XDG_CACHE_HOME="$OPENCODE_HOME/.cache" XDG_DATA_HOME="$OPENCODE_HOME/.local/share" \
  "$ROOT/bin/omarchy-agent-usage-claude" --force)

[[ $(jq -r '(.ready|tostring) + "/" + (.todayTotalTokens|tostring)' <<<"$result") == "true/185" ]] ||
  fail "Claude collector counts Anthropic usage from opencode sessions" "$result"
pass "Claude collector counts Anthropic usage from opencode sessions"

[[ $(jq -c '.modelUsage' <<<"$result") == '{"claude-opus-5":{"cacheCreationInputTokens":10,"cacheReadInputTokens":25,"inputTokens":100,"outputTokens":50}}' ]] ||
  fail "Claude collector ignores other opencode providers and user messages" "$result"
pass "Claude collector ignores other opencode providers and user messages"
