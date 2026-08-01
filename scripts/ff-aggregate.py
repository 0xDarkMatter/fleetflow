#!/usr/bin/env python3
"""ff-aggregate.py - discover every fleetflow run on this machine and roll them
up into ONE status document (the data feed behind assets/ff-dashboard.html).

WHAT THIS IS NOT: a second implementation of ff-status. Lane state, the stall
detector, and token accounting are subtle enough that a copy would drift and
start lying - in particular `live_signal:false` means "cannot substantiate a
stall", never "healthy", and only ff-status knows which brains it covers. So
this script SHELLS OUT to ff-status.sh once per run and only adds what a
single-run view cannot: discovery, cross-repo grouping, roll-ups, and history.

Three things make that affordable:
  * discovery is cached (roots are walked at most once per --discover-ttl);
  * a run is re-read only when its directory FINGERPRINT (file count + newest
    mtime) changes, or when it still has in-flight lanes and the cached copy is
    older than --live-ttl (the stall clock has to keep ticking);
  * runs are read in parallel.
A finished, untouched run therefore costs one scandir per aggregate, forever.

stdout: the JSON document (data only). stderr: chatter.
Exit codes: 0 ok | 2 usage | 3 no roots resolved | 7 every root unreadable
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

FF_VERSION = "1.2.0"
HOME = Path(os.environ.get("USERPROFILE") or Path.home())
FF_HOME = Path(os.environ.get("FLEETFLOW_HOME") or (HOME / ".fleetflow"))
SCRIPT_DIR = Path(__file__).resolve().parent

# Directories never worth descending into. `.claude` is deliberately ABSENT:
# background-agent lanes live at <repo>/.claude/worktrees/<slug>/, and a fleet
# run started inside one of those worktrees is a real run with real history.
PRUNE = {
    "node_modules", ".git", ".venv", "venv", "__pycache__", "dist", "build",
    "target", ".next", ".nuxt", ".cache", ".pytest_cache", ".mypy_cache",
    "vendor", ".terraform", "Library", "AppData", "$RECYCLE.BIN",
    "System Volume Information",
}

# Roll-up precedence. A single stalled lane is the headline for the whole run:
# it is the state most likely to be costing money while looking like progress.
STATE_RANK = ["stalled", "running", "failed", "done", "unknown"]


def err(msg: str) -> None:
    print(f"ff-aggregate: {msg}", file=sys.stderr)


# --------------------------------------------------------------------------
# roots
# --------------------------------------------------------------------------
def resolve_roots(cli_roots: list[str]) -> tuple[list[Path], str]:
    """Roots come from the first source that yields any, so this skill never
    carries one machine's directory layout. The final fallback is the current
    repo alone - correct everywhere, zero-config, and never a surprise scan of
    somebody's whole home directory."""
    if cli_roots:
        return [Path(r) for r in cli_roots], "--root"
    env = os.environ.get("FLEETFLOW_ROOTS")
    if env:
        return [Path(p) for p in env.split(os.pathsep) if p.strip()], "FLEETFLOW_ROOTS"
    cfg = FF_HOME / "roots.txt"
    if cfg.is_file():
        lines = [
            ln.strip() for ln in cfg.read_text(encoding="utf-8", errors="replace").splitlines()
        ]
        paths = [Path(ln) for ln in lines if ln and not ln.startswith("#")]
        if paths:
            return paths, str(cfg)
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        if top.returncode == 0 and top.stdout.strip():
            return [Path(top.stdout.strip())], "git toplevel (fallback)"
    except (OSError, subprocess.SubprocessError):
        pass
    return [], "none"


# --------------------------------------------------------------------------
# discovery
# --------------------------------------------------------------------------
def find_run_dirs(roots: list[Path], max_depth: int, errors: list[dict]) -> list[dict]:
    """Walk each root looking for <repo>/.fleetflow/<run>/journal.jsonl.

    An unreadable root is recorded and skipped, never raised: one offline
    network drive must not cost you the view of every local run.
    """
    found: list[dict] = []
    seen: set[str] = set()

    def walk(d: Path, depth: int, root: Path) -> None:
        if depth > max_depth:
            return
        try:
            entries = list(os.scandir(d))
        except OSError as e:
            errors.append({"scope": "scan", "path": str(d), "error": str(e)})
            return
        for e in entries:
            try:
                if not e.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            name = e.name
            if name == ".fleetflow":
                collect(Path(e.path), Path(d), root)
                continue
            if name in PRUNE or (name.startswith(".") and name != ".claude"):
                continue
            walk(Path(e.path), depth + 1, root)

    def collect(ffdir: Path, repo: Path, root: Path) -> None:
        try:
            runs = list(os.scandir(ffdir))
        except OSError as e:
            errors.append({"scope": "scan", "path": str(ffdir), "error": str(e)})
            return
        for r in runs:
            try:
                if not r.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            journal = Path(r.path) / "journal.jsonl"
            if not journal.is_file():
                continue  # e.g. the served `monitor/` dir - not a run
            key = str(Path(r.path).resolve()).lower()
            if key in seen:
                continue
            seen.add(key)
            found.append({
                "rundir": str(Path(r.path)),
                "run": r.name,
                "repo": str(repo),
                "repo_label": repo_label(repo, root),
                "root": str(root),
            })

    for root in roots:
        if not root.is_dir():
            errors.append({"scope": "root", "path": str(root), "error": "not a directory"})
            continue
        walk(root, 0, root)
    return found


def repo_label(repo: Path, root: Path) -> str:
    """Short, human-scannable repo name. Worktree lanes collapse to
    `GlyphWeb@unruffled-maxwell-1dd4f0` rather than a 90-char path."""
    try:
        rel = repo.relative_to(root)
        label = str(rel).replace("\\", "/")
    except ValueError:
        label = str(repo).replace("\\", "/")
    parts = [p for p in label.split("/") if p]
    if ".claude" in parts and "worktrees" in parts:
        i = parts.index(".claude")
        base = "/".join(parts[:i]) or repo.name
        wt = parts[-1]
        return f"{base}@{wt}"
    return label or repo.name


# --------------------------------------------------------------------------
# per-run status (delegated to ff-status.sh)
# --------------------------------------------------------------------------
def producer_stamp() -> str:
    """Identity of the thing that PRODUCED a cached run status.

    The run-dir fingerprint answers "did the data change". It cannot answer "did
    the reader change" - so after ff-status gained new fields, every cached entry
    kept serving the old shape forever, because the runs themselves were untouched.
    Mixing the reader's mtime+size into the cache key makes an edit to ff-status
    invalidate exactly the entries it affects, on the next build, with no manual
    cache-clearing step to remember.
    """
    # BOTH producers count. ff-status.sh emits the lane fields; THIS file computes
    # the roll-up on top of them - and forgetting the second is how a new
    # summary field silently stayed null on every cached run even after the
    # reader was correctly invalidated.
    parts = [FF_VERSION]
    for f in ("ff-status.sh", "ff-aggregate.py"):
        try:
            st = (SCRIPT_DIR / f).stat()
            parts.append(f"{int(st.st_mtime)}:{st.st_size}")
        except OSError:
            parts.append("?")
    return ":".join(parts)


def fingerprint(rundir: Path) -> tuple[int, int]:
    """(file count, newest mtime_ns) over the run dir, non-recursive. Every
    signal ff-status reads - journal, events streams, transcripts, artifacts,
    stderr - is a file directly in here, so this changes exactly when the run's
    status could have changed."""
    n = 0
    newest = 0
    try:
        for e in os.scandir(rundir):
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            n += 1
            if st.st_mtime_ns > newest:
                newest = st.st_mtime_ns
    except OSError:
        return (-1, -1)
    return (n, newest)


def roll_up(status: dict) -> dict:
    lanes = status.get("lanes") or []
    counts: dict[str, int] = {}
    for l in lanes:
        counts[l.get("state", "unknown")] = counts.get(l.get("state", "unknown"), 0) + 1
    state = next((s for s in STATE_RANK if counts.get(s)), "unknown")

    # cost_usd is null for any brain that does not price its own turn (codex,
    # grok). Summing those as zero would quietly under-report the run, so the
    # total carries how many lanes it actually covers and the page says so.
    costed = [l for l in lanes if isinstance(l.get("cost_usd"), (int, float))]
    started = [l["started"] for l in lanes if l.get("started")]
    # Freshest silence across the still-in-flight lanes. Drives the graduated
    # re-read interval: a run somebody is actively watching writes constantly and
    # gets polled hard; a run abandoned three days ago in `stalled` gets polled
    # rarely, because re-reading cannot change a verdict that is already final.
    inflight = [l for l in lanes if l.get("state") in ("running", "stalled")]
    idle = min((l.get("last_activity_s") or 0) for l in inflight) if inflight else None
    return {
        "state": state,
        "counts": counts,
        "lane_count": len(lanes),
        "idle_s": idle,
        "tokens_total": sum(l.get("tokens_total") or 0 for l in lanes),
        "tokens_in": sum(l.get("tokens_in") or 0 for l in lanes),
        "tokens_cached": sum(l.get("tokens_cached") or 0 for l in lanes),
        "tokens_out": sum(l.get("tokens_out") or 0 for l in lanes),
        "cost_usd": round(sum(l["cost_usd"] for l in costed), 4) if costed else None,
        "cost_lanes": len(costed),
        "cost_partial": len(costed) < len(lanes),
        "started": min(started) if started else 0,
        "elapsed_s": max((l.get("elapsed_s") or 0) for l in lanes) if lanes else 0,
        "brains": sorted({l.get("brain", "?") for l in lanes}),
        "orchestrator": status.get("orchestrator"),
        "models": sorted({l["model"] for l in lanes if l.get("model")}),
        "phases": [p for p in dict.fromkeys(l.get("phase", "build") for l in lanes)],
    }


REFRESH_CAP = 900  # never let an abandoned run go longer than 15 min unchecked


def refresh_interval(summary: dict, live_ttl: int) -> int:
    """How long a cached in-flight run may be trusted, given how quiet it is."""
    idle = summary.get("idle_s")
    if not idle or idle < live_ttl * 4:
        return live_ttl
    return max(live_ttl, min(idle // 4, REFRESH_CAP))


def read_run(entry: dict, bash: str, timeout: int) -> dict:
    """One ff-status.sh invocation. Any failure degrades to an `error` run card
    - a torn journal write mid-`mv` or a repo being cleaned right now must cost
    one tile, not the whole aggregate."""
    cmd = [
        bash, str(SCRIPT_DIR / "ff-status.sh"),
        "--run", entry["run"], "--repo", entry["repo"],
    ]
    try:
        # encoding is explicit: Python defaults to the ANSI codepage on Windows
        # (cp1252), and a single non-Latin-1 byte in a lane's activity string or
        # error tail would otherwise blow up the decoder thread and take the run
        # card with it. ff-status emits UTF-8 JSON.
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return {**entry, "error": f"ff-status timed out after {timeout}s", "lanes": []}
    except OSError as e:
        return {**entry, "error": f"cannot run ff-status: {e}", "lanes": []}
    out = p.stdout or ""
    if p.returncode not in (0, 14) or not out.strip():
        tail = (p.stderr or "").strip().splitlines()
        return {**entry, "error": (tail[-1] if tail else f"ff-status exit {p.returncode}"),
                "lanes": []}
    try:
        status = json.loads(out)
    except json.JSONDecodeError as e:
        return {**entry, "error": f"unparseable ff-status output: {e}", "lanes": []}
    return {**entry, **status, "summary": roll_up(status)}


# --------------------------------------------------------------------------
# history
# --------------------------------------------------------------------------
def load_history(limit: int) -> tuple[list[dict], list[dict]]:
    """Read ~/.fleetflow/history.jsonl (append-only; see ff-archive.sh).

    Last record wins per (repo, run): re-archiving a run supersedes rather than
    duplicates, which is what makes the append-only file safe to append to from
    ff-clean on every teardown.
    """
    path = FF_HOME / "history.jsonl"
    errors: list[dict] = []
    if not path.is_file():
        return [], errors
    by_key: dict[str, dict] = {}
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue  # a torn final line is expected on an append-only file
                key = f"{rec.get('repo', '')}|{rec.get('run', '')}".lower()
                by_key[key] = rec
    except OSError as e:
        errors.append({"scope": "history", "path": str(path), "error": str(e)})
        return [], errors
    recs = sorted(by_key.values(), key=lambda r: r.get("archived_at", 0), reverse=True)
    return recs[:limit], errors


# --------------------------------------------------------------------------
# aggregate
# --------------------------------------------------------------------------
def aggregate(
    roots: list[Path], source: str, *, max_depth: int = 6, cache: dict | None = None,
    live_ttl: int = 15, discover_ttl: int = 60, timeout: int = 180,
    workers: int = 12, want_history: bool = True, history_limit: int = 200,
) -> tuple[dict, dict]:
    """Returns (document, new_cache). `cache` is passed in and back out so a
    long-lived server keeps it in memory and a one-shot CLI run persists it."""
    t0 = time.time()
    cache = cache or {}
    errors: list[dict] = []
    now = int(time.time())

    disc = cache.get("_discovery")
    t_disc = time.time()
    if disc and now - disc.get("at", 0) < discover_ttl and disc.get("source") == source:
        entries = disc["entries"]
        errors.extend(disc.get("errors", []))
        discovered = False
    else:
        entries = find_run_dirs(roots, max_depth, errors)
        cache["_discovery"] = {
            "at": now, "entries": entries, "source": source,
            "errors": [e for e in errors if e.get("scope") in ("root", "scan")],
        }
        discovered = True
    discover_ms = int((time.time() - t_disc) * 1000)

    if roots and not entries and all(e.get("scope") == "root" for e in errors) and errors:
        return ({"generated_at": now, "error": "every configured root is unreadable",
                 "roots": [str(r) for r in roots], "runs": [], "history": [],
                 "errors": errors}, cache)

    stamp = producer_stamp()
    stale: list[dict] = []
    runs: list[dict] = []
    for e in entries:
        key = str(Path(e["rundir"]).resolve()).lower()
        fp = fingerprint(Path(e["rundir"]))
        if fp == (-1, -1):
            errors.append({"scope": "run", "path": e["rundir"], "error": "run dir vanished"})
            continue
        c = cache.get(key)
        if c and tuple(c["fp"]) == fp and c.get("by") == stamp:
            summary = c["run"].get("summary", {})
            counts = summary.get("counts", {})
            live = counts.get("running", 0) + counts.get("stalled", 0)
            # An in-flight run's SILENCE is itself news (the stall detector
            # measures it), and silence leaves the fingerprint untouched - so a
            # live run must be re-read on a timer even when nothing changed.
            #
            # But the timer is GRADUATED, not fixed. Abandoned runs are the norm
            # on a machine that has hosted 50+ fleets: they sit in `stalled`
            # forever, and at a fixed 15s TTL every one of them would re-run a
            # multi-second ff-status on every aggregate, permanently. So the
            # interval tracks the run's own silence - a lane that wrote 10s ago
            # is polled hard, one silent for three days is polled every 15 min,
            # because no amount of polling will change a verdict that is final.
            if not live or now - c["at"] < refresh_interval(summary, live_ttl):
                runs.append(c["run"])
                continue
        stale.append({**e, "_fp": fp, "_key": key})

    if stale:
        bash = shutil.which("bash") or "bash"
        with futures.ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
            for item, res in zip(stale, ex.map(
                lambda s: read_run(s, bash, timeout), stale)):
                # read_at lets the page tick an in-flight run's clocks forward
                # from a cached read (elapsed + age, silence + age) instead of
                # rendering a frozen number - or forcing a re-read to move it.
                res["read_at"] = now
                cache[item["_key"]] = {"fp": item["_fp"], "at": now, "by": stamp, "run": res}
                runs.append(res)

    runs.sort(key=lambda r: (
        STATE_RANK.index(r.get("summary", {}).get("state", "unknown"))
        if r.get("summary", {}).get("state") in STATE_RANK else 9,
        -(r.get("summary", {}).get("started") or 0),
    ))

    history: list[dict] = []
    if want_history:
        history, herr = load_history(history_limit)
        errors.extend(herr)

    live_runs = [r for r in runs if r.get("summary", {}).get("state") in ("running", "stalled")]
    hits = len(runs) - len(stale)
    doc = {
        "schema": "fleetflow/aggregate/1",
        "version": FF_VERSION,
        "generated_at": now,
        "build_ms": int((time.time() - t0) * 1000),
        "discover_ms": discover_ms,
        "rediscovered": discovered,
        "runs_refreshed": len(stale),
        # Cache effectiveness, surfaced because it is the difference between a
        # 29s build and a 15ms one - and because a hit rate that quietly collapses
        # (a bad fingerprint, a churning run dir) is invisible any other way.
        "cache": {
            "hits": hits, "misses": len(stale), "entries": len(cache) - 1,
            "hit_rate": round(hits / len(runs), 3) if runs else None,
        },
        "roots": [str(r) for r in roots],
        "roots_source": source,
        "totals": {
            "runs": len(runs),
            "live_runs": len(live_runs),
            "repos": len({r["repo"].lower() for r in runs}),
            "lanes": sum(r.get("summary", {}).get("lane_count", 0) for r in runs),
            "tokens_total": sum(r.get("summary", {}).get("tokens_total", 0) for r in runs),
            "history_runs": len(history),
        },
        "runs": runs,
        "history": history,
        "errors": errors,
    }
    return doc, cache


# --------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="ff-aggregate.py", add_help=False,
        description="Discover every fleetflow run under the configured roots and "
                    "emit one aggregate JSON document.",
        epilog="""ROOTS are resolved from the first source that yields any:
  --root (repeatable) > $FLEETFLOW_ROOTS (os.pathsep) > ~/.fleetflow/roots.txt
  > the current git repo. The skill ships no machine-specific default.

EXAMPLES
  ff-aggregate.py | jq '.totals'
  ff-aggregate.py --root X:/Forma --root X:/Roam | jq -r '.runs[].run'
  ff-aggregate.py | jq -r '.runs[] | select(.summary.state=="stalled") | .run'
  ff-aggregate.py --out ~/.fleetflow/aggregate.json --quiet
  ff-aggregate.py --init-roots X:/Forma X:/Roam    # write ~/.fleetflow/roots.txt
""",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", action="append", default=[], metavar="PATH")
    ap.add_argument("--out", metavar="FILE")
    ap.add_argument("--max-depth", type=int, default=6)
    ap.add_argument("--live-ttl", type=int, default=15, metavar="SECONDS")
    ap.add_argument("--discover-ttl", type=int, default=60, metavar="SECONDS")
    ap.add_argument("--timeout", type=int, default=180, metavar="SECONDS")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--no-cache", action="store_true", help="ignore and do not write the cache")
    ap.add_argument("--no-history", action="store_true")
    ap.add_argument("--init-roots", nargs="*", metavar="PATH",
                    help="write ~/.fleetflow/roots.txt with these paths and exit")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("-h", "--help", action="help")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code not in (0, None) else 0

    if a.init_roots is not None:
        FF_HOME.mkdir(parents=True, exist_ok=True)
        dest = FF_HOME / "roots.txt"
        body = ["# fleetflow discovery roots - one path per line, '#' comments.",
                "# Read by ff-aggregate.py; override with $FLEETFLOW_ROOTS or --root.", ""]
        body += [str(Path(p)) for p in a.init_roots]
        dest.write_text("\n".join(body) + "\n", encoding="utf-8")
        err(f"wrote {dest} ({len(a.init_roots)} root(s))")
        print(str(dest))
        return 0

    roots, source = resolve_roots(a.root)
    if not roots:
        err("no roots resolved - pass --root, set $FLEETFLOW_ROOTS, or run --init-roots")
        return 3
    if not a.quiet:
        err(f"roots from {source}: {', '.join(str(r) for r in roots)}")

    cache_path = FF_HOME / "cache" / "aggregate-cache.json"
    cache: dict = {}
    if not a.no_cache and cache_path.is_file():
        try:
            cache = json.loads(cache_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cache = {}

    doc, cache = aggregate(
        roots, source, max_depth=a.max_depth, cache=cache, live_ttl=a.live_ttl,
        discover_ttl=a.discover_ttl, timeout=a.timeout, workers=a.workers,
        want_history=not a.no_history)

    if not a.no_cache:
        try:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = cache_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(cache), encoding="utf-8")
            os.replace(tmp, cache_path)
        except OSError as e:
            err(f"cache not persisted: {e}")

    text = json.dumps(doc, indent=None)
    if a.out:
        # tmp + replace, same torn-write guard ff-status uses: a reader polling
        # this file must never catch it half-written.
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, out)
    else:
        print(text)

    if not a.quiet:
        t = doc["totals"]
        err(f"{t['runs']} run(s) across {t['repos']} repo(s), {t['live_runs']} live, "
            f"{doc['runs_refreshed']} refreshed in {doc['build_ms']}ms")
        for e in doc["errors"]:
            err(f"skipped {e.get('path')}: {e.get('error')}")
    if doc.get("error"):
        return 7
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
