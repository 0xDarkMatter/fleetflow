#!/usr/bin/env python3
"""ff-serve.py - serve the machine-wide fleetflow dashboard.

One process does both jobs: it serves assets/ff-dashboard.html and it builds the
aggregate. There is deliberately no second moving part - the predecessor of this
service was a static file server plus a detached `ff-status --watch` writing
status.json beside it, and its dominant failure was the watcher dying while the
server stayed up, so the page rendered a perfectly healthy-looking grid of
frozen numbers. Nothing on screen said anything was wrong.

Rebuilds are REQUEST-DRIVEN and NON-BLOCKING:
  * a request is answered from the last good aggregate, immediately, always;
  * if that aggregate is older than --ttl, the request also kicks off a
    background rebuild - so nothing runs when nobody is looking, and a rebuild
    that dies is simply restarted by the next request (a standing watcher, by
    contrast, stays dead until a human notices);
  * one rebuild at a time, with a watchdog so a wedged build cannot block
    refreshes forever.
A cold build over 50+ runs takes minutes; every response carries `age_s`, and
the page shows its own staleness rather than implying freshness it does not have.

Exit codes: 0 clean shutdown | 2 usage | 3 no roots resolved
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

SCRIPT_DIR = Path(__file__).resolve().parent
ASSETS = SCRIPT_DIR.parent / "assets"


def _load_aggregator():
    """Import ff-aggregate.py by path.

    The skill's scripts are named `ff-<verb>` for consistency with its shell
    tools, and a hyphen is not a legal Python identifier - so the aggregator
    cannot be a plain `import`. Loading it by path keeps ONE implementation of
    discovery and roll-up shared between the CLI and this server; duplicating it
    here is exactly how the two would drift apart.
    """
    path = SCRIPT_DIR / "ff-aggregate.py"
    spec = importlib.util.spec_from_file_location("ff_aggregate", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ff_aggregate"] = mod
    spec.loader.exec_module(mod)
    return mod


agg = _load_aggregator()
FF_VERSION = "1.2.0"


def err(msg: str) -> None:
    print(f"ff-serve: {msg}", file=sys.stderr, flush=True)


class State:
    """Everything the request thread and the builder thread share."""

    def __init__(self, roots, source, opts):
        self.roots = roots
        self.source = source
        self.opts = opts
        self.lock = threading.Lock()
        self.doc: dict | None = None
        self.built_at = 0.0
        self.building_since = 0.0
        self.builds = 0
        self.last_error: str | None = None
        self.cache: dict = {}
        self._load_cache()

    # The on-disk cache is what makes a service restart cheap: a finished run
    # already read once is never read again, so only genuinely live runs cost
    # anything after the first ever build on this machine.
    def _cache_path(self) -> Path:
        return agg.FF_HOME / "cache" / "aggregate-cache.json"

    def _load_cache(self) -> None:
        p = self._cache_path()
        if p.is_file():
            try:
                self.cache = json.loads(p.read_text(encoding="utf-8"))
                err(f"loaded run cache ({len(self.cache)} entries) from {p}")
            except (OSError, json.JSONDecodeError):
                self.cache = {}

    def _save_cache(self) -> None:
        try:
            p = self._cache_path()
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.cache), encoding="utf-8")
            os.replace(tmp, p)
        except OSError as e:
            err(f"cache not persisted: {e}")

    def maybe_build(self) -> None:
        """Start a rebuild if one is due and none is running. Never blocks."""
        with self.lock:
            now = time.time()
            running = self.building_since > 0
            if running and now - self.building_since < self.opts.build_timeout:
                return
            if running:
                # A build that has outlived the watchdog is presumed wedged (a
                # hung git call in some repo, a drive that went away mid-scan).
                # Let a fresh one start rather than freezing the dashboard on
                # whatever the last good document happened to be.
                err(f"build watchdog: previous build exceeded "
                    f"{self.opts.build_timeout}s - starting another")
            if not running and self.doc and now - self.built_at < self.opts.ttl:
                return
            self.building_since = now
        threading.Thread(target=self._build, daemon=True).start()

    def _build(self) -> None:
        t0 = time.time()
        try:
            doc, cache = agg.aggregate(
                self.roots, self.source,
                max_depth=self.opts.max_depth, cache=self.cache,
                live_ttl=self.opts.live_ttl, discover_ttl=self.opts.discover_ttl,
                timeout=self.opts.timeout, workers=self.opts.workers)
            with self.lock:
                self.doc = doc
                self.cache = cache
                self.built_at = time.time()
                self.builds += 1
                self.last_error = None
            self._save_cache()
            t = doc.get("totals", {})
            err(f"build #{self.builds}: {t.get('runs')} runs / {t.get('live_runs')} live "
                f"/ {doc.get('runs_refreshed')} refreshed in {int((time.time()-t0)*1000)}ms")
        except Exception as e:  # a builder crash must never take the server down
            with self.lock:
                self.last_error = f"{type(e).__name__}: {e}"
            err(f"build FAILED: {self.last_error}")
        finally:
            with self.lock:
                self.building_since = 0.0

    def snapshot(self) -> tuple[dict | None, dict]:
        with self.lock:
            meta = {
                "served_at": int(time.time()),
                "age_s": int(time.time() - self.built_at) if self.built_at else None,
                "building": self.building_since > 0,
                "builds": self.builds,
                "ttl_s": self.opts.ttl,
                "server_version": FF_VERSION,
                "build_error": self.last_error,
            }
            return self.doc, meta


class Doctor:
    """Runs ff-doctor.sh and caches its verdict for the dashboard's Fleet view.

    The two modes have wildly different costs and MUST NOT be treated alike:
    `--offline` is binaries + `bash -n` (~1-2s, safe to run inline on a request),
    while `--live` probes every provider over the network - including a real
    `claude -p` per Anthropic model at up to 120s each - so it is minutes. Live
    therefore runs in a BACKGROUND thread and the request returns the last good
    verdict with `building: true`, exactly like the aggregate does, for exactly
    the same reason: a page that blocks for two minutes is indistinguishable
    from a dead one.

    Never probes on its own schedule. Capacity is a question the operator asks,
    not a thing to poll - `--live` spends real model calls, and a dashboard that
    quietly billed a provider probe every few seconds would be a bug with an
    invoice attached.
    """

    #: ff-doctor emits `name<TAB>status<TAB>detail`; status is one of these.
    #: `unavailable` is the model probe's own word for "did not answer" and is
    #: counted separately from `unreachable` (a provider we could not reach at
    #: all) - conflating them would hide which half of the fleet is actually up.
    STATUSES = ("ok", "advisory", "unavailable", "unreachable", "fail")

    def __init__(self, opts):
        self.opts = opts
        self.lock = threading.Lock()
        self.docs: dict[str, dict] = {}     # mode -> last good verdict
        self.running: set[str] = set()

    def _script(self) -> Path:
        return SCRIPT_DIR / "ff-doctor.sh"

    def _run(self, mode: str) -> None:
        t0 = time.time()
        bash = shutil.which("bash") or "bash"
        # Bounded well above --live's own internal per-probe timeouts so a slow
        # provider reports as slow rather than as a killed doctor.
        budget = self.opts.doctor_timeout if mode == "live" else 90
        try:
            p = subprocess.run(
                [bash, str(self._script()), f"--{mode}"],
                capture_output=True, text=True, timeout=budget,
                cwd=str(SCRIPT_DIR.parent))
            out, rc = p.stdout, p.returncode
        except subprocess.TimeoutExpired:
            out, rc = "", 124
        except (OSError, subprocess.SubprocessError) as e:
            err(f"doctor {mode} failed to launch: {e}")
            out, rc = "", 125

        checks, counts = [], {s: 0 for s in self.STATUSES}
        for line in out.splitlines():
            parts = line.rstrip("\r").split("\t")
            if len(parts) < 2 or not parts[0]:
                continue
            name, status = parts[0], parts[1]
            checks.append({"name": name, "status": status,
                           "detail": parts[2] if len(parts) > 2 else ""})
            if status in counts:
                counts[status] += 1

        orch = next((c["detail"] for c in checks
                     if c["name"] == "orchestrator" and c["status"] == "ok"), None)
        doc = {
            "schema": "fleetflow/doctor/1", "mode": mode,
            "ran_at": int(time.time()), "took_ms": int((time.time() - t0) * 1000),
            "exit_code": rc,
            # rc 0 = every REQUIRED check passed. Advisories (a model whose CLI
            # is not installed) are informational and deliberately not failures:
            # an absent grok is a capability you do not have, not a broken fleet.
            "ok": rc == 0, "counts": counts, "checks": checks,
            "orchestrator": orch,
            "error": ("timed out after %ds" % budget) if rc == 124
                     else ("could not launch ff-doctor.sh" if rc == 125 else None),
        }
        with self.lock:
            self.docs[mode] = doc
            self.running.discard(mode)
        err(f"doctor {mode}: rc={rc} "
            f"ok={counts['ok']} advisory={counts['advisory']} "
            f"unreachable={counts['unreachable']} fail={counts['fail']} "
            f"in {doc['took_ms']}ms")

    def get(self, mode: str, force: bool) -> dict:
        """Return the last good verdict, refreshing it when stale or forced."""
        ttl = self.opts.doctor_live_ttl if mode == "live" else self.opts.doctor_ttl
        with self.lock:
            doc = self.docs.get(mode)
            busy = mode in self.running
            fresh = doc is not None and time.time() - doc["ran_at"] < ttl and not force
            if not fresh and not busy:
                self.running.add(mode)
                start = True
            else:
                start = False
        if start:
            if mode == "offline":
                self._run(mode)          # fast enough to answer this request
                with self.lock:
                    doc = self.docs.get(mode)
            else:
                threading.Thread(target=self._run, args=(mode,), daemon=True).start()
        with self.lock:
            doc = self.docs.get(mode)
            building = mode in self.running
        if doc is None:
            return {"schema": "fleetflow/doctor/1", "mode": mode, "checks": [],
                    "counts": {s: 0 for s in self.STATUSES}, "building": building,
                    "ran_at": None, "age_s": None, "ok": None, "orchestrator": None,
                    "error": None if building else "no verdict yet"}
        return {**doc, "building": building,
                "age_s": int(time.time() - doc["ran_at"])}


class Roost:
    """Surfaces `roost status --json` for the dashboard's ROOST accounts pane.

    roost is the Claude Code OAuth profile health/load-balancer (claude-lb).
    It is a per-machine optional install: absence is a capability this box
    does not have, not an error - the binary is probed once at startup and
    the endpoint answers {"available": false}, which is the page's signal to
    not render the section at all.

    Same one-process, request-driven design as Doctor: the CLI call runs in a
    BACKGROUND thread and requests are answered from the last good verdict
    immediately. roost caches its own probes (~5 min TTL server-side in
    roost itself), so the TTL here only keeps the dashboard's poll from
    spawning a process per tick. The raw --json payload is tens of KB
    (28 days of per-component platform-status history); only the fields the
    pane actually renders are forwarded.
    """

    TTL = 60          # seconds a verdict is served without re-running the CLI
    TIMEOUT = 90      # roost's own probe path can take a few seconds cold

    def __init__(self):
        self.lock = threading.Lock()
        self.doc: dict | None = None
        self.at = 0.0
        self.running = False
        self.refreshing = False
        self.refresh_result: dict | None = None
        self.last_error: str | None = None
        self.bin = shutil.which("roost")
        if self.bin:
            err(f"roost detected at {self.bin} - ROOST accounts pane enabled")

    def refresh_auth(self) -> dict:
        """Kick `roost refresh --soon 30m --json` in the background: renews the
        OAuth tokens of expired and soon-to-expire profiles. Local CLI only, no
        model calls - but it IS a state change to the auth store, so it runs
        strictly click-gated, never on a poll or timer."""
        if not self.bin:
            return {"available": False}
        with self.lock:
            start = not self.refreshing
            if start:
                self.refreshing = True
        if start:
            threading.Thread(target=self._refresh, daemon=True).start()
        with self.lock:
            return {"available": True, "refreshing": True,
                    "last": self.refresh_result}

    def _refresh(self) -> None:
        try:
            p = subprocess.run(
                [self.bin, "refresh", "--soon", "30m", "--json"],
                capture_output=True, text=True, timeout=180,
                encoding="utf-8", errors="replace", stdin=subprocess.DEVNULL)
            out = (p.stdout or p.stderr or "").strip()
            with self.lock:
                self.refresh_result = {"ok": p.returncode == 0,
                                       "at": int(time.time()),
                                       "detail": out[:400]}
        except Exception as e:  # noqa: BLE001
            with self.lock:
                self.refresh_result = {"ok": False, "at": int(time.time()),
                                       "detail": f"{type(e).__name__}: {e}"}
        finally:
            with self.lock:
                self.refreshing = False
                self.at = 0.0   # token state changed - next status read re-probes

    def _run(self) -> None:
        t0 = time.time()
        try:
            p = subprocess.run(
                [self.bin, "status", "--json"],
                capture_output=True, text=True, timeout=self.TIMEOUT,
                encoding="utf-8", errors="replace",
                stdin=subprocess.DEVNULL)
            data = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else None
            if data is None:
                tail = (p.stderr or "").strip().splitlines()
                raise RuntimeError(tail[-1] if tail else f"roost exit {p.returncode}")
            doc = self._trim(data)
            # `roost widget` is roost's OWN visual for exactly this data — a
            # self-contained, script-free, .rw-scoped HTML fragment built for
            # embedding. The dashboard renders it verbatim rather than
            # re-designing roost's surface. Best-effort: an older roost
            # without the subcommand just means the pane falls back to the
            # dashboard's plain profile cards.
            try:
                w = subprocess.run(
                    [self.bin, "widget"],
                    capture_output=True, text=True, timeout=self.TIMEOUT,
                    encoding="utf-8", errors="replace",
                    stdin=subprocess.DEVNULL)
                if w.returncode == 0 and "<" in (w.stdout or ""):
                    doc["widget"] = w.stdout
            except (OSError, subprocess.SubprocessError):
                pass
            doc["took_ms"] = int((time.time() - t0) * 1000)
            with self.lock:
                self.doc = doc
                self.at = time.time()
                self.last_error = None
        except Exception as e:  # noqa: BLE001 - any failure = stale pane, never a crash
            with self.lock:
                self.last_error = f"{type(e).__name__}: {e}"
            err(f"roost probe FAILED: {self.last_error}")
        finally:
            with self.lock:
                self.running = False

    @staticmethod
    def _trim(data: dict) -> dict:
        profiles = []
        for p in data.get("data") or []:
            u = p.get("usage") or {}
            profiles.append({
                "name": p.get("name"),
                "health": p.get("health"),
                "subscription_type": p.get("subscription_type"),
                "session_pct": u.get("session_pct"),
                "weekly_pct": u.get("weekly_pct"),
                "session_reset_at": p.get("session_reset_at"),
                "weekly_reset_at": p.get("weekly_reset_at"),
                "error": p.get("error"),
                "probed_at": p.get("probed_at"),
            })
        meta = data.get("meta") or {}
        ps = meta.get("platform_status") or {}
        return {
            "schema": "fleetflow/roost/1", "available": True,
            "ran_at": int(time.time()),
            "profiles": profiles,
            "counts": {k: meta.get(k) for k in (
                "count", "ok", "rate_limited", "session_limit", "weekly_limit",
                "auth_expired", "auth_dead", "network_error", "unknown") if k in meta},
            "platform": {
                "indicator": ps.get("indicator"),
                "description": ps.get("description"),
                "active_incidents": len(ps.get("active_incidents") or []),
                "degraded": [c.get("name") for c in (ps.get("degraded_components") or [])],
                "age_seconds": ps.get("age_seconds"),
            } if ps else None,
        }

    def get(self, force: bool) -> dict:
        if not self.bin:
            return {"schema": "fleetflow/roost/1", "available": False}
        with self.lock:
            fresh = self.doc is not None and time.time() - self.at < self.TTL and not force
            start = not fresh and not self.running
            if start:
                self.running = True
        if start:
            threading.Thread(target=self._run, daemon=True).start()
        with self.lock:
            doc, building, error = self.doc, self.running, self.last_error
        with self.lock:
            refreshing, refresh = self.refreshing, self.refresh_result
        if doc is None:
            return {"schema": "fleetflow/roost/1", "available": True,
                    "building": building, "profiles": [], "counts": {},
                    "platform": None, "age_s": None, "error": error,
                    "refreshing": refreshing, "refresh": refresh}
        return {**doc, "building": building,
                "age_s": int(time.time() - self.at), "error": error,
                "refreshing": refreshing, "refresh": refresh}


class Handler(BaseHTTPRequestHandler):
    state: State = None  # type: ignore[assignment]
    doctor: Doctor = None  # type: ignore[assignment]
    roost: Roost = None  # type: ignore[assignment]
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - signature is the base class's
        pass  # quiet by design: the page polls every 3s and would flood the log

    def handle(self) -> None:
        """Swallow client-side disconnects for the WHOLE exchange, not just the
        write. The process manager's readiness probe opens a keep-alive socket
        and resets it once it has what it wants, which raises inside the base
        class's own `readline` - outside any handler code. Left alone it prints
        a full traceback per probe: this service's log was pure connection-reset
        noise every 10 seconds, which is how a real error goes unnoticed."""
        try:
            super().handle()
        except OSError:
            pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            # Every way a client can leave mid-write lands here, and none of them
            # are this server's problem: a closed tab (BrokenPipe/ConnectionReset)
            # or the process manager's readiness probe hanging up the moment it
            # has its status line (ConnectionAborted / WinError 10053, which is
            # what Windows raises and what filled this service's log on day one).
            # Catching the specific subclasses missed that third case.
            pass

    def _json(self, code: int, obj: dict) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/index.html"):
            f = ASSETS / "ff-dashboard.html"
            try:
                self._send(200, f.read_bytes(), "text/html; charset=utf-8")
            except OSError as e:
                self._send(500, f"cannot read {f}: {e}".encode(), "text/plain; charset=utf-8")
            return

        if path == "/api/aggregate.json":
            self.state.maybe_build()
            doc, meta = self.state.snapshot()
            if doc is None:
                # 200, not an error status: "building" is a normal state the page
                # renders as a message. A 5xx here would be indistinguishable to
                # the page from the server being gone, which is the one thing it
                # must be able to tell apart.
                self._json(200, {"schema": "fleetflow/aggregate/1", "runs": [], "history": [],
                                 "errors": [], "totals": {}, "roots": [str(r) for r in self.state.roots],
                                 "generated_at": int(time.time()),
                                 "error": "building the first aggregate — a cold scan of every "
                                          "root can take a few minutes; this page will fill in",
                                 **meta})
                return
            self._json(200, {**doc, **meta})
            return

        if path == "/api/refresh":
            with self.state.lock:
                self.state.built_at = 0.0  # force the next maybe_build
            self.state.maybe_build()
            self._json(200, {"ok": True, "forced": True})
            return

        if path == "/api/doctor.json":
            q = parse_qs(urlsplit(self.path).query)
            truthy = {"1", "true", "yes", ""}
            mode = "live" if (q.get("live", [None])[0] in truthy) else "offline"
            force = q.get("force", [None])[0] in truthy
            self._json(200, self.doctor.get(mode, force=force))
            return

        if path == "/api/roost/refresh":
            self._json(200, self.roost.refresh_auth())
            return

        if path == "/api/roost.json":
            q = parse_qs(urlsplit(self.path).query)
            force = q.get("force", [None])[0] in {"1", "true", "yes", ""}
            self._json(200, self.roost.get(force=force))
            return

        if path in ("/api/health", "/health"):
            doc, meta = self.state.snapshot()
            self._json(200, {"ok": True, "has_aggregate": doc is not None,
                             "runs": (doc or {}).get("totals", {}).get("runs"), **meta})
            return

        self._send(404, b"not found", "text/plain; charset=utf-8")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="ff-serve.py", add_help=False,
        description="Serve the machine-wide fleetflow dashboard and build its aggregate.",
        epilog="""ROUTES
  /                     the dashboard (assets/ff-dashboard.html)
  /api/aggregate.json   last good aggregate + freshness meta; triggers a
                        background rebuild when older than --ttl
  /api/refresh          force a rebuild on the next poll
  /api/doctor.json      ff-doctor verdict for the Fleet view. Default --offline
                        (binaries + syntax, runs inline). ?live=1 additionally
                        probes every provider - minutes, and it spends real
                        model calls, so it runs in the background and is only
                        ever started by an explicit request. ?force=1 ignores
                        the cache.
  /api/roost.json       Claude OAuth profile health via the roost CLI (claude-lb),
                        trimmed to what the pane renders; {"available": false}
                        when roost is not installed on this machine. Cached 60s,
                        probed in the background. ?force=1 ignores the cache.
  /api/health           liveness + whether an aggregate exists yet

EXAMPLES
  ff-serve.py --port 8161
  ff-serve.py --port 8161 --root X:/Forma --root X:/Roam
  curl -s localhost:8161/api/health | jq .
""",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8161)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--root", action="append", default=[], metavar="PATH")
    ap.add_argument("--ttl", type=int, default=10, metavar="SECONDS",
                    help="max aggregate age before a request triggers a rebuild")
    ap.add_argument("--live-ttl", type=int, default=15, metavar="SECONDS")
    ap.add_argument("--discover-ttl", type=int, default=120, metavar="SECONDS")
    ap.add_argument("--max-depth", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=180, metavar="SECONDS")
    ap.add_argument("--build-timeout", type=int, default=600, metavar="SECONDS")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--doctor-ttl", type=int, default=30, metavar="SECONDS",
                    help="cache life of an --offline doctor verdict")
    ap.add_argument("--doctor-live-ttl", type=int, default=900, metavar="SECONDS",
                    help="cache life of a --live verdict (it spends real model calls)")
    ap.add_argument("--doctor-timeout", type=int, default=420, metavar="SECONDS",
                    help="hard budget for a --live probe")
    ap.add_argument("-h", "--help", action="help")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code not in (0, None) else 0

    roots, source = agg.resolve_roots(a.root)
    if not roots:
        err("no roots resolved - pass --root, set $FLEETFLOW_ROOTS, "
            "or run: ff-aggregate.py --init-roots <PATH>...")
        return 3

    state = State(roots, source, a)
    Handler.state = state
    Handler.doctor = Doctor(a)
    Handler.roost = Roost()
    err(f"fleetflow {FF_VERSION} - roots from {source}: "
        f"{', '.join(str(r) for r in roots)}")

    # Warm up straight away so the first visitor is not the one paying for a
    # cold scan. Backgrounded: the socket must be listening immediately or the
    # process manager's readiness probe fails while we scan the disk.
    state.maybe_build()

    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    err(f"listening on http://{a.bind}:{a.port}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        err("shutting down")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
