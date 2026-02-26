#!/usr/bin/env python3
"""Loggy — Web Server Backend (Phase 13)
Lightweight HTTP server wrapping analyzer.sh for browser-based TUI.
No external dependencies — stdlib only.
Compatible with Python 3.8+ including 3.13 (cgi module removed in 3.13).
"""

import os, sys, json, subprocess, shutil, tempfile, time, re, glob, uuid
import urllib.parse, mimetypes, email
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from io import BytesIO

# ── Config ──────────────────────────────────────────────────────────────────
PORT = int(os.environ.get("IOTECHA_PORT", 8080))
HOST = os.environ.get("IOTECHA_HOST", "0.0.0.0")
ANALYZER = os.environ.get("IOTECHA_ANALYZER", "./analyzer.sh")
FRONTEND = os.environ.get("IOTECHA_FRONTEND", "index.html")
WORK_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_DIR = os.path.join(WORK_DIR, "uploads")
SESSION_DIR = os.path.join(WORK_DIR, "sessions")
ANALYZER_DIR = os.path.dirname(os.path.abspath(ANALYZER))
SIGNATURES_FILE = os.path.join(ANALYZER_DIR, "signatures", "known_signatures.tsv")
REGISTRY_FILE = os.path.join(ANALYZER_DIR, "signatures", "error_registry.tsv")

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(SESSION_DIR, exist_ok=True)

# ── Multipart parser (stdlib only, no cgi module needed) ────────────────────
def parse_multipart(rfile, content_type, content_length):
    """Parse multipart/form-data without the deprecated cgi module.
    Returns dict of {field_name: {'filename': str|None, 'data': bytes}}.
    Works on Python 3.8-3.13+.
    """
    m = re.search(r'boundary=([^\s;]+)', content_type)
    if not m:
        return {}
    boundary = m.group(1).strip('"')
    raw = rfile.read(content_length)
    fake_msg = ('Content-Type: multipart/form-data; boundary="{}"\r\n\r\n'.format(boundary)).encode() + raw
    msg = email.message_from_bytes(fake_msg)
    result = {}
    for part in msg.walk():
        cd = part.get("Content-Disposition", "")
        if not cd:
            continue
        nm = re.search(r'name="([^"]+)"', cd)
        if not nm:
            continue
        name = nm.group(1)
        fn = re.search(r'filename="([^"]*)"', cd)
        filename = fn.group(1) if fn else None
        data = part.get_payload(decode=True)
        if data is None:
            data = b""
        result[name] = {"filename": filename, "data": data}
    return result

# ── Session Store ───────────────────────────────────────────────────────────
sessions = {}

def new_session(input_path):
    sid = uuid.uuid4().hex[:12]
    sdir = os.path.join(SESSION_DIR, sid)
    rdir = os.path.join(sdir, "reports")
    os.makedirs(rdir, exist_ok=True)
    sessions[sid] = {
        "id": sid, "input_path": input_path,
        "work_dir": sdir, "reports_dir": rdir,
        "state": "loaded", "device_id": "", "analysis_mode": "",
        "stdout": "", "stderr": "",
    }
    return sid

# ── Run analyzer.sh ────────────────────────────────────────────────────────
def run_analyzer(args, timeout=120):
    cmd = ["bash", ANALYZER] + args
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           cwd=ANALYZER_DIR, env={**os.environ, "TERM": "dumb", "NO_COLOR": "1"})
        stdout = p.stdout.decode("utf-8", errors="replace")
        stderr = p.stderr.decode("utf-8", errors="replace")
        return p.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Timeout after {}s".format(timeout)
    except Exception as e:
        return 1, "", str(e)

def strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', s)
    s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', s)
    return s

# ── Parse analysis results from reports dir ─────────────────────────────────
def parse_session_results(sid):
    s = sessions.get(sid)
    if not s:
        return None
    rdir = s["reports_dir"]
    result = {"issues": [], "metrics": {}, "status": {}, "timeline": [], "health": {},
              "deep": {}, "signatures": [], "reports": [], "device_info": {}}
    for f in sorted(glob.glob(os.path.join(rdir, "*"))):
        bn = os.path.basename(f)
        result["reports"].append({"name": bn, "path": f, "size": os.path.getsize(f)})
    stdout = s.get("stdout", "")
    for m in re.finditer(r'#\d+\s+(CRITICAL|HIGH|MEDIUM|LOW)\s+(.+?)(?:\n|$)', stdout):
        result["issues"].append({"severity": m.group(1), "title": m.group(2).strip()})
    if not result["issues"]:
        for m in re.finditer(r'\[(CRITICAL|HIGH|MEDIUM|LOW)\]\s+(.+?)(?:\n|$)', stdout):
            result["issues"].append({"severity": m.group(1), "title": m.group(2).strip()})
    m = re.search(r'Health Score:\s*(\d+)\s*/\s*100\s*Grade:\s*([A-F])', stdout)
    if not m:
        m = re.search(r'Health Score:\s*(\d+)/100\s*\(([A-F])\)', stdout)
    if m:
        result["health"] = {"score": int(m.group(1)), "grade": m.group(2)}
    m = re.search(r'Device.*?:\s*(\S+)', stdout)
    if m:
        result["device_info"]["device_id"] = m.group(1)
    return result

# ── Search logs ─────────────────────────────────────────────────────────────
def search_logs(sid, pattern, severity="", component="", after="", before="", max_results=50):
    s = sessions.get(sid)
    if not s:
        return []
    work = s["work_dir"]
    parsed_dir = os.path.join(work, "parsed")
    if not os.path.isdir(parsed_dir):
        return [{"line": "Logs not parsed yet — run analysis first"}]
    results = []
    sev_str = ""
    if severity:
        sev_map = {"E": "|E|", "W": "|W|", "I": "|I|", "C": "|C|", "N": "|N|"}
        sev_str = sev_map.get(severity.upper(), "")
    for f in sorted(glob.glob(os.path.join(parsed_dir, "*.parsed"))):
        try:
            cmd = ["grep", "-i", "-n", pattern, f]
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            for line in p.stdout.strip().split("\n"):
                if not line:
                    continue
                if severity and sev_str and sev_str not in line:
                    continue
                if component and component.lower() not in line.lower():
                    continue
                results.append({"file": os.path.basename(f), "line": line[:300]})
                if len(results) >= max_results:
                    return results
        except:
            pass
    return results

# ── List components from parsed logs ────────────────────────────────────────
def list_components(sid):
    s = sessions.get(sid)
    if not s:
        return []
    parsed_dir = os.path.join(s["work_dir"], "parsed")
    comps = {}
    if os.path.isdir(parsed_dir):
        for f in glob.glob(os.path.join(parsed_dir, "*.parsed")):
            name = os.path.basename(f).replace(".parsed", "")
            try:
                with open(f) as fh:
                    lines = fh.readlines()
                total = len(lines)
                errors = sum(1 for l in lines if "|E|" in l or "|C|" in l)
                warnings = sum(1 for l in lines if "|W|" in l)
                comps[name] = {"total": total, "errors": errors, "warnings": warnings}
            except:
                comps[name] = {"total": 0, "errors": 0, "warnings": 0}
    return comps

# ── Load signatures ─────────────────────────────────────────────────────────
def load_signatures():
    sigs = []
    if os.path.isfile(SIGNATURES_FILE):
        with open(SIGNATURES_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 6:
                    sigs.append({
                        "pattern": parts[0], "component": parts[1],
                        "severity": parts[2], "title": parts[3],
                        "root_cause": parts[4], "fix": parts[5],
                        "kb_url": parts[6] if len(parts) > 6 else "",
                        "source": "signatures"
                    })
    if os.path.isfile(REGISTRY_FILE):
        with open(REGISTRY_FILE) as f:
            col_map = {}
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if not col_map:
                    col_map = {name.strip(): idx for idx, name in enumerate(parts)}
                    continue
                def col(name, default=""):
                    idx = col_map.get(name)
                    if idx is not None and idx < len(parts):
                        return parts[idx]
                    return default
                if len(parts) >= 4:
                    sigs.append({
                        "pattern": col("name"),
                        "component": col("module"),
                        "severity": col("severity", "MEDIUM"),
                        "title": col("description"),
                        "root_cause": col("description"),
                        "fix": col("troubleshootingSteps"),
                        "kb_url": "",
                        "source": "registry",
                        "module": col("module"),
                        "errorType": col("errorType"),
                        "onSiteRequired": col("onSiteServiceRequired", "false")
                    })
    return sigs

# ── HTTP Handler ────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        ts = time.strftime("%H:%M:%S")
        sys.stderr.write("  [{}] {}\n".format(ts, fmt % args))

    def _json(self, data, code=200):
        body = json.dumps(data, default=str, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path, content_type=None):
        if not os.path.isfile(path):
            self._json({"error": "Not found"}, 404)
            return
        ct = content_type or mimetypes.guess_type(path)[0] or "application/octet-stream"
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", len(data))
        self.send_header("Access-Control-Allow-Origin", "*")
        if ct == "application/octet-stream":
            self.send_header("Content-Disposition",
                             'attachment; filename="{}"'.format(os.path.basename(path)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = dict(urllib.parse.parse_qsl(parsed.query))

        if path == "/" or path == "/index.html":
            self._file(FRONTEND, "text/html")
        elif path == "/api/status":
            self._json({"ok": True, "version": "1.0", "sessions": len(sessions), "analyzer": ANALYZER})
        elif path == "/api/sessions":
            self._json({"sessions": [
                {"id": s["id"], "state": s["state"], "device_id": s.get("device_id",""),
                 "input": os.path.basename(s["input_path"]), "mode": s.get("analysis_mode","")}
                for s in sessions.values()
            ]})
        elif path == "/api/check":
            rc, out, err = run_analyzer(["--check"], timeout=15)
            self._json({"ok": rc == 0, "output": strip_ansi(out + err)})
        elif path == "/api/signatures":
            self._json({"signatures": load_signatures()})
        elif path.startswith("/api/session/"):
            parts = path.split("/")
            if len(parts) < 4:
                self._json({"error": "Missing session ID"}, 400); return
            sid = parts[3]
            action = parts[4] if len(parts) > 4 else "info"
            if sid not in sessions:
                self._json({"error": "Session not found"}, 404); return
            if action == "info":
                s = sessions[sid]
                self._json({"session": {
                    "id": sid, "state": s["state"], "device_id": s.get("device_id", ""),
                    "input": os.path.basename(s["input_path"]), "mode": s.get("analysis_mode", ""),
                    "reports": [os.path.basename(f) for f in glob.glob(os.path.join(s["reports_dir"], "*"))],
                }})
            elif action == "results":
                r = parse_session_results(sid)
                r["raw_output"] = sessions[sid].get("stdout", "")
                self._json(r)
            elif action == "search":
                results = search_logs(sid, params.get("q", ""), params.get("severity", ""),
                    params.get("component", ""), params.get("after", ""),
                    params.get("before", ""), int(params.get("max", 50)))
                self._json({"results": results, "count": len(results)})
            elif action == "components":
                self._json({"components": list_components(sid)})
            elif action == "report":
                fname = params.get("file", "")
                if not fname:
                    self._json({"error": "Missing file param"}, 400); return
                fpath = os.path.join(sessions[sid]["reports_dir"], os.path.basename(fname))
                self._file(fpath)
            else:
                self._json({"error": "Unknown action: {}".format(action)}, 404)
        else:
            self._json({"error": "Not found"}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        content_length = int(self.headers.get("Content-Length", 0))

        if path == "/api/upload":
            ct = self.headers.get("Content-Type", "")
            if "multipart" in ct:
                fields = parse_multipart(self.rfile, ct, content_length)
                fileinfo = fields.get("file")
                if fileinfo and fileinfo.get("filename"):
                    safe_name = os.path.basename(fileinfo["filename"])
                    dest = os.path.join(UPLOAD_DIR, "{}_{}".format(uuid.uuid4().hex[:8], safe_name))
                    with open(dest, "wb") as f:
                        f.write(fileinfo["data"])
                    sid = new_session(dest)
                    self._json({"ok": True, "session_id": sid, "file": safe_name})
                else:
                    self._json({"error": "No file"}, 400)
            else:
                body = json.loads(self.rfile.read(content_length))
                p = body.get("path", "")
                if not p or not os.path.exists(p):
                    self._json({"error": "Path not found: {}".format(p)}, 400); return
                sid = new_session(os.path.abspath(p))
                self._json({"ok": True, "session_id": sid, "file": os.path.basename(p)})

        elif path == "/api/analyze":
            body = json.loads(self.rfile.read(content_length))
            sid = body.get("session_id", "")
            mode = body.get("mode", "standard")
            web = body.get("web", False)
            mail = body.get("mail", False)
            tickets = body.get("tickets", False)
            if sid not in sessions:
                self._json({"error": "Session not found"}, 404); return
            s = sessions[sid]
            args = ["-q", "--no-color", "--mode", mode, "-o", s["reports_dir"]]
            if web: args.append("--web")
            if mail: args.append("--mail")
            if tickets: args.append("--tickets")
            args.append(s["input_path"])
            s["state"] = "analyzing"
            s["analysis_mode"] = mode
            rc, out, err = run_analyzer(args, timeout=180)
            out = strip_ansi(out); err = strip_ansi(err)
            s["stdout"] = out; s["stderr"] = err
            s["state"] = "done" if rc == 0 else "error"
            m = re.search(r'Device.*?:\s*(\S+)', out)
            if m: s["device_id"] = m.group(1)
            reports = [os.path.basename(f) for f in glob.glob(os.path.join(s["reports_dir"], "*"))]
            ok = len(reports) > 0
            if ok: s["state"] = "done"
            self._json({"ok": ok, "exit_code": rc, "output": out, "errors": err,
                        "reports": reports, "session_id": sid})

        elif path == "/api/compare":
            body = json.loads(self.rfile.read(content_length))
            base = body.get("baseline", ""); target = body.get("target", "")
            if not base or not target:
                self._json({"error": "Need baseline and target"}, 400); return
            base_path = sessions[base]["input_path"] if base in sessions else base
            target_path = sessions[target]["input_path"] if target in sessions else target
            outdir = os.path.join(SESSION_DIR, "compare_" + uuid.uuid4().hex[:8])
            os.makedirs(outdir, exist_ok=True)
            args = ["-q", "--no-color", "-o", outdir, "--compare", base_path, target_path]
            rc, out, err = run_analyzer(args, timeout=180)
            reports = [os.path.basename(f) for f in glob.glob(os.path.join(outdir, "*"))]
            self._json({"ok": rc == 0, "output": strip_ansi(out), "errors": strip_ansi(err),
                        "reports": reports, "reports_dir": outdir})

        elif path == "/api/fleet":
            body = json.loads(self.rfile.read(content_length))
            directory = body.get("directory", "")
            if not directory or not os.path.isdir(directory):
                self._json({"error": "Directory not found: {}".format(directory)}, 400); return
            outdir = os.path.join(SESSION_DIR, "fleet_" + uuid.uuid4().hex[:8])
            os.makedirs(outdir, exist_ok=True)
            args = ["-q", "--no-color", "-o", outdir, "--fleet", directory]
            rc, out, err = run_analyzer(args, timeout=300)
            reports = [os.path.basename(f) for f in glob.glob(os.path.join(outdir, "*"))]
            self._json({"ok": rc == 0, "output": strip_ansi(out), "errors": strip_ansi(err),
                        "reports": reports, "reports_dir": outdir})
        else:
            self._json({"error": "Not found"}, 404)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


# ── Main ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if sys.version_info < (3, 8):
        sys.stderr.write("  ERROR: Python 3.8+ required (found {}.{})\n".format(*sys.version_info[:2]))
        sys.exit(1)

    try:
        server = HTTPServer((HOST, PORT), Handler)
    except OSError as e:
        sys.stderr.write("  ERROR: Cannot bind to port {} — {}\n".format(PORT, e))
        sys.stderr.write("  Tip: Try a different port with --port 9090\n")
        sys.exit(1)

    url = "http://localhost:{}".format(PORT)
    py_ver = "{}.{}.{}".format(*sys.version_info[:3])
    print("  Serving on {}".format(url))
    print("  Python {}".format(py_ver))
    print("  Press Ctrl+C to stop\n")

    # Auto-open browser (best-effort)
    try:
        import platform as _platform
        _sys = _platform.system()
        if _sys == "Windows":
            # Works in both native Windows and MSYS2/Git Bash
            os.system('start "" "{}"'.format(url))
        elif _sys == "Darwin":
            subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Server stopped.")
        server.server_close()
