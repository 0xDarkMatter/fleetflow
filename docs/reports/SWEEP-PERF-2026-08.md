# `ff-sweep --list` is slow because it walks every worktree twice — measurement and proposal

**Status:** proposal (2026-08-12) · measured on this machine, lane
`fleetflow/sweepperf/perf`. Nothing here is landed; `scripts/ff-sweep.sh` is
unchanged. Every number below was taken, not estimated; where a figure is a
projection it says so.

Binding context: [ADR-020](../adr/ADR-020-sweep-reclaims-only-archived-and-landed.md)
owns the safety predicate and none of this changes it.

---

## 1. Summary

A machine-wide `ff-sweep.sh --list` was timed end to end at **717 s (12 min)**
over 91 run dirs — and that is with a filesystem cache already warmed by this
lane's earlier passes. The original cold observation was killed at 200 s without
finishing.

Of that, **31.7 s is discovery** (timed separately per root) and the rest is the
per-run loop. Attributing the per-run loop stage by stage:

| Stage | Attributed | Share of per-run | What it produces |
|---|---:|---:|---|
| `du -s` (`dir_bytes`) | **568.4 s** | 60.6 % | the `bytes` column |
| `find -printf '%T@'` (age) | **306.7 s** | 32.7 % | `age_s`, and the `--older-than` filter |
| `classify()` git + jq per lane | 45.0 s | 4.8 % | **the verdict** |
| `archived_p` (`jq -s` history per run) | 9.8 s | 1.0 % | the `archived` flag |
| incremental `jq -nc` row accumulation | 7.4 s | 0.8 % | the JSON array |
| attributed total | 937.3 s | | |

The attribution sums higher than the 717 s end-to-end run, which is expected and
does not undermine it: the instrumentation harness adds its own `date +%s%N`
forks per stage per run, and it runs `du` and the recursive `find` back to back
over the same trees under different cache warmth than the real script sees. Read
the column as **shares, not as a total**.

**`du` and the age walk are 93.3 % of the per-run work — ~89 % of the whole
command. Both are full recursive tree walks, and both fill columns the safety
predicate never reads.** The git and jq work that decides the verdict is 4.8 %.

The recommendation is four phases, in this order. The first three cache nothing
and change no predicate input; only the fourth introduces a cache, and the only
thing it caches is a byte count.

| Phase | Change | Removes |
|---|---|---:|
| P1 | discovery reuses the dashboard's already-warm `_discovery` entry | −31.6 s |
| P2 | the recursive age walk runs only under `--older-than` | −306.7 s |
| P3 | fork elimination in `classify` / `archived_p` / row building | ~−36 s of the 62.2 s those three stages cost |
| P4 | `bytes` cached (and a `--no-size` escape hatch) | −568.4 s |

**Measured end state, all four phases in effect (P4 as `--no-size`): 43.7 s for
all 91 run dirs**, down from a measured 717 s — a **16×** reduction, with
byte-identical output on every field checked. The only cached data in that run
were run-dir *paths* (P1); every verdict was computed live. With P4 as a size
cache instead of a skip, a cold run pays `du` once and a warm one lands in the
same 43.7 s.

**I recommend explicitly NOT caching the classification**, which is what the
brief pointed at. Reasons in §6 — the short version is that it is 4.8 % of the
cost and the one datum whose staleness can delete work.

---

## 2. Method

The machine has **10 roots** in `~/.fleetflow/roots.txt`, **91 run dirs** (not
~50) across **39 distinct repo/worktree checkouts**, holding **156 lane
worktrees** in total (32 of the 91 runs still have lanes on disk).

The shipped `scripts/ff-sweep.sh --list` was first timed end to end, unmodified,
machine-wide: **717 s**. Each stage of its per-run loop was then re-implemented
verbatim in an instrumentation harness and timed per run dir with `date +%s%N`,
over all 91 dirs, to attribute that time. Discovery was timed per root. Platform
constants were timed at 50–200 iterations. Prototypes were then A/B'd against
the real script on two repos and their output diffed field-by-field.

The end-to-end number is the one to trust for "how slow is it"; the stage
attribution is the one to trust for "where does it go".

Scratch harnesses lived in an uncommitted `.ffperf/` directory in this lane and
are reproducible from §9.

---

## 3. Measurements

### 3.1 Discovery — 31.7 s, and 75 % of it is one directory tree

| Root | Time | `.fleetflow` dirs found |
|---|---:|---:|
| X:/Forma | 513 ms | 2 |
| X:/Evolution7 | 1 846 ms | 12 |
| X:/Roam | 1 383 ms | 5 |
| X:/Homelab | 1 656 ms | 4 |
| X:/DnD | 1 513 ms | 2 |
| X:/Maplab | 272 ms | 1 |
| X:/Lab | 1 142 ms | 0 |
| **X:/Forge** | **23 610 ms** | 13 |
| X:/Benching | 3 023 ms | 2 |
| X:/Agents | 441 ms | 0 |

`X:/Forge` enumerates **115 038 directories** at `-maxdepth 7` after the prune
list — **93 608 of them under `X:/Forge/Axiom/data`** alone. The walk is not
slow because of fleetflow; it is slow because one unrelated data tree sits under
a configured root.

Things that do *not* fix it:

- Adding `-prune` after the `.fleetflow` `-print` (so `find` stops descending
  into run dirs and their worktrees): 1 876 → 1 194 ms on Evolution7, but
  21 409 → 21 336 ms on Forge. Free, worth taking, not the answer.
- Lowering `-maxdepth`: 7 → 5 takes Forge from 21.4 s to 6.8 s and finds the
  same 13 dirs *today*, but depth 5 cannot reach
  `<root>/<group>/<repo>/.claude/worktrees/<slug>/.fleetflow`, which is a real
  shape on this box (`X:/Forma/forma/slack`). Rejected as unsafe coverage loss.

What does fix it: **the dashboard has already done this walk.**
`ff-aggregate.py` caches discovery under `_discovery` in
`~/.fleetflow/cache/aggregate-cache.json`, `ff-serve.py` persists that file on
every rebuild, and the `fleetflow` Process Compose service rebuilds on request.
Measured against the live walk at the same moment:

| Source | Time | Entries |
|---|---:|---:|
| `find` over 10 roots | 31 754 ms | 91 |
| `_discovery` from the dashboard cache | **132 ms** | 91 — **identical set** |

240×, and the entry shape (`rundir`, `run`, `repo`, `repo_label`, `root`) is
exactly what `ff-sweep` needs. ADR-020 already states the goal that "the sweep
and the dashboard cannot disagree about which repos exist"; reading the same
cache makes that structural instead of aspirational.

### 3.2 Per-run stages — attribution over 91 run dirs

Read these as shares of the per-run loop, not as a total (see §1 on why the
attribution sums above the 717 s end-to-end figure). Totals across all 91 dirs
(`n=91`):

```
du=568.4s   newest=306.7s   classify=45.0s   archived=9.8s   jqrow=7.4s
```

The cost is extraordinarily concentrated: **the top 5 run dirs account for
772.6 s of the 875.1 s of `du`+age — 88 %.**

| Total | `du` | age | classify | lanes | run dir |
|---:|---:|---:|---:|---:|---|
| **454 968 ms** | 224 361 | 225 599 | 4 801 | 19 | `X:/Evolution7/Payload/.fleetflow/wkit` |
| 29 153 ms | 26 089 | 2 168 | 729 | 4 | `X:/Roam/ATDW-MCP/.claude/worktrees/feed-phase0/.fleetflow/phase2` |
| 15 305 ms | 13 387 | 1 279 | 452 | 2 | `X:/Roam/Dispatch/.fleetflow/m1` |
| 9 509 ms | 4 318 | 4 337 | 651 | 3 | `X:/Evolution7/Ledger/.fleetflow/billqa` |
| 6 209 ms | 2 385 | 2 554 | 1 076 | 5 | `X:/Evolution7/Ledger/.fleetflow/invhub` |

**One run dir — `Payload/.fleetflow/wkit`, 19 lanes each holding a full
monorepo checkout — accounts for 455 s by itself, 49 % of all per-run cost.**
That one directory is on its own more than twice the 200 s budget that killed
the original run.

Note the symmetry in that row: `du` 224 s and the age walk 226 s. They are the
same walk, done twice, for two different columns.

### 3.3 Platform constants — forks are the unit of cost here

Windows/Git Bash, measured on this box:

| Operation | Cost |
|---|---:|
| pure-bash string op (`${p##*/}`) | **0.27 ms** |
| bare command substitution of a builtin (fork, no exec) | **11.6 ms** |
| one external command (`basename`) | 25 ms |
| one `git` invocation | 41 ms |
| one `jq` invocation (trivial program) | 41 ms |
| `jq -s` over the 207-record `history.jsonl` | 59 ms |
| two-stage pipeline (`printf … \| grep -c`) | 51 ms |

Two consequences:

1. A fork costs ~43× a bash string operation. `basename`/`dirname`/`grep -c`/
   `awk`/`paste` inside a per-lane loop are not free ergonomics; at 156 lanes
   they are the whole of `classify`'s 45 s.
2. **`archived_p` is not the O(runs × history) problem it looks like.** Of its
   59 ms, 41 ms is the bare `jq` spawn and only ~18 ms is parsing 207 records.
   At 91 runs it is 9.8 s — 1 % of the total. Worth fixing because it is nearly
   free to fix, but it was never the cause.

---

## 4. Where the hypothesis held and where it did not

Shares are of the per-run loop, except discovery which is of the 717 s
end-to-end run.

| Suspect (from the brief) | Verdict |
|---|---|
| 1. `dir_bytes()` → `du -s` dominates | **Confirmed — 60.6 %**, the single largest item |
| 2. the `find -printf` age walk is a second full tree walk | **Confirmed — 32.7 %**; together with `du`, 93.3 % |
| 3. three git invocations per lane, spawn is expensive on Windows | **Real but small — 4.8 %.** The spawn-cost premise is right (41 ms each); the count is not the bottleneck |
| 4. `archived_p` is O(runs × history) | **Wrong at this scale — 1.0 %.** Dominated by spawn, not by the 207-record slurp |
| 5. `find_run_dirs()` discovery | **Real — 31.7 s, 4.4 % of the command**, and 75 % of *it* is one unrelated data tree |

The correction that matters: the expensive work is not the work that computes
the verdict. It is the two cosmetic columns beside it.

---

## 5. Proposal

Four phases, independently landable, in decreasing safety-triviality.

### P1 — discovery reuses the dashboard's `_discovery` (−31.6 s)

When no `--repo` is given and no `--root` overrides are passed, read
`~/.fleetflow/cache/aggregate-cache.json`. Use its `_discovery.entries` when

- the file parses, and
- `._discovery.source` equals the roots source `resolve_roots()` just resolved, and
- `now - ._discovery.at < FF_SWEEP_DISCOVER_TTL` (propose 900 s default, with a
  `--rediscover` flag and `--discover-ttl N` to override).

Otherwise fall back to the current `find` walk — and add `-prune` after the
`.fleetflow` `-print` in it, so the fallback stops descending into run dirs and
their worktrees.

Paths in that cache are Windows-separated (`X:\Forma\…`); normalise with
`gsub("\\\\";"/")` in the same `jq` that reads them. This is a `jq -r` capture:
`| tr -d '\r'` per the AGENTS.md landmine.

Cost: ~25 lines, one flag, two `--help` lines. It introduces a *read-only*
coupling to a file `ff-aggregate.py` owns — worth a comment at both ends naming
`_discovery` as the shared shape, and a defensive read (any parse failure falls
through to the walk).

### P2 — the recursive age walk runs only under `--older-than` (−306.7 s)

`age_s` is consumed in exactly two places: the `--older-than` filter, and a
display field in `--json`.

- With `--older-than`: keep the exact recursive `find -printf '%T@'`. It gates
  eligibility, so it must not be approximated (see §7).
- Without it (the default, and every `--list`): use
  `find "$rundir" -maxdepth 1 -type f -printf '%T@'` — the newest file *directly
  in the run dir*.

Sampled on 8 run dirs, the shallow and recursive answers were identical to the
second, which is expected: a run's journal, transcripts, `.result.json` and
`.err` files are written after any file inside a lane. Mark the field
`age_s_approx` in the JSON, or document it, rather than pretending it is exact.

Cost: ~4 lines.

### P3 — fork elimination (~−36 s of the 62.2 s `classify`+`archived_p`+row cost)

P2 and P3 together were what took `--repo X:/Evolution7/BrandKit` (5 runs,
~50 lanes, small trees) from 16.6 s to 6.7 s — 2.5× on a repo where neither `du`
nor the age walk is expensive, i.e. the win here is purely fork count.

Six changes, all mechanical:

1. **Read `history.jsonl` once.** One `jq -r` emitting lowercased
   `repo<TAB>run` keys to a sorted temp file before the loop; `archived_p`
   becomes `grep -Fxq`. 91 `jq -s` spawns → 1.
2. **Accumulate rows as NDJSON**, one `jq -nc` append per run, and a single
   `jq -s .` at the end. Removes the `--argjson R "$ROWS"` re-serialisation of
   the whole growing array on every iteration (O(n²) in array size).
3. **One `jq` per run instead of two** for `manifest.base` and the in-flight
   lane count: `jq -n --slurpfile m … --slurpfile j …` reads both files in one
   spawn.
4. **Memoise the base-ref check per repo.** `git show-ref --verify` currently
   runs once per *run*; repos hold up to 12 runs on this box.
5. **`git status --porcelain=v2 --branch` replaces `status --porcelain` +
   `rev-parse HEAD`.** The `# branch.oid <sha>` header carries HEAD, so 3 git
   invocations per lane become 2. Measured on a real lane: v1 `--porcelain`
   55 ms, v2 `--porcelain=v2 --branch` 68 ms — so v2 costs 13 ms more but
   removes a 41 ms `rev-parse`, netting ~28 ms per lane.
6. **Parse that output in pure bash** — a `while IFS= read -r line; case` loop —
   instead of `printf | grep -c` ×2, `awk`, and `paste`. Same for
   `basename`/`dirname`: `${wt##*/}`, `${rundir%/.fleetflow/*}`.

⚠️ **The v1→v2 status format change is the one place in this proposal that can
silently break the safety predicate.** In `--porcelain=v2` the header lines
start with `#`, so today's `grep -c '^[^?]'` (which means "tracked change" in v1)
would count `# branch.oid` as a tracked modification. The correct v2 patterns
are: tracked = lines starting with `1 `, `2 `, or `u `; untracked = `? `;
headers = `#`. Also handle `branch.oid = (initial)` (unborn HEAD) by treating the
lane as *unmerged*, i.e. keeping it.

Both verified directly on a fixture repo with one tracked modification and one
untracked file: `grep -c '^[^?]'` (the v1 rule) counts **3** on v2 output where
the correct answer is **1**, because it swallows the two `#` header lines; and an
unborn HEAD really does print `# branch.oid (initial)`.

Cost: ~35 lines rewritten inside `classify()` plus the history preload. This is
the highest-regression-risk phase and the only one that touches predicate code.

### P4 — cache `bytes`, and add `--no-size` (−568.4 s)

`du -s` is irreducible: it is a full walk by definition, and 60.6 % of the per-run cost.
Two mitigations, both cheap:

- `--no-size`: skip `du` entirely, print `-` in the bytes column and omit the
  "N on disk" roll-up. Immediate, zero risk, useful on its own.
- A size cache at `~/.fleetflow/cache/sweep-sizes.json`, keyed on the resolved
  lowercased run-dir path, holding `{fp, by, bytes, at}` where `fp` is the
  ff-aggregate-style non-recursive `(child count, newest child mtime)` and `by`
  is a producer stamp (`FF_VERSION` + `ff-sweep.sh` mtime:size), exactly as
  `producer_stamp()` does. On a miss, `du` and store.

A stale hit prints a wrong number of bytes. That is the entire blast radius —
see §7.

### P5 — optional hardening, independent of any cache

`--reclaim` currently classifies every run at the top of the walk and then
removes eligible ones in a second pass. On a machine-wide sweep those two
moments are minutes apart. Re-run `classify()` for each candidate immediately
before invoking `ff-clean`, and skip (with a stderr line) if the verdict is no
longer eligible. Cost: n_eligible × ~90 ms per lane — negligible next to the
`rm -rf` that follows. This closes an existing TOCTOU window and is the
mechanism that would make any future verdict cache safe.

---

## 6. What I recommend against: caching the classification

The brief points at `ff-aggregate.py`'s cache as the house style and offers the
premise that *"a finished, archived run's classification is immutable, which is
the property a cache should exploit."* Having measured it, I recommend not
doing this. Three reasons.

**(a) It is 4.8 % of the cost.** `classify()` attributes to 45.0 s of the 937 s
of per-run work. After P1–P3 it is most of what remains, and what remains is
43.7 s for the entire machine — for a housekeeping command the operator runs
occasionally. Caching it buys seconds and costs a permanent safety obligation.

**(b) The precedent's fingerprint is not sound for this reader.**
`ff-aggregate.fingerprint()` is a *non-recursive* `scandir` of the run dir, and
its own docstring says why that is correct there: "Every signal ff-status reads
— journal, events streams, transcripts, artifacts, stderr — is a file directly
in here." That is true of `ff-status`. It is false of `ff-sweep`. The sweep's
predicate reads state that lives **inside the lane worktrees**: a tracked
modification, a new commit, a new untracked file. None of those touch the run
dir's direct children, so a cache keyed that way would keep serving
`reclaimable` for a run whose lane someone edited five minutes ago. Making the
fingerprint see inside the worktrees means either a recursive walk — which is
precisely the `du`/age cost we are removing, so the cache pays for itself in the
thing it was meant to avoid — or a per-lane `git status`, which *is* the
classification.

**(c) The immutability premise holds for two of its three conjuncts, not the
third.** `reclaimable` is `archived ∧ every-lane-landed ∧ no-tracked-mods ∧
no-untracked ∧ no-in-flight-lane`.

- *Archived* is monotone: `history.jsonl` is append-only (ADR-011), and an
  archived run never becomes unarchived.
- *Landed* is monotone for a fixed commit: once `merge-base --is-ancestor` is
  true it stays true (barring a base reset).
- *"This worktree has zero tracked modifications, zero untracked files"* is
  **not immutable at all.** A lane worktree is a live checkout on disk. An
  editor, an agent, a `git checkout`, a build that drops an artifact — any of
  these flips it, at any moment, without touching the run dir.

That third conjunct is exactly what decides deletion, and it is the one that
moves. So the property the cache would be exploiting is not the property that
makes the run safe to delete.

**This was not hypothetical — it happened during the measurement.** The
prototype's machine-wide pass and the shipped script's baseline ran about an
hour apart, and they disagreed on exactly one of 91 runs:
`X:/Forge/claude-bus/.fleetflow/raven2-p1` read `active` in the first and
`holds-work` in the second. Neither was wrong. At the first reading one lane had
a `started` with no `result` (`age_s` was 20 s — the run was live); by the second
all 11 lanes had returned and 2 were unmerged. Re-running the prototype on that
directory afterwards reproduces the shipped verdict exactly — and by then a third
change had landed on top, `integrate` going from `unmerged` to `modified`.

One run dir changed classification **twice in an hour, entirely from activity
inside its lane worktrees**, without the run dir's own direct children being the
signal. A verdict cache keyed on a non-recursive fingerprint would have served
the first answer through all of it.

(Both states here are `KEPT` states, so nothing was at risk. The point is the
mutation rate, not this run's outcome.)

---

## 7. Safety argument

The constraint is: *a cache must never cause a run to be classified
`reclaimable` from stale data.* Taking each phase:

**P1 (discovery) — the only cached datum is which directories exist.** It is not
an input to any verdict. Stale in either direction is safe:

- A run created since the cache was written is **missing** from the list. It is
  therefore not reported and not reclaimed — strictly conservative, and it fails
  toward keeping.
- A run dir already removed is **listed**; the existing `[ -d "$rundir" ]` /
  `[ -f journal.jsonl ]` guards skip it.
- A run dir listed under a path that has since been *reused* by a different run
  is still fully classified live, because P1 caches nothing but the path.

It cannot promote anything to `reclaimable`, because it decides nothing.

**P2 (age) — the approximation is confined to the case where age decides
nothing.** The direction matters and is the reason for the split. The shallow
age reads the newest file *directly in* the run dir, which is a lower bound on
the true recursive newest ⇒ an **over**-estimate of the run's age ⇒ a run would
pass `--older-than` that should not have. That is the unsafe direction, so
`--older-than` keeps the exact recursive walk. Without `--older-than`, age gates
nothing and is display-only.

**P3 (fork elimination) — no cache, and no change to any predicate input.** It
computes the same facts from the same git and jq output with fewer processes.

Machine-wide, the prototype and the shipped script agreed on **90 of 91
verdicts**, and the single difference was a live run that genuinely changed state
between the two passes — re-measured at the same moment, it agrees too, so the
real figure is 91/91 (the case is worth reading in §6: it is also the best
evidence for why the classification must not be cached).

Verified per-field on two repos: on `X:/Evolution7/Ledger` (12 runs, 26 lanes) and
`X:/Evolution7/BrandKit` (5 runs, ~50 lanes) the prototype's verdict, lane
counts, `archived` flag, `detail` string **and byte counts diffed identical**
against the shipped script. Those 17 runs cover `reclaimable` (14),
`landed-untracked` (2 — including the exact untracked paths printed in
`detail`) and `holds-work` (1). They do **not** cover `active`, and no repo on
this box produced one in the A/B set, so the in-flight path was exercised only
by the machine-wide prototype run (5 `active` runs, verdicts matching) and by
the existing test fixtures — worth an explicit assertion when this lands.

The one genuine hazard is the v1→v2 porcelain parse, flagged in P3. It is
covered by the existing ADR-020 fixture in `tests/run.sh`, which builds lanes
that are landed, unmerged, tracked-modified, and untracked-only, and asserts
that `holds-work` is never `eligible`.

**P4 (size cache) — the cached datum is a byte count.** `bytes` is read by: the
TSV/JSON `bytes` column, `TOT_BYTES`, and `REC_BYTES` (the "N on disk / N
reclaimable" stderr line). It is **not** read by `classify()`, not by the
`eligible` test, not by `--older-than`, and it is not passed to `ff-clean`. A
stale size prints a wrong number and nothing else.

**Nothing in this proposal caches a verdict, an archived flag, a lane count, or
any git fact.** Every input to `eligible` is recomputed from live `git` on every
invocation. With P5 it is recomputed a second time, immediately before deletion.

---

## 8. Cost of landing

| Phase | LoC | Risk | Notes |
|---|---:|---|---|
| P1 | ~25 + 2 help lines | low | new read-only coupling to `aggregate-cache.json`; defensive read + fallback |
| P2 | ~4 | low | `age_s` becomes approximate on the default path — document it |
| P3 | ~35 | **medium** | rewrites predicate-adjacent parsing; the v2 format change is the trap |
| P4 | ~30 + 1 flag | low | new cache file `~/.fleetflow/cache/sweep-sizes.json` |
| P5 | ~10 | low | pure hardening |

Suggested test additions. The existing gate is green on this lane as written
(`bash tests/run.sh` — **313 passed, 0 failed**) and every one of those assertions
still applies unchanged:

1. A lane holding **both** a tracked modification and an untracked file, asserting
   `holds-work` — this is the case a wrong v2 pattern would flip.
2. A fixture with an unborn-HEAD lane (`branch.oid (initial)`), asserting it reads
   `unmerged`/kept, never `reclaimable`.
3. `--older-than` exactness: touch a file **deep inside** a lane worktree, assert
   the run is excluded by `--older-than 1` (pins that P2 did not approximate the
   gating path).
4. A poisoned discovery cache (a `_discovery` entry naming a run dir that holds
   work) yields no eligible row — pins that P1 caches paths only.
5. `--no-size` produces the same verdicts as a sized run.

New flags need `--help` `EXAMPLES` entries per the Skill Resource Protocol.

**Considered and not proposed: parallelising the per-run loop.** Bash job control
in a safety-critical script, with interleaved stderr and result ordering to
manage, is real complexity. `ff-aggregate.py` gets away with it because Python
hands it a `ThreadPoolExecutor`; the bash equivalent is background jobs plus
per-run temp files plus a join. It would be worth maybe another 4–6× on the
43.7 s residual, but that residual is already a housekeeping command's worth of
time, so it is not where the next effort belongs. Revisit only if the run-dir
count grows several-fold.

---

## 9. Reproducing

```bash
# machine-wide baseline - measured 717 s on this box
time bash scripts/ff-sweep.sh --list

# discovery, live walk vs the dashboard's cached answer
time bash -c 'while read -r r; do find "$r" -maxdepth 7 -type d -name .fleetflow -print; done < <(awk "NF && \$0 !~ /^#/" ~/.fleetflow/roots.txt)' | wc -l
time jq -r '._discovery.entries[]? | .rundir' ~/.fleetflow/cache/aggregate-cache.json | tr -d '\r' | wc -l

# per-repo A/B (the two used above)
time bash scripts/ff-sweep.sh --repo X:/Evolution7/Ledger   --list   # 29.0 s
time bash scripts/ff-sweep.sh --repo X:/Evolution7/BrandKit --list   # 16.6 s

# platform constant that explains P3
time bash -c 'for i in $(seq 200); do x="$(printf a)"; done'         # ~11.6 ms/fork
```

Headline A/B. Every prototype row was diffed field-by-field against the shipped
script and came back identical (§7).

| Target | shipped | prototype | phases exercised |
|---|---:|---:|---|
| `--repo X:/Evolution7/Ledger` (12 runs, 26 lanes, 1.6 GB) | 29.0 s | **14.1 s** | P2+P3 (`--repo` skips discovery; `du` still run) |
| … same, with `du` stubbed out | — | **5.1 s** | P2+P3+P4 |
| `--repo X:/Evolution7/BrandKit` (5 runs, ~50 lanes, small trees) | 16.6 s | **6.7 s** | P2+P3 |
| machine-wide, 91 run dirs | **717 s** (measured end-to-end, incl. `du`) | **43.7 s** | P1+P2+P3+P4-as-`--no-size` |

Verdict distribution, shipped run: 68 `reclaimable`, 16 `holds-work`,
3 `landed-untracked`, 4 `active`. The prototype reproduced it (see §7 on the one
run that legitimately moved between passes).

Gate: `bash tests/run.sh` → **313 passed, 0 failed** on this lane.

## See also

- [ADR-020](../adr/ADR-020-sweep-reclaims-only-archived-and-landed.md) — the
  safety predicate this proposal does not touch
- [ADR-011](../adr/ADR-011-archive-before-remove.md) — why `archived` is monotone
- `scripts/ff-aggregate.py` — `producer_stamp()` / `fingerprint()`, the cache
  precedent, and the reason its fingerprint does not transfer to this reader
