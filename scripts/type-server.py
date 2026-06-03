#!/usr/bin/env python3
"""
/paste       POST  {text}  — set X11 clipboard + Ctrl+V to focused window
/toggle-ime  POST         — toggle ibus Chinese/English, return new state
/ime-status  GET          — return current state {"state":"中"|"En"}
"""
import http.server, subprocess, os, json, time

DISPLAY = os.environ.get("DISPLAY", ":1")

# Server-side IM state mirror
_ime = "En"


def _env():
    return {**os.environ, "DISPLAY": DISPLAY}


def _engine_for_state(state):
    return "libpinyin" if state == "中" else "xkb:us::eng"


def _state_for_engine(engine):
    return "中" if engine == "libpinyin" else "En"


def _current_ime():
    """Return IBus' actual engine when available, falling back to our mirror."""
    try:
        r = subprocess.run(
            ["ibus", "engine"],
            env=_env(),
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if r.returncode == 0:
            return _state_for_engine(r.stdout.strip())
    except subprocess.TimeoutExpired:
        pass
    return _ime


def _apply_ime(state):
    """Switch ibus engine between English keyboard and libpinyin."""
    engine = _engine_for_state(state)
    try:
        r = subprocess.run(
            ["ibus", "engine", engine],
            env=_env(),
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
    except subprocess.TimeoutExpired:
        if _current_ime() == state:
            return True, ""
        return False, "ibus engine timed out"

    if _current_ime() == state:
        return True, ""

    if r.returncode != 0:
        details = (r.stderr or r.stdout or "").strip()
        return False, details or "ibus engine failed"
    return True, ""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        global _ime

        if self.path == "/ime-status":
            _ime = _current_ime()
            self._json({"state": _ime})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global _ime

        if self.path == "/toggle-ime":
            _ime = _current_ime()
            target = "中" if _ime == "En" else "En"
            ok, error = _apply_ime(target)
            if ok:
                _ime = target
                self._json({"state": _ime})
            else:
                self._json({"state": _ime, "error": error}, status=500)
            return

        if self.path == "/paste":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length)
            try:
                text = json.loads(raw.decode("utf-8")).get("text", "")
            except Exception:
                text = raw.decode("utf-8", errors="replace")

            if not text:
                self.send_response(400)
                self._cors()
                self.end_headers()
                return

            env = _env()

            # Set both X11 clipboard selections to UTF-8 text
            for sel in ("primary", "clipboard"):
                p = subprocess.Popen(
                    ["xclip", "-selection", sel, "-rmlastnl"],
                    stdin=subprocess.PIPE, env=env,
                )
                p.communicate(text.encode("utf-8"))

            # Give xclip's background process time to become selection owner
            time.sleep(0.15)

            # Send Ctrl+V to whichever X11 window currently has focus
            r = subprocess.run(
                ["xdotool", "getactivewindow"],
                capture_output=True, text=True, env=env,
            )
            win = r.stdout.strip()
            if win:
                subprocess.run(
                    ["xdotool", "key", "--clearmodifiers", "--window", win, "ctrl+v"],
                    env=env, check=False,
                )
            else:
                subprocess.run(
                    ["xdotool", "key", "--clearmodifiers", "ctrl+v"],
                    env=env, check=False,
                )

            self.send_response(200)
            self._cors()
            self.end_headers()
            self.wfile.write(b"ok")
            return

        self.send_response(404)
        self.end_headers()

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", 7070), Handler).serve_forever()
