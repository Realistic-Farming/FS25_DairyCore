# MAINTENANCE rows 242 and 260 mutation battery: DairyCore's Soil harvest integration works in a game.
# Row 242: Soil's handle read from the mission first (src/DairyCoreManager.lua: _barnOrganicFraction;
# src/FeedProvenance.lua: onHarvestCut). Row 260: Soil's harvest bus called with a dot, subscribe(name, fn)
# and unsubscribe(name) (src/DairyCoreManager.lua: _bindHarvestBus, _unbindHarvestBus). Rows live in
# tools/test/lua/MAINT-242-soil_harvest_integration_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. This repo's runner has no
# selection, so each mutant runs the whole suite. Run ONE mutant per call, in the foreground, and check free
# memory first.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the bare-global fallbacks kept after the mission read: in a game they read nil (Soil's global lives in
#     Soil's own mod environment), so removing them changes nothing a game can reach;
#   - comments.
#
# M06 mutates a line this PR does not change (onHarvestCut's contamination carry), at Bob's R-15: this PR makes
# that carry reachable in a game for the first time, and E6 is the bar that reaches it.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint242.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint242.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint242.py --baseline  the suite, unmutated
#        py tools/test/mutate_maint242.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MGR = "src/DairyCoreManager.lua"
FP = "src/FeedProvenance.lua"

MUTATIONS = [
 ("M01-contract-bare-global", MGR,
  [("    local mgr = (g_currentMission ~= nil and g_currentMission.soilFertilityManager) or g_SoilFertilityManager\n",
    "    local mgr = g_SoilFertilityManager\n", 1)],
  "the contract's organic credit reads only the bare global: nil in a game (E4)"),
 ("M02-harvest-bare-global", FP,
  [("        local sf = (g_currentMission ~= nil and g_currentMission.soilFertilityManager) or g_SoilFertilityManager\n",
    "        local sf = g_SoilFertilityManager\n", 1)],
  "the harvest capture reads only the bare global: every cut recorded conventional (E2)"),
 ("M03-provenance-colon", MGR,
  [('        bus.subscribe("DairyCore_FeedProvenance", function(payload)\n',
    '        bus:subscribe("DairyCore_FeedProvenance", function(payload)\n', 1)],
  "the provenance listener subscribed with a colon: Soil refuses it, no harvest reaches provenance (E1, E2)"),
 ("M04-contamination-colon", MGR,
  [('        bus.subscribe("DairyCore_FeedContamination", function(payload)\n',
    '        bus:subscribe("DairyCore_FeedContamination", function(payload)\n', 1)],
  "the mycotoxin listener subscribed with a colon: Soil refuses it, no barn is penalised (E1, E3)"),
 ("M05-unsubscribe-colon", MGR,
  [('            bus.unsubscribe("DairyCore_FeedProvenance")\n            bus.unsubscribe("DairyCore_FeedContamination")\n',
    '            bus:unsubscribe("DairyCore_FeedProvenance")\n            bus:unsubscribe("DairyCore_FeedContamination")\n', 1)],
  "the listeners unsubscribed with a colon: Soil keeps both after the mission ends (E5)"),
 ("M06-no-contamination-carry", FP,
  [("    local cont = math.max(0, math.min(1, (payload.diseasePressure or 0) / 100))\n",
    "    local cont = 0\n", 1)],
  "a harvest cut carries no contamination into the feed pool (E6); not a line this PR changes, run at Bob's R-15"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "crashed" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, out = run_suite()
        tail = [l for l in out.strip().splitlines() if l.strip()]
        print(re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, _ = run_suite()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "crashed" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
