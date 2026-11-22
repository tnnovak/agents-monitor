# agents-monitor — auto-post Codex JSONL

Server: `https://agents-monitor.fly.dev`
Endpoints: `POST /api/ingest` and `POST /ingest`, `GET /api/logs?limit=200&since=-1&session_id=xxx`

Auth:
- `X-Ingest-Token: <INGEST_TOKEN>` (preferred for agents), or
- `Authorization: Bearer <MONITOR_PASSWORD>`, or `?token=<INGEST_TOKEN>`

Get tokens from the machine (values are not shown by `fly secrets list`):

```bash
cd ~/agents-monitor
fly ssh console --command "sh -c 'printenv INGEST_TOKEN'"
fly ssh console --command "sh -c 'printenv MONITOR_PASSWORD'"
```

Server behavior (v7+):
- Ignores client `ordinal` collisions. Assigns server-side `ordinal = max+1`.
- Preserves client value as `client_ordinal`, adds `timestamp` if missing, `ingested_at`, and `session_id` (extracted from `payload.session_id`).
- `GET /api/logs?since=-1` returns everything. `since=<cursor>` returns only newer. `session_id=` / `host=` filter.
- `host` labels new posts: `wsl-<hostname>` from `codex-tail.sh` (`$HOST_LABEL` to override), `win-<COMPUTERNAME>` from `Codex-Tail.ps1` (`-HostLabel` / `$env:HOST_LABEL`). Page shows `[host]` with purple left-border for wsl, green for win, plus an `all hosts` dropdown.

Set once per shell (required — empty vars silently post nowhere):

```bash
export MONITOR_URL=https://agents-monitor.fly.dev
export INGEST_TOKEN=$(fly ssh console --command "sh -c 'printenv INGEST_TOKEN'" 2>/dev/null | tail -n 1)
export MONITOR_PASSWORD=$(fly ssh console --command "sh -c 'printenv MONITOR_PASSWORD'" 2>/dev/null | tail -n 1)
echo "TOKEN_LEN:${#INGEST_TOKEN} URL:$MONITOR_URL"
```

## Method 1 — non-interactive agents (`codex exec --json`)

Best for launched agents. `codex exec --json` prints Codex-native JSONL
`{"timestamp","ordinal","type","payload"}` — exactly what the server stores
(same shape as `~/.codex/sessions/2026/.../rollout-*.jsonl`).

```bash
codex exec --json "do task" 2>&1 | tee /tmp/codex.jsonl | while IFS= read -r line; do
  [ -n "$line" ] && curl -s -X POST "$MONITOR_URL/api/ingest" \
    -H "Content-Type: application/json" \
    -H "X-Ingest-Token: $INGEST_TOKEN" -d "$line" > /dev/null
done
```

Verify:

```bash
curl -s "$MONITOR_URL/api/logs?limit=5&since=-1" -H "Authorization: Bearer $MONITOR_PASSWORD" | python3 -m json.tool | head -n 40
```

## Method 2 — interactive / VSCode sessions (polling tailer)

`tail -F ~/.codex/sessions/2026/*/*/*.jsonl` does NOT work alone: the glob
expands once at start, so files created after you start it are never watched.
Use `codex-tail.sh` (polls with `find` every 2s, picks up new files, skips old history):

```bash
# kill the old broken tail first
kill $(cat /tmp/codex-tail.pid 2>/dev/null) 2>/dev/null; pkill -f "tail -n0 -F" 2>/dev/null; pkill -f codex-tail.sh 2>/dev/null

~/agents-monitor/codex-tail.sh &
echo $! > /tmp/codex-tail.pid
```

What it does (`codex-tail.sh`):
- resolves `INGEST_TOKEN` if unset, exits if still empty
- baselines all existing `rollout-*.jsonl` line counts (won't resend history)
- every 2s: `find ~/.codex/sessions -name "rollout-*.jsonl"`, posts only appended `{...}` lines

Force one line through to prove the pipe:

```bash
echo '{"type":"event_msg","payload":{"text":"manual tail test"}}' | curl -s -X POST "$MONITOR_URL/api/ingest" -H "Content-Type: application/json" -H "X-Ingest-Token: $INGEST_TOKEN" -d @-
```

Filter one agent in the UI/API:

```text
/api/logs?limit=200&since=-1&session_id=sess-A-test
```

## Method 3 — server page sends back to a session (reverse channel)

The page has a floating ✎ button (bottom-right) opening a bottom popup:
prompt text + optional `session_id` + send. It `POST`s to
`/api/queue/send` (browser cookie auth) and the message also appears in the
stream as `queue_msg`.

Poll a queue message (oldest-first, pop semantics):

```bash
curl -s "$MONITOR_URL/get" -H "X-Ingest-Token: $INGEST_TOKEN"
curl -s "$MONITOR_URL/get?session_id=<uuid>" -H "X-Ingest-Token: $INGEST_TOKEN"
curl -s "$MONITOR_URL/api/queue/depth" -H "X-Ingest-Token: $INGEST_TOKEN"
```

`queue-poll.sh` polls `/get` and delivers via `codex queue`:

```bash
TARGET_THREAD=<session-uuid> ~/agents-monitor/queue-poll.sh &
echo $! > /tmp/queue-poll.pid
# DRY_RUN=1 TARGET_THREAD=<uuid> ~/agents-monitor/queue-poll.sh --once  # test without delivering
```

Messages with empty `session_id` are broadcast: any filtered poller picks
them up. Messages with a `session_id` are only picked up by an unfiltered
poller or one polling with that same `session_id`.

## Both directions at once

```bash
~/agents-monitor/start-channels.sh   # starts codex-tail.sh + queue-poll.sh
kill $(cat /tmp/codex-tail.pid) $(cat /tmp/queue-poll.pid)  # stop
```

Tail follows all sessions automatically; the poller auto-attaches the
latest session unless `TARGET_THREAD=<uuid>` is set. Token is fetched via
`fly ssh console -a agents-monitor` if `INGEST_TOKEN` is unset.
