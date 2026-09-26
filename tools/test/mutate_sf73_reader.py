#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-73 slice 3, the DairyCore FIELD_REPORT reader: do the bars catch what they claim?

Each mutation breaks one clause of SF-73 Implementation v1.1 in shipped code and
requires one of the SF-73 bars to go RED with named FAIL rows. A bar that dies on a
Lua error instead is recorded CRASH, which is not a kill (a crash is unattributable).
Every target is restored in a finally and proved by sha256.

Run from tools/test:  py -u mutate_sf73.py
"""
import hashlib
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FILES = {
    "dcm": os.path.join(ROOT, "src", "DairyCoreManager.lua"),
}
BARS = ["SF-73-feed_field_report_reader_spec_test.lua"]
TICK, CROSS = "✓", "✗"

MUTATIONS = [
    ("approaching-counts-balanced", "dcm",
     [("                    if rel[n] ~= \"IDEAL\" and rel[n] ~= \"ABOVE\" then balancedAll = false end\n",
       "                    if rel[n] == \"BELOW\" then balancedAll = false end\n", 1)],
     "APPROACHING counts as balanced", "B3"),
    ("footprint-accepted", "dcm",
     [("    if not ok or type(rel) ~= \"table\" or rel.scope ~= \"FIELD_REPORT\" or type(rel.nutrients) ~= \"table\" then\n",
       "    if not ok or type(rel) ~= \"table\" or type(rel.nutrients) ~= \"table\" then\n", 1)],
     "a vehicle FOOTPRINT decides the herd", "B7"),
    ("undetermined-not-legacy", "dcm",
     [("        if kind ~= \"BELOW\" and kind ~= \"APPROACHING\" and kind ~= \"IDEAL\" and kind ~= \"ABOVE\" then\n"
       "            return nil   -- UNDETERMINED or missing: the whole legacy test decides\n        end\n", "", 1)],
     "an incomplete record is used instead of the whole legacy test", "B5, B6"),
]


def read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def run_suite():
    proc = subprocess.run([os.environ.get("NODE", "node"), "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.stdout + proc.stderr


def bar_results(out):
    res = {}
    lines = out.splitlines()
    for i, line in enumerate(lines):
        for bar in BARS:
            if bar in line and (line.startswith(TICK) or line.startswith(CROSS)):
                rows, crash = [], "Lua error" in line
                j = i + 1
                while j < len(lines) and lines[j].startswith("    "):
                    if lines[j].strip().startswith("FAIL "):
                        rows.append(lines[j].strip())
                    j += 1
                res[bar] = (line[0], rows, crash)
    return res


def pattern(old):
    return "\r?\n".join(re.escape(part) for part in old.split("\n"))


def main():
    originals = {k: read_bytes(p) for k, p in FILES.items()}
    digests = {k: hashlib.sha256(b).hexdigest() for k, b in originals.items()}
    texts = {k: b.decode("utf-8") for k, b in originals.items()}
    for k, p in FILES.items():
        print("target : %-44s sha256 %s" % (os.path.relpath(p, ROOT), digests[k]))
    base = bar_results(run_suite())
    for bar in BARS:
        sym = base.get(bar, (None,))[0]
        if sym != TICK:
            print("bar not green before mutating: %s (%s)" % (bar, sym))
            return 2
    print("BASELINE all %d SF-73 bars green\n" % len(BARS))

    results = []
    try:
        for mid, fkey, edits, clause, expect in MUTATIONS:
            mutated, landed = texts[fkey], True
            for old, new, want in edits:
                pat = pattern(old)
                found = len(re.findall(pat, mutated))
                if found != want:
                    print("%s: EDIT DID NOT LAND, anchor found %d, wanted %d" % (mid, found, want))
                    landed = False
                    break
                mutated = re.sub(pat, lambda _m, r=new: r, mutated, count=want)
            if not landed:
                results.append((mid, "NOT APPLIED"))
                continue
            if mutated == texts[fkey]:
                print("%s: the mutation is a no-op on the file" % mid)
                results.append((mid, "NOT APPLIED"))
                continue
            with open(FILES[fkey], "w", encoding="utf-8", newline="") as fh:
                fh.write(mutated)
            res = bar_results(run_suite())
            red = [(b, r) for b, r in res.items() if r[0] == CROSS]
            rows = [row for _, r in red for row in r[1]]
            crashed = any(r[2] for _, r in red)
            if rows:
                verdict = "KILLED"
            elif red and crashed:
                verdict = "CRASH"
            else:
                verdict = "SURVIVED"
            results.append((mid, verdict))
            print("%-8s %s\n    clause : %s\n    expect : %s" % (verdict, mid, clause, expect))
            for row in rows[:6]:
                print("    " + row)
            if len(rows) > 6:
                print("    ... and %d more" % (len(rows) - 6))
            print()
            with open(FILES[fkey], "wb") as fh:
                fh.write(originals[fkey])
    finally:
        bad = False
        for k, p in FILES.items():
            with open(p, "wb") as fh:
                fh.write(originals[k])
            ok = hashlib.sha256(read_bytes(p)).hexdigest() == digests[k]
            bad = bad or not ok
            print("restore: %-44s sha256 %s" % (os.path.relpath(p, ROOT), "MATCHES" if ok else "DOES NOT MATCH"))
        if bad:
            return 3
    after = bar_results(run_suite())
    green = all(after.get(b, (None,))[0] == TICK for b in BARS)
    print("after restore: %s\n" % ("all SF-73 bars green" if green else "NOT GREEN"))
    for m, v in results:
        print("  %-8s %s" % (v, m))
    killed = sum(1 for _, v in results if v == "KILLED")
    print("\n%d of %d mutations killed with named rows" % (killed, len(results)))
    return 0 if killed == len(results) and green else 1


if __name__ == "__main__":
    sys.exit(main())
