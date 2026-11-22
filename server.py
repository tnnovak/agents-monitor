import hashlib
import hmac
import json
import os
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.getenv("DATA_DIR", os.path.join(BASE_DIR, "data"))
DATA_FILE = os.path.join(DATA_DIR, "codex-live.jsonl")
QUEUE_FILE = os.path.join(DATA_DIR, "msg-queue.jsonl")
PORT = int(os.getenv("PORT", "8080"))
MONITOR_PASSWORD = os.getenv("MONITOR_PASSWORD", "")
INGEST_TOKEN = os.getenv("INGEST_TOKEN", "") or MONITOR_PASSWORD or ""
COOKIE_NAME = "monitor_auth"

os.makedirs(DATA_DIR, exist_ok=True)
if not os.path.exists(DATA_FILE):
    open(DATA_FILE, "a").close()
if not os.path.exists(QUEUE_FILE):
    open(QUEUE_FILE, "a").close()

LOCK = threading.Lock()

def cookie_token():
    return hashlib.sha256(MONITOR_PASSWORD.encode()).hexdigest() if MONITOR_PASSWORD else ""

def is_authed(handler):
    if not MONITOR_PASSWORD:
        return True
    cookie = handler.headers.get("Cookie", "")
    if f"{COOKIE_NAME}={cookie_token()}" in cookie and cookie_token():
        return True
    auth = handler.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and hmac.compare_digest(auth[7:], MONITOR_PASSWORD):
        return True
    qs = parse_qs(urlparse(handler.path).query)
    if qs.get("token", [""])[0] and hmac.compare_digest(qs["token"][0], MONITOR_PASSWORD):
        return True
    return False

def is_ingest_authed(handler):
    if not INGEST_TOKEN:
        return True
    got = handler.headers.get("X-Ingest-Token", "")
    if got and hmac.compare_digest(got, INGEST_TOKEN):
        return True
    if is_authed(handler):
        return True
    qs = parse_qs(urlparse(handler.path).query)
    if qs.get("token", [""])[0] and hmac.compare_digest(qs["token"][0], INGEST_TOKEN):
        return True
    return False

def get_max_ordinal():
    max_ord = -1
    try:
        with open(DATA_FILE, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                    v = o.get("ordinal")
                    if isinstance(v, int) and v > max_ord:
                        max_ord = v
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return max_ord

def read_queue():
    items = []
    try:
        with open(QUEUE_FILE, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    items.append(json.loads(line))
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return items

def write_queue(items):
    tmp = QUEUE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for o in items:
            f.write(json.dumps(o) + "\n")
    os.replace(tmp, QUEUE_FILE)

def extract_session_id(obj):
    if isinstance(obj.get("session_id"), str):
        return obj["session_id"]
    p = obj.get("payload")
    if isinstance(p, dict):
        for k in ("session_id", "id"):
            if isinstance(p.get(k), str) and len(p[k]) > 8:
                return p[k]
    return None

LOGIN_PAGE = """<!doctype html><html><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>agents-monitor login</title>
<style>body{background:#0b0e14;color:#d6deeb;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
form{background:#111827;padding:24px;border:1px solid #334155;border-radius:8px}input{background:#0b0e14;color:#fff;border:1px solid #334155;padding:8px;margin:8px 0;width:220px}
button{background:#2563eb;color:#fff;border:0;padding:8px 14px;cursor:pointer}</style>
</head><body><form method="POST" action="/login">
<h3>agents-monitor</h3><div>Password:</div>
<input type="password" name="password" autofocus/><br/>
<button type="submit">Enter</button>
</form></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {self.command} {self.path}")

    def send_cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Ingest-Token")

    def send_json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_cors()
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, loc, cookie=None):
        self.send_response(302)
        self.send_header("Location", loc)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors()
        self.end_headers()

    def do_GET(self):
        p = urlparse(self.path)
        if p.path == "/health":
            return self.send_json({"ok": True})
        if p.path == "/login":
            body = LOGIN_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if p.path == "/logout":
            self.redirect("/login", f"{COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax")
            return
        if p.path in ("/get", "/api/get", "/api/queue", "/api/queue/get", "/queue/get"):
            if not is_ingest_authed(self):
                return self.send_json({"error": "unauthorized"}, 401)
            qs = parse_qs(p.query)
            sess = qs.get("session_id", [None])[0]
            host = qs.get("host", [None])[0]
            with LOCK:
                items = read_queue()
                idx = -1
                for i, m in enumerate(items):
                    if sess and m.get("session_id") not in (None, sess):
                        continue
                    if host and m.get("host") != host:
                        continue
                    idx = i
                    break
                if idx == -1:
                    return self.send_json({"ok": True, "msg": None, "depth": len(items)})
                msg = items.pop(idx)
                write_queue(items)
                return self.send_json({"ok": True, "msg": msg, "depth": len(items)})
        if p.path in ("/api/queue/depth", "/queue/depth"):
            if not is_ingest_authed(self):
                return self.send_json({"error": "unauthorized"}, 401)
            with LOCK:
                items = read_queue()
                return self.send_json({"ok": True, "depth": len(items)})
        if not is_authed(self):
            self.redirect("/login")
            return
        if p.path in ("/", "/index.html"):
            fp = os.path.join(BASE_DIR, "index.html")
            with open(fp, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_cors()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if p.path == "/api/logs":
            qs = parse_qs(p.query)
            limit = int(qs.get("limit", ["200"])[0])
            limit = max(1, min(limit, 2000))
            since_raw = qs.get("since", [None])[0]
            try:
                since = int(since_raw) if since_raw not in (None, "") else None
            except ValueError:
                since = None
            session_filter = qs.get("session_id", [None])[0]
            host_filter = qs.get("host", [None])[0]
            lines = []
            try:
                with open(DATA_FILE, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            lines.append(line)
            except FileNotFoundError:
                lines = []
            out = []
            max_ord = since if since is not None else -1
            for line in lines:
                try:
                    obj = json.loads(line)
                    ord_ = obj.get("ordinal")
                    if isinstance(ord_, int) and ord_ > max_ord:
                        max_ord = ord_
                    if since is not None and isinstance(ord_, int) and ord_ <= since:
                        continue
                    if session_filter and obj.get("session_id") != session_filter:
                        p2 = obj.get("payload") or {}
                        if not isinstance(p2, dict) or p2.get("session_id") != session_filter:
                            continue
                    if host_filter and obj.get("host") != host_filter:
                        continue
                    out.append(obj)
                except Exception:
                    out.append({"_raw": line[:2000]})
            out = out[-limit:]
            cursor = since if since is not None else -1
            for o in out:
                if isinstance(o.get("ordinal"), int):
                    cursor = max(cursor, o["ordinal"])
            if max_ord > cursor:
                cursor = max_ord
            return self.send_json({"lines": out, "cursor": cursor, "count": len(out)})
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        p = urlparse(self.path)
        if p.path == "/login":
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length else ""
            qs = parse_qs(raw)
            pw = qs.get("password", [""])[0]
            if MONITOR_PASSWORD and hmac.compare_digest(pw, MONITOR_PASSWORD):
                self.redirect("/", f"{COOKIE_NAME}={cookie_token()}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000")
            else:
                self.redirect("/login")
            return
        if p.path in ("/ingest", "/api/ingest"):
            if not is_ingest_authed(self):
                return self.send_json({"error": "unauthorized"}, 401)
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""
            batch = [l for l in (raw.splitlines() if raw else []) if l.strip()]
            if not batch and raw.strip():
                batch = [raw.strip()]
            appended = 0
            now = datetime.now(timezone.utc).isoformat()
            with LOCK:
                nxt = get_max_ordinal() + 1
                with open(DATA_FILE, "a", encoding="utf-8") as f:
                    for line in batch:
                        try:
                            obj = json.loads(line)
                        except Exception:
                            obj = {"_raw": line[:4000]}
                        client_ord = obj.get("ordinal")
                        if isinstance(client_ord, int) and client_ord != nxt:
                            obj["client_ordinal"] = client_ord
                        obj["ordinal"] = nxt
                        nxt += 1
                        if "timestamp" not in obj:
                            obj["timestamp"] = now
                        obj.setdefault("ingested_at", now)
                        sid = extract_session_id(obj)
                        if sid and "session_id" not in obj:
                            obj["session_id"] = sid
                        f.write(json.dumps(obj) + "\n")
                        appended += 1
            return self.send_json({"ok": True, "appended": appended})
        if p.path in ("/api/queue/send", "/queue/send"):
            if not is_authed(self):
                return self.send_json({"error": "unauthorized"}, 401)
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""
            try:
                body = json.loads(raw) if raw.strip() else {}
            except Exception:
                return self.send_json({"error": "need JSON {text}"}, 400)
            text = str(body.get("text", "")).strip()
            if not text:
                return self.send_json({"error": "empty text"}, 400)
            text = text[:4000]
            sess = body.get("session_id") or None
            if sess is not None:
                sess = str(sess).strip()[:200] or None
            host = body.get("host") or None
            if host is not None:
                host = str(host).strip()[:100] or None
            now = datetime.now(timezone.utc).isoformat()
            with LOCK:
                items = read_queue()
                mid = "%d-%d" % (int(time.time() * 1000) % 100000000, len(items) + 1)
                msg = {"id": mid, "text": text, "session_id": sess, "host": host,
                       "created_at": now, "sender": "web"}
                items.append(msg)
                write_queue(items)
                depth = len(items)
                nxt = get_max_ordinal() + 1
                with open(DATA_FILE, "a", encoding="utf-8") as f:
                    f.write(json.dumps({"ordinal": nxt, "type": "queue_msg", "timestamp": now,
                                        "ingested_at": now, "host": "web",
                                        "session_id": sess,
                                        "payload": {"text": text}}) + "\n")
            return self.send_json({"ok": True, "id": mid, "depth": depth})
        self.send_json({"error": "not found"}, 404)

if __name__ == "__main__":
    mode = "OPEN (no password)" if not MONITOR_PASSWORD else "LOCKED"
    print(f"agents-monitor {mode} on 0.0.0.0:{PORT} -> {DATA_FILE}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
