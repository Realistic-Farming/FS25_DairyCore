# DairyCore RSF-F166 advisory mutation battery.
#
# SEPARATE FILE ON PURPOSE. tools/test/mutate.py is the RSF-F216 milk-sale battery
# and belongs to that feature; this one belongs to F166. The first draft of this
# work wrote over mutate.py wholesale, which would have deleted fourteen F216
# mutations under an F166 commit message. Same mistake as writing a file without
# reading it first. Each battery keeps its own file and its own anchors.
#
# Scope: the guards the repair added. The suite was green BEFORE the repair too,
# on a getter that accepted a nil farm, walked every barn on the map and admitted
# barns whose own farmId was nil. A green bar proves nothing on its own; these
# mutations ask whether each new guard is actually PINNED by a named row.
#
# For each mutation: assert the edit LANDED (exact occurrence count), run the
# suite, record KILLED/SURVIVED with the NAMED rows that failed, restore the file
# byte-for-byte and PROVE the restore with a hash.
#
# KILLED* means killed only by a Lua error. That is a weak kill: the file aborts,
# the runner prints one line and nobody can say which row caught it. Treated as a
# failure of the battery, not a success.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

M = "src/DairyCoreManager.lua"

# (id, file, [(old, new, want), ...], the defect it reintroduces)
MUTATIONS = [
 ("M1-nil-farm-accepted", M,
  [('    if type(farmId) ~= "number" then return nil end',
    '    if type(farmId) ~= "number" then return farmId end', 1)],
  "a nil farm id passes admission, truncates the _proStaff varargs call to zero "
  "arguments and reports FARM 1's entitlement to whoever asked"),

 ("M2-nil-owner-barn-readmitted", M,
  [("    if barn.farmId ~= farmId then return nil end",
    "    if barn.farmId ~= nil and barn.farmId ~= farmId then return nil end", 1)],
  "the old permissive route returns: a barn whose own farmId is nil is published "
  "to ANY requesting farm"),

 ("M3-wire-gate-dropped", M,
  [("    if not isServer and barn._wireReceived ~= true then return nil end",
    "    if false and barn._wireReceived ~= true then return nil end", 1)],
  "a client publishes never-received barn records, whose default herdHealthScore "
  "of 60 sits exactly on the inclusive cutoff, so a default is reported as an "
  "observation of a herd in trouble"),

 ("M4-native-owner-mismatch-ignored", M,
  [("    if not ok or owner ~= farmId then return nil end",
    "    if not ok then return nil end", 1)],
  "a barn whose cached farmId lags native ownership is published to the farm that "
  "no longer owns the building"),

 ("M5-missing-score-reads-as-zero", M,
  [("    local score = barn.herdHealthScore\n"
    "    if type(score) == \"number\" and score == score\n"
    "        and score ~= math.huge and score ~= -math.huge\n"
    "        and score <= self:_herdAdvisoryCutoff() then",
    "    local score = barn.herdHealthScore or 0\n"
    "    if true\n"
    "        and true\n"
    "        and score <= self:_herdAdvisoryCutoff() then", 1)],
  "an absent or malformed health fact is read as 0, which is below every cutoff, "
  "so a missing observation is published as the worst possible one"),

 ("M6-provider-truthiness-accepted", M,
  [('    return self:_proStaff("hasHerdAdvisory", false, id) == true',
    '    return self:_proStaff("hasHerdAdvisory", false, id) and true or false', 1)],
  "any truthy provider return grants entitlement, so a level number, a string or "
  "a table counts as a yes"),

 ("M7-farm-not-forwarded", M,
  [('    return self:_proStaff("hasHerdAdvisory", false, id) == true',
    '    return self:_proStaff("hasHerdAdvisory", false) == true', 1)],
  "the admitted farm is not forwarded, so the provider resolves the mission farm "
  "instead and every farm reads farm 1's entitlement"),

 ("M8-dead-probe-published", M,
  [("    if barnId == nil or barn._probeDead then return nil end",
    "    if barnId == nil then return nil end", 1)],
  "a barn whose placeable probe is dead is still published"),

 ("M9-reasons-order-swapped", M,
  [("    if DairyConstants.HERD_ADVISORY.SPOILAGE_STAGES[\n"
    "            self:_normalizeSpoilageKey(barn.spoilageStatus)] then\n"
    "        reasons[#reasons + 1] = DairyConstants.HERD_ADVISORY.REASONS.MILK\n"
    "    end",
    "    if DairyConstants.HERD_ADVISORY.SPOILAGE_STAGES[\n"
    "            self:_normalizeSpoilageKey(barn.spoilageStatus)] then\n"
    "        table.insert(reasons, 1, DairyConstants.HERD_ADVISORY.REASONS.MILK)\n"
    "    end", 1)],
  "the fixed health-then-milk reason order is reversed, which silently changes "
  "what every view renders first"),

 ("M10-rows-unsorted", M,
  [("    table.sort(rows, function(a, b) return tostring(a.barnId) < tostring(b.barnId) end)",
    "    -- sort removed", 1)],
  "rows come back in pairs() order, so the list reshuffles between reads and a "
  "view's selection lands on a different barn"),
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
    print("  %s %s" % (tag, mid))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
