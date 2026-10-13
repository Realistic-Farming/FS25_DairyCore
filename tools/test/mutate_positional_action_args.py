# PLAYER-REPORTS row 199 mutation battery, the DairyCore half: the feed-flush sender sends a
# positional array and its handler reads args[1] as a positive number; the three latent handlers
# read the documented positional order (src/DairyCoreManager.lua). Rows live in
# PR-199-positional_action_args_test.lua; the other bars run with it.
#
# Each mutation restores one piece of the defect and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the transport itself (the fixture copies of NetworkSync): not this repo's code.
# - the ownership equality (farm.farmId ~= farmId): unchanged by this PR and pinned by the
#   existing d1 rows; only the read of the farm and the > 0 test moved.
# - the > 0 test dropped: an EQUIVALENT mutant here (found in the first run, 7 entries, one
#   survivor, removed). A spectator's forged 0 that passed the equality reaches
#   _doFeedFlush(0), which finds no contaminated feed under farm 0, purges nothing and
#   charges nobody; unlike ProStaff's flush it never resolves 0 to the host's farm. The
#   test stays as Bob's intake asks (defence in depth) and row B3 pins the observable.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_positional_action_args.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MGR = "src/DairyCoreManager.lua"

MUTATIONS = [
 ("K1-flush-sends-keyed", MGR,
  [("        ns:requestAction(DairyConstants.FEED_FLUSH.ACTION, { farmId })\n",
    "        ns:requestAction(DairyConstants.FEED_FLUSH.ACTION, { farmId = farmId })\n", 1)],
  "the flush request arrives empty on the server"),
 ("H1-flush-reads-keyed", MGR,
  [("            local farmId = type(args) == \"table\" and args[1] or nil\n            if type(farmId) ~= \"number\" or farmId <= 0 then return end\n            local farm = g_farmManager",
    "            local farmId = type(args) == \"table\" and args.farmId or nil\n            if type(farmId) ~= \"number\" or farmId <= 0 then return end\n            local farm = g_farmManager", 1)],
  "the flush handler looks for a key the wire cannot carry"),
 ("L1-sell-reads-keyed", MGR,
  [("            local barnId = type(args) == \"table\" and args[1] or nil\n            if barnId == nil then return end\n            self:sellMilk(barnId, args[2])",
    "            local barnId = type(args) == \"table\" and args.barnId or nil\n            if barnId == nil then return end\n            self:sellMilk(barnId, args.quantity)", 1)],
  "the milk sale looks for keys the wire cannot carry"),
 ("L2-assign-reads-keyed", MGR,
  [("            local barnId = type(args) == \"table\" and args[1] or nil\n            if barnId == nil then return end\n            self:assignCollectionWorker(barnId, args[2])",
    "            local barnId = type(args) == \"table\" and args.barnId or nil\n            if barnId == nil then return end\n            self:assignCollectionWorker(barnId, args.workerId)", 1)],
  "the rota assignment looks for keys the wire cannot carry"),
 ("L3-unassign-reads-keyed", MGR,
  [("            local barnId = type(args) == \"table\" and args[1] or nil\n            if barnId == nil then return end\n            self:unassignCollectionWorker(barnId)",
    "            local barnId = type(args) == \"table\" and args.barnId or nil\n            if barnId == nil then return end\n            self:unassignCollectionWorker(barnId)", 1)],
  "the rota release looks for a key the wire cannot carry"),
 ("L4-sell-order-swapped", MGR,
  [("            self:sellMilk(barnId, args[2])", "            self:sellMilk(args[2], barnId)", 1)],
  "the sale's quantity and barn change places"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
