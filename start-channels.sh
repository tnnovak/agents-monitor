#!/bin/bash
# Start full bidirectional comms with agents-monitor in one script:
#   codex-tail.sh  (session -> server page, watches latest Codex output)
#   queue-poll.sh  (server page -> session, auto-attaches latest session)
DIR="$(cd "$(dirname "$0")" && pwd)"
export MONITOR_URL="${MONITOR_URL:-https://agents-monitor.fly.dev}"
if [ -z "${INGEST_TOKEN:-}" ]; then
  INGEST_TOKEN=$(fly ssh console -a agents-monitor --command "sh -c 'printenv INGEST_TOKEN'" 2>/dev/null | tail -n 1 | tr -d '\r\n ')
  export INGEST_TOKEN
fi
if [ -z "${INGEST_TOKEN:-}" ]; then echo "INGEST_TOKEN empty and fly lookup failed" >&2; exit 1; fi

# stop any previous channels
pkill -f "codex-tail.sh" 2>/dev/null
pkill -f "queue-poll.sh" 2>/dev/null
sleep 1

"$DIR/codex-tail.sh" > /tmp/codex-tail.log 2>&1 &
echo $! > /tmp/codex-tail.pid
"$DIR/queue-poll.sh" > /tmp/queue-poll.log 2>&1 &
echo $! > /tmp/queue-poll.pid
sleep 2
echo "--- tail ---"; cat /tmp/codex-tail.pid 2>/dev/null | xargs -I{} ps -o pid,etime,cmd -p {} 2>&1 | head -n 3; head -n 2 /tmp/codex-tail.log 2>/dev/null
echo "--- poll ---"; cat /tmp/queue-poll.pid 2>/dev/null | xargs -I{} ps -o pid,etime,cmd -p {} 2>&1 | head -n 3; head -n 3 /tmp/queue-poll.log 2>/dev/null
echo "stop with: kill \$(cat /tmp/codex-tail.pid) \$(cat /tmp/queue-poll.pid)"
