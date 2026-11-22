#!/bin/bash
# tail Codex rollout jsonl -> agents-monitor ingest (polling, picks up new files)
export MONITOR_URL="${MONITOR_URL:-https://agents-monitor.fly.dev}"
HOST_LABEL="${HOST_LABEL:-wsl-$(hostname 2>/dev/null | cut -c1-24)}"
export HOST_LABEL
if [ -z "$INGEST_TOKEN" ]; then
  INGEST_TOKEN=$(fly ssh console -a agents-monitor --command "sh -c 'printenv INGEST_TOKEN'" 2>/dev/null | tail -n 1 | tr -d '\r\n ')
  export INGEST_TOKEN
fi
if [ -z "$INGEST_TOKEN" ]; then echo "INGEST_TOKEN empty" >&2; exit 1; fi
echo "posting to $MONITOR_URL as host=$HOST_LABEL (token len ${#INGEST_TOKEN})"
declare -A SEEN
linecount() { wc -l < "$1" 2>/dev/null | tr -cd '0-9'; }
post_line() {
  # $1 = raw json line; inject host if missing (use $1, never stdin:
  # stdin here is the shared tail pipe of the while-read loop)
  printf '%s' "$1" | HOST_LABEL="$HOST_LABEL" python3 -c 'import json,sys,os
h=os.environ.get("HOST_LABEL","wsl")
d=sys.stdin.read()
try:
  o=json.loads(d)
  o.setdefault("host",h)
  print(json.dumps(o))
except Exception:
  print(d.strip())' | curl -s -m 5 -X POST "$MONITOR_URL/api/ingest" -H "Content-Type: application/json" -H "X-Ingest-Token: $INGEST_TOKEN" --data-binary @- > /dev/null
}
# baseline: skip existing history, only new lines from now on
while IFS= read -r f; do
  [ -z "$f" ] && continue
  n=$(linecount "$f"); [ -z "$n" ] && n=0
  SEEN["$f"]=$n
done < <(find ~/.codex/sessions -name "rollout-*.jsonl" 2>/dev/null)
while true; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    last=${SEEN["$f"]:-0}; last=$(echo "$last" | tr -cd '0-9'); [ -z "$last" ] && last=0
    cur=$(linecount "$f"); [ -z "$cur" ] && cur=0
    if [ "$cur" -gt "$last" ] 2>/dev/null; then
      tail -n +$((last+1)) "$f" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          \{*) post_line "$line" ;;
        esac
      done
      SEEN["$f"]=$cur
    fi
  done < <(find ~/.codex/sessions -name "rollout-*.jsonl" 2>/dev/null)
  sleep 2
done
