# RSF-F216 milk-sale mutation harness.
#
# For each mutation: assert the edit LANDED (exact occurrence count), run the
# suite, record KILLED/SURVIVED with the NAMED rows that failed, then restore the
# file byte-for-byte and prove the restore with a hash.
#
# WHY THE COUNT ASSERT IS THE WHOLE POINT. A no-op edit is indistinguishable from
# an unpinned rule: both report "SURVIVED". Two of this battery's first drafts were
# no-ops that read as surviving bars, one adding a second refusal that was
# unreachable because the first still returned, and one capturing pcall's result
# without wrapping anything. Both would have sent someone hunting a missing test
# that was not missing.
#
# A kill by a Lua error rather than a named row is reported as KILLED*, because a
# crash aborts the file and hides which bar caught it along with every bar after it.
# The battery should have no KILLED* entries; if one appears, guard the dereference
# in the test rather than accepting the kill.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MGR = "src/DairyCoreManager.lua"
CON = "src/DairyConstants.lua"

# The early refusal block, as a single anchor. Several mutations remove it and put
# it back somewhere worse, which is how the ordering hazard is tested: a mutation
# that only ADDS a second refusal lower down is unreachable and proves nothing.
EARLY = '''    if spot <= fee then
        DCLogger.info("Milk sale refused (%s): fee %.4f/L meets or beats price %.4f/L (barn %s)",
            tostring(source), fee, spot, tostring(barn.barnId))
        return nil, "fee_exceeds_price"
    end

    -- DC-25: read tank then barn in one server tick.'''
EARLY_GONE = '''    -- DC-25: read tank then barn in one server tick.'''

# (id, file, [(old, new, expected_occurrences), ...], rule it breaks)
MUTATIONS = [
 ("M1-refusal-removed", MGR,
  [(EARLY, EARLY_GONE, 1)],
  "the sale no longer refuses at all; milk moves at any fee"),

 ("M2-boundary-weakened", MGR,
  [("    if spot <= fee then", "    if spot < fee then", 1)],
  "at an exactly equal fee and price the sale proceeds and pays nothing"),

 ("M3-refusal-after-removal", MGR,
  [(EARLY, EARLY_GONE, 1),
   ('    local removed = tankRemoved + barnRemoved\n    if removed <= 0 then return nil, "no_milk" end',
    '    local removed = tankRemoved + barnRemoved\n    if removed <= 0 then return nil, "no_milk" end\n'
    '    if spot <= fee then return nil, "fee_exceeds_price" end', 1)],
  "the milk is taken from the tank and barn and THEN the sale refuses"),

 ("M4-refusal-inside-suppression", MGR,
  [(EARLY, EARLY_GONE, 1),
   ("    barn._suppressDetection = true\n    local barnRemoved = 0",
    "    barn._suppressDetection = true\n"
    '    if spot <= fee then return nil, "fee_exceeds_price" end\n'
    "    local barnRemoved = 0", 1)],
  "returns inside the suppressed window, so a later REAL milk drop goes unnoticed"),

 ("M5-nonfinite-guard-removed", MGR,
  [("    if raw == nil or raw ~= raw or raw == math.huge or raw == -math.huge then\n"
    "        raw = DairyConstants.SALE.FEE_PER_1000L\n    end",
    "    if raw == nil then raw = DairyConstants.SALE.FEE_PER_1000L end", 1)],
  "a NaN fee reaches the comparison, where spot <= fee is false and the refusal never fires"),

 ("M6-floor-dropped", MGR,
  [("    local feePer1000 = math.floor(raw)", "    local feePer1000 = raw", 1)],
  "a fractional setting becomes a second fractional charge"),

 ("M7-clamp-dropped", MGR,
  [("    feePer1000 = math.max(DairyConstants.SALE.FEE_MIN_PER_1000L,\n"
    "                          math.min(DairyConstants.SALE.FEE_MAX_PER_1000L, feePer1000))",
    "    -- clamp removed", 1)],
  "a setting outside the ratified band is charged as written"),

 ("M8-one-outer-pcall", MGR,
  # BOTH rungs must end up inside ONE pcall for this to be the defect it names.
  # A first version merged rung 1 into a single pcall but left rung 2's own pcall
  # standing below, so the fill-type rung was still reached and the mutation
  # SURVIVED: a no-op wearing a real mutation's name. Edit 2 removes rung 2's
  # separate guard, which is what actually creates the defect.
  [("""    local quote = nil
    pcall(function()
        local md = g_currentMission ~= nil and g_currentMission.MarketDynamics or nil
        if md == nil or md.isActive ~= true then return end
        if md.settings ~= nil and not md.settings.pricesEnabled then return end
        local engine = md.marketEngine
        if engine == nil or engine.getPrice == nil or ftIndex == nil then return end
        quote = engine:getPrice(ftIndex)
    end)""",
    """    local quote, base = nil, nil
    pcall(function()
        local md = g_currentMission ~= nil and g_currentMission.MarketDynamics or nil
        if md ~= nil and md.isActive == true
           and not (md.settings ~= nil and not md.settings.pricesEnabled) then
            local engine = md.marketEngine
            if engine ~= nil and engine.getPrice ~= nil and ftIndex ~= nil then
                quote = engine:getPrice(ftIndex)
            end
        end
        if type(quote) == "number" and quote > 0 then return end
        local ftm = g_fillTypeManager
        if ftm == nil or ftIndex == nil then return end
        local desc = ftm:getFillTypeByIndex(ftIndex)
        base = desc ~= nil and desc.pricePerLiter or nil
    end)""", 1),
   ("""    local base = nil
    pcall(function()
        local ftm = g_fillTypeManager
        if ftm == nil or ftIndex == nil then return end
        local desc = ftm:getFillTypeByIndex(ftIndex)
        base = desc ~= nil and desc.pricePerLiter or nil
    end)
    if type(base) == "number" then""",
    """    if type(base) == "number" then""", 1)],
  "a THROWING provider aborts the whole ladder and lands on the 1.0 literal, never trying the fill type"),

 ("M9-isActive-dropped", MGR,
  [("        if md == nil or md.isActive ~= true then return end",
    "        if md == nil then return end", 1)],
  "a loading or disabled provider's quote is taken as a live price"),

 ("M10-pricesEnabled-dropped", MGR,
  [("        if md.settings ~= nil and not md.settings.pricesEnabled then return end",
    "        -- predicate removed", 1)],
  "a quote is used while the provider's own pricing is switched off"),

 ("M11-rota-return-dropped", MGR,
  [("    return self:_adminSellMilk(barn, nil, DairyConstants.COLLECTION.SOURCES.rota, nowHours, monotonicDay)",
    "    self:_adminSellMilk(barn, nil, DairyConstants.COLLECTION.SOURCES.rota, nowHours, monotonicDay)", 1)],
  "the hour tick cannot observe the rota's result"),

 ("M12-divided-twice", MGR,
  [("    local fee = feePer1000 / DairyConstants.SALE.FEE_DIVISOR",
    "    local fee = feePer1000 / DairyConstants.SALE.FEE_DIVISOR / DairyConstants.SALE.FEE_DIVISOR", 1)],
  "the conversion has two homes and the charge is a thousandth of the ruling"),

 ("M13-default-changed", CON,
  [("    FEE_PER_1000L     = 11,", "    FEE_PER_1000L     = 12,", 1)],
  "the shipped default is not the ratified 11 per 1000 L"),

 ("M14-sale-uses-shared-helper", MGR,
  [("    local spot = self:_milkSaleUnitPrice(fillType)", "    local spot = self:_milkSpotPrice()", 1)],
  "the sale prices through the shared helper again, ignoring isActive and pricesEnabled"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
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

    counts_ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            counts_ok = False
            break
        mutated = mutated.replace(ob, nb, 1)
    if not counts_ok:
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
    print("  %s %s  (%s)" % (tag, mid, why))
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
