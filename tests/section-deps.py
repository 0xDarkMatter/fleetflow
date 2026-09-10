#!/usr/bin/env python3
"""Derive the section dependency map for tests/run.sh, and check the copy
embedded in it is current.

WHY THIS EXISTS. run.sh is one flat ~3400-line bash script whose sections share
fixtures built by earlier sections ($REPO's r1 journal, the r5/r6/r7 stall runs,
the waves repo, the ff-plan packet repo, ...). A section is therefore NOT
independently runnable in general, and `--only <regex>` must pull in whatever
built what the selected sections read. That prerequisite map is DERIVED here
rather than hand-written, because a hand-written one rots the first time
somebody adds a fixture and a rotten map turns `--only` into a false green.

THE DERIVATION. For each section: WRITES = shell vars it assigns, functions it
defines, and run dirs it creates or spawns into; READS = vars it references,
functions it calls, run dirs it names. A section depends on the most recent
EARLIER section that writes something it reads. That "most recent writer" step
is only sound because every writer of a run dir also reads it (it names the dir
to write it), so consecutive writers chain and the transitive closure recovers
the whole history of a shared fixture - which is what count-sensitive
assertions ("r1 has exactly 3 started records") actually depend on.

The map is conservative by construction: a spurious edge costs seconds in a
subset lane, a missing edge costs a wrong answer. When in doubt this over-links.

EXIT CODES (Skill Resource Protocol): 0 ok, 2 usage, 10 map is stale.

EXAMPLES
  python tests/section-deps.py --emit     # print the table run.sh should embed
  python tests/section-deps.py --check    # exit 10 if run.sh's copy is stale
  python tests/section-deps.py --report   # human-readable deps per section
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_SH = os.path.join(HERE, "run.sh")

# Fixtures built by the ungated preamble, or otherwise not a section's to own.
# The preamble always runs in every mode, so nothing needs to depend on it.
PREAMBLE = {
    "$PASS", "$FAILN", "$HERE", "$S", "$TMP", "$REPO", "$PKT", "$HOME",
    "$REAL_STORE", "$REAL_STORE_BEFORE", "$PATH", "$BASH_SOURCE", "$PWD",
    "$RANDOM", "$IFS", "$LINENO", "$SECONDS", "$OSTYPE", "$EOF", "$PY",
    "$PKT2",
}

RE_BANNER = re.compile(r"^# (---|===) ")
RE_SEC = re.compile(r"^if __sec ([a-z0-9-]+); then$")
RE_ASSIGN = re.compile(r"(?<![A-Za-z0-9_${.-])([A-Z][A-Z0-9_]{1,})=(?!=)")
RE_REF = re.compile(r"\$\{?([A-Z][A-Z0-9_]{1,})")
RE_FUNCDEF = re.compile(r"^\s*([a-z_][a-z0-9_]*)\(\)\s*\{")
RE_RUN = re.compile(r"--run\s+([A-Za-z0-9_.-]+)|\.fleetflow/([A-Za-z0-9_.-]+)")
# A command that brings a run dir into existence or appends to it. Anything
# else that merely names the dir is a read.
RE_RUNWRITE = re.compile(r"ff-spawn\.sh|ff-import\.sh|ff-chip\.sh open|mkdir|>>|>\s|:\s*>")


# The selection machinery carries `# === ... ===` markers of its own. They are
# not section banners, and the block is part of the ungated preamble, so it is
# skipped wholesale rather than pattern-matched around.
MACHINERY_OPEN = "# === section selection: the fast iteration lane"
MACHINERY_CLOSE = "# === end section selection"


def split_sections(lines):
    """-> [(slug, first_line_no, [body lines])], element 0 always the preamble."""
    secs = [("preamble", 1, [])]
    pending = None
    in_machinery = False
    for i, line in enumerate(lines, 1):
        if line.startswith(MACHINERY_OPEN):
            in_machinery = True
        if in_machinery:
            secs[-1][2].append(line)
            if line.startswith(MACHINERY_CLOSE):
                in_machinery = False
            continue
        m = RE_SEC.match(line)
        if m:
            pending = m.group(1)
            continue
        if RE_BANNER.match(line):
            secs.append((pending or "UNGATED-SECTION-%d" % i, i, []))
            pending = None
        secs[-1][2].append(line)
    return secs


def analyse(secs):
    out = []
    for slug, start, body in secs:
        writes, reads = set(), set()
        for line in body:
            if line.lstrip().startswith("#"):
                continue
            stripped = line.split(" #", 1)[0]
            for m in RE_ASSIGN.finditer(stripped):
                writes.add("$" + m.group(1))
            for m in RE_REF.finditer(stripped):
                reads.add("$" + m.group(1))
            m = RE_FUNCDEF.match(stripped)
            if m:
                writes.add(m.group(1) + "()")
            for m in RE_RUN.finditer(stripped):
                key = "run:" + (m.group(1) or m.group(2))
                reads.add(key)
                if RE_RUNWRITE.search(stripped):
                    writes.add(key)
        out.append({"slug": slug, "start": start, "w": writes, "r": reads,
                    "body": body})
    # Function calls are only resolvable once every definition is known.
    defined = {f for s in out for f in s["w"] if f.endswith("()")}
    for s in out:
        text = "\n".join(l for l in s["body"] if not l.lstrip().startswith("#"))
        for fn in defined:
            if fn in s["w"]:
                continue
            if re.search(r"(^|[\s;&|(`$])" + re.escape(fn[:-2]) + r"(\s|$|;|\))",
                         text, re.M):
                s["r"].add(fn)
    return out


def deps_for(sections):
    """-> {slug: [direct prerequisite slugs, in file order]}"""
    result = {}
    for idx, sec in enumerate(sections):
        if idx == 0:
            continue
        need = set()
        for tok in sec["r"]:
            if tok in PREAMBLE or tok.startswith("$FLEETFLOW"):
                continue
            if tok.startswith("$") and tok in sec["w"]:
                continue
            for j in range(idx - 1, -1, -1):
                if tok in sections[j]["w"]:
                    if j > 0:
                        need.add(j)
                    break
        result[sec["slug"]] = [sections[k]["slug"] for k in sorted(need)]
    return result


def table(deps):
    return "\n".join("%s:%s" % (s, ",".join(d)) for s, d in deps.items())


def embedded(lines):
    """The __DEPS heredoc currently baked into run.sh, or None."""
    try:
        a = lines.index("__DEPS=$(cat <<'DEPTABLE'")
        b = lines.index("DEPTABLE", a)
    except ValueError:
        return None
    return "\n".join(lines[a + 1:b])


def main(argv):
    modes = [a for a in argv[1:] if a in ("--emit", "--check", "--report")]
    if len(modes) != 1 or len(argv) != 2:
        sys.stderr.write(__doc__ or "")
        return 2
    lines = open(RUN_SH, encoding="utf-8").read().split("\n")
    secs = split_sections(lines)
    ungated = [s for s, _, _ in secs if s.startswith("UNGATED-SECTION")]
    if ungated:
        sys.stderr.write("section banner with no `if __sec <slug>; then`: %s\n"
                         % ", ".join(ungated))
        return 10
    slugs = [s for s, _, _ in secs]
    dupes = {s for s in slugs if slugs.count(s) > 1}
    if dupes:
        sys.stderr.write("duplicate section slug: %s\n" % ", ".join(sorted(dupes)))
        return 10
    deps = deps_for(analyse(secs))
    want = table(deps)
    if modes[0] == "--emit":
        print(want)
        return 0
    if modes[0] == "--report":
        for slug, d in deps.items():
            print("%-28s %s" % (slug, ", ".join(d) or "-"))
        return 0
    got = embedded(lines)
    if got is None:
        sys.stderr.write("run.sh has no __DEPS table to check\n")
        return 10
    if got.strip() != want.strip():
        wl, gl = want.split("\n"), got.split("\n")
        sys.stderr.write("run.sh __DEPS is stale - regenerate with "
                         "`python tests/section-deps.py --emit`\n")
        for line in sorted(set(wl) ^ set(gl)):
            sys.stderr.write("  %s %s\n" % ("want" if line in wl else "have", line))
        return 10
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
