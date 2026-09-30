# RSF-F191 v1.4.0.0 delta mutation battery (full: an RSF repair, R-25): the record
# classifier in RLBridge:computeHerdScore (src/RLBridge.lua), every clause on the lines
# the delta changes, plus the gate, the penalty, the cap and the averaging around them.
# The rows live in f191_active_disease_test.lua (section 7, the v1.4 record state with
# the provider's own 1.4 gate; section 8, the entry-point bar through onDayTick; and the
# legacy rows, 2e and 2f rewritten to the brief), and every other bar runs with them.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# C1, C2 and C3 are the intake's three: the classifier reverted to the v0.2
# `not d.cured and not d.isCarrier` (must fail the mixed row), a state-bearing record
# falling through to the flags (must fail a state row that also carries both flags false),
# and the unknown-state raise dropped (must fail the degrade rows).
#
# Not run, equivalent by construction, and why:
# - dropping the non-string state raise: a non-string state then reaches the unknown-state
#   branch, whose raise (or its string concatenation, for a boolean) still degrades.
# - dropping the disease-list table check: ipairs on a non-table raises inside safeRead.
# - dropping the record table check: indexing a non-table raises, or the record takes the
#   legacy branch and its flag check raises, inside safeRead either way.
# Not run, and outside the delta: the floor at math.max(animalScore, 0), unchanged
# arithmetic that no F191 row reaches (every fixture cow scores above zero).
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f191_v14.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

RLB = "src/RLBridge.lua"

CLASSIFIER = (
    "                    local state = d.state\n"
    "                    if state ~= nil then\n"
    "                        if type(state) ~= \"string\" then\n"
    "                            error(\"F191: a disease state that is not a string (\" .. tostring(state) .. \")\")\n"
    "                        elseif state == \"INFECTIOUS\" then\n"
    "                            diseaseCount = diseaseCount + 1\n"
    "                        elseif state ~= \"EXPOSED\" and state ~= \"RECOVERED\" and state ~= \"DEAD\" then\n"
    "                            error(\"F191: an unknown disease state (\" .. state .. \")\")\n"
    "                        end\n"
    "                    else\n"
    "                        if type(d.cured) ~= \"boolean\" or type(d.isCarrier) ~= \"boolean\" then\n"
    "                            error(\"F191: a legacy disease record without boolean cured and isCarrier flags\")\n"
    "                        end\n"
    "                        if not d.cured and not d.isCarrier then\n"
    "                            diseaseCount = diseaseCount + 1\n"
    "                        end\n"
    "                    end\n")
V02 = ("                    if not d.cured and not d.isCarrier then\n"
       "                        diseaseCount = diseaseCount + 1\n"
       "                    end\n")
FLAGS = "                        if type(d.cured) ~= \"boolean\" or type(d.isCarrier) ~= \"boolean\" then\n"
LEGACY = "                        if not d.cured and not d.isCarrier then\n"
ZERO_STATES = "                        elseif state ~= \"EXPOSED\" and state ~= \"RECOVERED\" and state ~= \"DEAD\" then\n"

MUTATIONS = [
 ("C1-v02-classifier", RLB,
  [(CLASSIFIER, V02, 1)],
  "the classifier reverted to v0.2's not cured and not isCarrier: every 1.4 sibling counts (intake mutant 1)"),
 ("C2-state-falls-through", RLB,
  [("                    if state ~= nil then\n", "                    if state == \"INFECTIOUS\" then\n", 1)],
  "a state-bearing record that is not INFECTIOUS falls through to the legacy flags (intake mutant 2)"),
 ("C3-unknown-state-zero", RLB,
  [("                            error(\"F191: an unknown disease state (\" .. state .. \")\")\n", "", 1)],
  "an unknown state counts zero instead of degrading (intake mutant 3)"),
 ("C4-exposed-counts", RLB,
  [("                        elseif state == \"INFECTIOUS\" then\n",
    "                        elseif state == \"INFECTIOUS\" or state == \"EXPOSED\" then\n", 1)],
  "the hidden phase penalizes"),
 ("C5-any-string-counts", RLB,
  [("                        elseif state == \"INFECTIOUS\" then\n", "                        elseif true then\n", 1)],
  "every string state penalizes"),
 ("C6-susceptible-zero", RLB,
  [(ZERO_STATES,
    "                        elseif state ~= \"EXPOSED\" and state ~= \"RECOVERED\" and state ~= \"DEAD\" and state ~= \"SUSCEPTIBLE\" then\n", 1)],
  "SUSCEPTIBLE counts zero, which the brief does not list (a DEVIATES if built)"),
 ("C7-dead-degrades", RLB,
  [(ZERO_STATES, "                        elseif state ~= \"EXPOSED\" and state ~= \"RECOVERED\" then\n", 1)],
  "a DEAD record degrades the bridge instead of counting zero"),
 ("C8-legacy-flags-unchecked", RLB,
  [(FLAGS, "                        if false then\n", 1)],
  "malformed legacy flags are read instead of raising"),
 ("C9-legacy-cured-flag-only", RLB,
  [(FLAGS, "                        if type(d.cured) ~= \"boolean\" then\n", 1)],
  "only cured must be a boolean"),
 ("C10-legacy-carrier-flag-only", RLB,
  [(FLAGS, "                        if type(d.isCarrier) ~= \"boolean\" then\n", 1)],
  "only isCarrier must be a boolean"),
 ("C11-legacy-cured-ignored", RLB,
  [(LEGACY, "                        if not d.isCarrier then\n", 1)],
  "a cured legacy record penalizes"),
 ("C12-legacy-carrier-ignored", RLB,
  [(LEGACY, "                        if not d.cured then\n", 1)],
  "a carrier legacy record penalizes"),
 ("G1-gate-nonboolean-accepted", RLB,
  [("            if hasAnyDisease ~= true and hasAnyDisease ~= false then\n", "            if false then\n", 1)],
  "a non-boolean gate is read as its truth"),
 ("G2-gate-ignored", RLB,
  [("            if hasAnyDisease then\n", "            if true then\n", 1)],
  "a false gate still opens the list"),
 ("P1-step", RLB,
  [("            local diseasePenalty = math.min(diseaseCount * 0.08, 0.40)\n",
    "            local diseasePenalty = math.min(diseaseCount * 0.07, 0.40)\n", 1)],
  "the step is not 0.08"),
 ("P2-cap", RLB,
  [("            local diseasePenalty = math.min(diseaseCount * 0.08, 0.40)\n",
    "            local diseasePenalty = math.min(diseaseCount * 0.08, 0.48)\n", 1)],
  "the cap is not 0.40"),
 ("P3-no-average", RLB,
  [("        return (total / count) * 100\n", "        return total * 100\n", 1)],
  "the herd is summed, not averaged"),
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
    for l in named[:12]:
        print("        " + l[:120])
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
