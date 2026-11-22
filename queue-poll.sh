#!/bin/bash
# Poll agents-monitor message queue and deliver to a Codex CLI session.
#   TARGET_THREAD=<session-uuid> ./queue-poll.sh [--once]
#   DRY_RUN=1 ./queue-poll.sh --once   # fetch + print, still calls codex? no: prints only
# Requires: codex CLI, MONITOR_URL, INGEST_TOKEN (or fly CLI to fetch it).
export MONITOR_URL="${MONITOR_URL:-https://agents-monitor.fly.dev}"
if [ -z "$INGEST_TOKEN" ]; then
  INGEST_TOKEN=$(fly ssh console -a agents-monitor --command "sh -c 'printenv INGEST_TOKEN'" 2>/dev/null | tail -n 1 | tr -d '\r\n ')
  export INGEST_TOKEN
fi
if [ -z "$INGEST_TOKEN" ]; then echo "INGEST_TOKEN empty" >&2; exit 1; fi
if [ -z "${TARGET_THREAD:-}" ]; then
  TARGET_THREAD=$(ls -t ~/.codex/sessions/2026/*/*/*.jsonl 2>/dev/null | head -n 1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -n 1)
  export TARGET_THREAD
  echo "TARGET_THREAD auto-detected: ${TARGET_THREAD:-<none>}"
fi
if [ -z "${TARGET_THREAD:-}" ]; then echo "no Codex session found and TARGET_THREAD unset" >&2; exit 1; fi
ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1
POLL_SECONDS="${POLL_SECONDS:-2}"
echo "polling $MONITOR_URL/get as target=${TARGET_THREAD:-<any>} (token len ${#INGEST_TOKEN})"
while true; do
  url="$MONITOR_URL/get"
  if [ -n "${TARGET_THREAD:-}" ]; then url="$url?session_id=$TARGET_THREAD"; fi
  resp=$(curl -s -m 10 -H "X-Ingest-Token: $INGEST_TOKEN" "$url" 2>/dev/null)
  parsed=$(python3 -c '
import json,sys
try:
  d = json.loads(sys.stdin.read())
except Exception:
  print("BADJSON"); sys.exit(0)
m = d.get("msg")
if not m:
  print("EMPTY"); sys.exit(0)
sid = m.get("session_id") or ""
print("MSG")
print(sid)
print(m.get("id",""))
print(m.get("text",""))' <<<"$resp")
  head=$(echo "$parsed" | head -n 1)
  if [ "$head" = "EMPTY" ]; then
    [ "$ONCE" = "1" ] && { echo "queue empty"; break; }
    sleep "$POLL_SECONDS"; continue
  fi
  if [ "$head" != "MSG" ]; then
    echo "bad response: $(echo "$resp" | head -c 200)" >&2
    sleep "$POLL_SECONDS"
    [ "$ONCE" = "1" ] && break
    continue
  fi
  sid=$(echo "$parsed" | sed -n '2p')
  mid=$(echo "$parsed" | sed -n '3p')
  text=$(echo "$parsed" | tail -n +4)
  [ -z "$sid" ] && sid="${TARGET_THREAD:-}"
  if [ -z "$sid" ]; then echo "msg $mid has no session target and TARGET_THREAD unset; skipping delivery" >&2; fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY msg=$mid session=${sid:-<none>} text=$(echo "$text" | head -c 200)"
  elif [ -n "$sid" ]; then
    echo "delivering msg=$mid to $sid : $(echo "$text" | head -c 120)"
    if codex queue --thread "$sid" --message "$text" ${AUTO_RESUME:+--resume} 2>&1; then
      echo "queued ok"
    else
      echo "codex queue failed for $sid" >&2
    fi
  fi
  [ "$ONCE" = "1" ] && break
  sleep 1
done
