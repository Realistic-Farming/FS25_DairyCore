# DairyCore MAINTENANCE row 99 battery: the three translation helpers (src/gui/DairyRfPdaGuest.lua's
# tr, src/DairyCoreManager.lua's _tr, src/gui/DairyGuideDialog.lua's tr) in the SoilFertilizer #973
# shape. Rows live in group T of dc14_collection_refusal_esc_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# Each mutation restores the old gate or removes the new one and must be KILLED by a named row.
# For each: assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. KILLED* means
# killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the manager's _tr without hasText: its one call site's key is present in the bar's texts,
#     so the helper answers the same either way there; the guest's and the guide's copies (the
#     same body) carry that mutation (P2, D2), and T2 and T5 pin the absent-key case;
#   - the pcall around hasText: removing it raises inside the helper, which surfaces as a Lua
#     error rather than a named row (T6 is the observable; a crash kill is unattributable);
#   - the deleted modEnv.i18n branch: restoring it reads a field the engine never sets
#     (mods.lua:453 sets modEnv.g_i18n), so it is equivalent in every reachable state.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint99_tr_gate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GUEST = "src/gui/DairyRfPdaGuest.lua"
MGR = "src/DairyCoreManager.lua"
GUIDE = "src/gui/DairyGuideDialog.lua"
HAS = "    local okHas, has = pcall(i18n.hasText, i18n, key)\n    if not okHas or has ~= true then return fallback or key end\n"
RET = "    if not ok or type(text) ~= \"string\" or text == \"\" then return fallback or key end\n    return text\nend\n"
PREFIX = "    if not ok or type(text) ~= \"string\" or text == \"\" then return fallback or key end\n    if text:lower():find(\"^missing\") then return fallback or key end\n    return text\nend\n"

MUTATIONS = [
 ("P1-guest-prefix-gate-restored", GUEST, [(RET, PREFIX, 1)],
  "the guest refuses a real text that begins 'Missing' and shows the English fallback"),
 ("P2-guest-no-hastext", GUEST, [(HAS, "", 1)],
  "the guest trusts getText for an absent key and shows the engine's Missing sentence"),
 ("M1-manager-prefix-gate-restored", MGR, [(RET, PREFIX, 1)],
  "the manager hands SettingsHub the English fallback for a real label that begins 'Missing'"),
 ("D1-guide-prefix-gate-restored", GUIDE, [(RET, PREFIX, 1)],
  "the Field Guide refuses a real text that begins 'Missing'"),
 ("D2-guide-no-hastext", GUIDE, [(HAS, "", 1)],
  "the Field Guide shows the engine's Missing sentence for an absent key"),
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
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
