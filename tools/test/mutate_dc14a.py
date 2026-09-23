# DC-14 host slice A mutation battery: the collection-refusal session report and its
# safe view (src/DairyCollectionRefusal.lua), the manager's capture and clears
# (src/DairyCoreManager.lua). Rows live in dc14_collection_refusal_producer_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work (mutate.py is
# RSF-F216's, mutate_f166.py is RSF-F166's).
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - "farm 0 admitted" (Bob's intake): farm 0 is refused twice on the same line of
#     _collectionRealFarmId (farmId < 1, then _isRealFarmId), and 14 and 15 fall to the
#     MAX_FARM_ID bound before _isRealFarmId sees them, so the two guards mask each
#     other and no one-line edit admits 0; V6 and V7 pin the bound and the integer
#     test, which are the guards a bar can see;
#   - main.lua's source() of the new file: the bench loads modules from the --!load
#     list, so a missing source line is invisible here; the pre-commit gate parses
#     main.lua and the build check verifies the zip carries the file;
#   - a getter returning a stored table instead of fresh ones: nothing in the code
#     keeps a rows table to return, so no one-line edit creates that defect; row K3
#     stands as the contract check;
#   - the unkeyed-barn warning path: a placeable unique id that is empty or over 128
#     bytes does not occur in the engine, and the path only logs.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, THROUGH THE TEST LOCK. A battery edits production files in place.
#
# Usage: py tools/test/mutate_dc14a.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CR = "src/DairyCollectionRefusal.lua"
MGR = "src/DairyCoreManager.lua"

MUTATIONS = [
 # ── the capture ────────────────────────────────────────────────────────────
 ("C1-status-dropped-at-capture", MGR,
  [("                self:_recordCollectionAttempt(barn, ok, removed, status, nowHours)\n", "", 1)],
  "the rota's status is captured and never recorded: no refusal is ever explained"),
 ("C2-sale-not-protected", MGR,
  [("                local ok, removed, status = pcall(self._rotaCollection, self, barn, nowHours, monotonicDay)",
    "                local ok, removed, status = true, self:_rotaCollection(barn, nowHours, monotonicDay)", 1)],
  "a raising sale aborts the whole tick loop instead of marking its barn unavailable"),
 ("C3-any-status-explained", CR,
  [("    elseif status == \"fee_exceeds_price\" then", "    elseif status ~= nil then", 1)],
  "an ordinary sale result is read as a refusal"),
 ("C4-ordinary-result-keeps-record", CR,
  [("    else\n        record = nil\n    end\n    local before = st.records[barnId]",
    "    else\n        record = st.records[barnId]\n    end\n    local before = st.records[barnId]", 1)],
  "a later ordinary sale no longer clears the explanation"),
 ("C5-unresolved-owner-stores-fee", CR,
  [("        if owner == nil or owner ~= barn.farmId then", "        if false then", 1)],
  "a refusal with an unreadable or changed owner reads the milk and stores a fee reason"),
 ("C6-raising-sale-claims-nothing-wrong", CR,
  [("        record = { recordedFarmId = owner, state = R.ROW_STATES.UNAVAILABLE, reason = R.ROW_REASONS.EVALUATION_ERROR }\n    elseif status == \"fee_exceeds_price\" then",
    "        record = nil\n    elseif status == \"fee_exceeds_price\" then", 1)],
  "a raising sale reads as no report"),

 # ── presence ───────────────────────────────────────────────────────────────
 ("P1-station-instead-of-storage", CR,
  [("    local storage = spec ~= nil and spec.storage or nil", "    local storage = spec ~= nil and (spec.unloadingStation or spec.storage) or nil", 1)],
  "the barn read uses the unloading station, whose levels are not keyed by the numeric index"),
 ("P2-unsupported-index-read-anyway", CR,
  [("    if not supported then return \"UNAVAILABLE\" end\n", "", 1)],
  "a Storage that does not support MILK is read as zero"),
 ("P3-malformed-level-accepted", CR,
  [("    if not dc14IsFinite(level) or level < 0 then return \"UNAVAILABLE\" end\n    return level > 0 and \"PRESENT\" or \"ZERO\"",
    "    if type(level) ~= \"number\" then level = tonumber(level) or 0 end\n    return level > 0 and \"PRESENT\" or \"ZERO\"", 1)],
  "a malformed level is coerced instead of refused"),
 ("P4-missing-storage-is-zero", CR,
  [("    if type(storage) ~= \"table\" then return \"UNAVAILABLE\" end", "    if type(storage) ~= \"table\" then return \"ZERO\" end", 1)],
  "a missing native Storage collapses to zero, the _milkLevel defect the brief names"),
 ("P5-tank-read-before-barn-zero", CR,
  [("    local barnRead = self:_collectionBarnMilk(barn)\n    if barnRead ~= \"ZERO\" then return barnRead end\n    return self:_collectionTankMilk(barn, farmId)",
    "    local tankRead = self:_collectionTankMilk(barn, farmId)\n    if tankRead ~= \"ZERO\" then return tankRead end\n    return self:_collectionBarnMilk(barn)", 1)],
  "an unreadable tank poisons a barn that proved presence"),
 ("P6-tank-quantity-from-native-storage", CR,
  [("                local fill = tank.fillLevel", "                local fill = (type(tp.spec_husbandry) == \"table\" and tp.spec_husbandry.storage and tp.spec_husbandry.storage.fillLevels and tp.spec_husbandry.storage.fillLevels[1]) or 0", 1)],
  "the tank's milk is read from an invented native Storage instead of the registry record"),
 ("P7-cached-tank-owner-admits", CR,
  [("                if ok then owner = self:_collectionRealFarmId(o) end", "                if ok then owner = self:_collectionRealFarmId(tank.farmId) end", 1)],
  "the registry's cached farm admits a tank whose live owner is another farm"),
 ("P8-out-of-range-tank-counted", CR,
  [("            inRange = math.sqrt(dx * dx + dz * dz) < radius", "            inRange = true", 1)],
  "a tank beyond the radius proves presence"),
 ("P9-unread-position-ignored", CR,
  [("        if inRange == nil then\n            uncertain = true\n        elseif inRange then",
    "        if inRange == nil then\n            uncertain = uncertain\n        elseif inRange then", 1)],
  "a candidate with no live position is skipped instead of failing closed"),
 ("P10-unread-owner-ignored", CR,
  [("            if owner == nil then\n                uncertain = true\n            elseif owner == farmId then",
    "            if owner == nil then\n                uncertain = uncertain\n            elseif owner == farmId then", 1)],
  "a tank in range whose owner cannot be read is skipped"),
 ("P11-malformed-fill-ignored", CR,
  [("                if not dc14IsFinite(fill) or fill < 0 then\n                    uncertain = true\n                elseif fill > 0 then",
    "                if not dc14IsFinite(fill) or fill < 0 then\n                    uncertain = uncertain\n                elseif fill > 0 then", 1)],
  "a malformed registry fill on a same-farm tank is skipped"),
 ("P12-trusted-zero-keeps-record", CR,
  [("            elseif presence == \"ZERO\" then\n                -- An empty high-fee round: trusted zero clears an older explanation.\n                record = nil",
    "            elseif presence == \"ZERO\" then\n                record = st.records[barnId]", 1)],
  "an empty high-fee round keeps an older explanation alive"),

 # ── the view ───────────────────────────────────────────────────────────────
 ("V1-stale-owner-not-invalidated", CR,
  [("            if record ~= nil and owner ~= nil and record.recordedFarmId ~= owner then\n                st.records[barnId] = nil\n                record = nil\n                self:_touchCollectionRefusal()\n            end\n", "", 1)],
  "a barn sold to another farm carries the seller's explanation to the buyer"),
 ("V2-cached-farm-admits", CR,
  [("            if owner ~= nil then\n                admitted = owner == farmId\n            elseif barn.farmId == farmId then",
    "            if barn.farmId == farmId then\n                admitted = true\n            elseif owner == farmId then", 1)],
  "the cached farm id admits a row after the placeable changed hands"),
 ("V3-unresolved-owner-shows-record", CR,
  [("                    if unresolved then\n                        row.state, row.code = R.ROW_STATES.UNAVAILABLE, R.ROW_CODES.UNAVAILABLE\n                        row.reason = R.ROW_REASONS.OWNER_UNRESOLVED\n                    elseif record == nil then",
    "                    if record == nil then", 1)],
  "an unreadable owner still shows whatever was recorded"),
 ("V4-next-due-without-worker", CR,
  [("                    if barn.assignedWorkerId ~= nil and dc14IsFinite(barn.nextCollectionDue)",
    "                    if dc14IsFinite(barn.nextCollectionDue)", 1)],
  "next due is published with no worker on the rota"),
 ("V5-rows-unsorted", CR,
  [("    table.sort(rows, function(a, b) return a.barnKey < b.barnKey end)\n", "", 1)],
  "rows come out in registration order"),
 ("V6-upper-farm-bound-dropped", CR,
  [("    if farmId < 1 or farmId > maxId then return nil end", "    if farmId < 1 then return nil end", 1)],
  "an id past MAX_FARM_ID is a real farm"),
 ("V7-fraction-admitted", CR,
  [("    if not dc14IsFinite(farmId) or math.floor(farmId) ~= farmId then return nil end", "    if not dc14IsFinite(farmId) then return nil end", 1)],
  "a fractional farm id is admitted"),
 ("V8a-placeable-existence-not-reproved", CR,
  [("        local live = (p ~= nil and not barn._probeDead) and self:_advisoryPlaceable(barnId, ps) or nil\n        if live ~= nil and live == p then",
    "        local live = (p ~= nil and not barn._probeDead) and p or nil\n        if live ~= nil and live == p then", 1)],
  "a demolished barn keeps its row until the next discovery pass"),
 ("V8b-getter-farm-after-server-branch", CR,
  [("    local farmId = self:_collectionLocalFarmId()\n    if farmId == nil then\n        return { state = R.STATES.UNAVAILABLE, reason = R.REASONS.NO_REAL_FARM, rows = {} }\n    end\n    if not self:_isServer() then\n        return { state = R.STATES.WAITING, reason = R.REASONS.FIRST_SNAPSHOT, rows = {} }\n    end",
    "    if not self:_isServer() then\n        return { state = R.STATES.WAITING, reason = R.REASONS.FIRST_SNAPSHOT, rows = {} }\n    end\n    local farmId = self:_collectionLocalFarmId()\n    if farmId == nil then\n        return { state = R.STATES.UNAVAILABLE, reason = R.REASONS.NO_REAL_FARM, rows = {} }\n    end", 1)],
  "a pure client with no real farm reads updating instead of NO_REAL_FARM"),
 ("V8-client-reads-as-ready", CR,
  [("        return { state = R.STATES.WAITING, reason = R.REASONS.FIRST_SNAPSHOT, rows = {} }",
    "        return { state = R.STATES.READY, reason = nil, rows = {} }", 1)],
  "a pure client with no snapshot reads no-report instead of updating"),
 ("V9-settings-off-answers", CR,
  [("    if self.settings == nil or self.settings.enabled == false then\n        return { state = R.STATES.UNAVAILABLE, reason = R.REASONS.SETTINGS_OFF, rows = {} }\n    end\n", "", 1)],
  "with Dairy switched off the view still answers"),
 ("V10-pf-exposes-surface", CR,
  [("    if self.disabled then return nil end\n    if self.settings == nil", "    if self.settings == nil", 1)],
  "PF stand-down exposes a collection surface"),
 ("V11-label-not-bounded", CR,
  [("    if type(label) == \"string\" and label ~= \"\" and #label <= R.MAX_LABEL_BYTES and dc14ValidUtf8(label) then",
    "    if type(label) == \"string\" and label ~= \"\" then", 1)],
  "a 129-byte or invalid UTF-8 name is packed as the label"),

 # ── the clears and the boundaries ──────────────────────────────────────────
 ("L1-collection-does-not-clear", MGR,
  [("    -- DC-14: an actual collection from any real source clears the refusal explanation.\n    self:_clearCollectionRefusal(barn.barnId)\n", "", 1)],
  "an office sale or a detected haul leaves the explanation standing"),
 ("L1b-due-round-does-not-bump", MGR,
  [("            barn.nextCollectionDue = nowHours + (barn.collectionInterval or 24)\n            -- DC-14: the next due moved; a worker's barn publishes it.\n            if barn.assignedWorkerId ~= nil then self:_touchCollectionRefusal() end\n",
    "            barn.nextCollectionDue = nowHours + (barn.collectionInterval or 24)\n", 1)],
  "a due round moves the published next due without moving the revision"),
 ("L1c-census-change-does-not-bump", MGR,
  [("        -- DC-14: the census moved (bound, hidden, removed or re-owned), so the\n        -- admitted rows moved with it.\n        self:_touchCollectionRefusal()\n", "", 1)],
  "a barn hidden or bound by discovery changes the rows without moving the revision"),
 ("L2-unassign-clears", MGR,
  [("    barn.rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED\n    -- DC-14: the past attempt is retained; only the next-due publication changes.\n    self:_touchCollectionRefusal()",
    "    barn.rotaState = DairyConstants.COLLECTION.ROTA_STATES.UNASSIGNED\n    self:_clearCollectionRefusal(barnId)", 1)],
  "unassigning the worker erases the last actual attempt"),
 ("L3-unassign-does-not-touch", MGR,
  [("    -- DC-14: the past attempt is retained; only the next-due publication changes.\n    self:_touchCollectionRefusal()\n", "", 1)],
  "the shown projection changes without the revision moving"),
 ("L4-no-reset-on-load", MGR,
  [("    self:_resetCollectionRefusalSession()\n    self._discoveryRetries = 0", "    self._discoveryRetries = 0", 1)],
  "a same-process mission reload keeps the old session's reports"),
 ("L5-reset-below-pf-return", MGR,
  [("    self:_resetCollectionRefusalSession()\n    self._discoveryRetries = 0\n    self._discoveryTimer = 0\n    self._discoveryPending = true\n    -- Zero Precision Farming compatibility: stand down fully if PF is present.\n    if g_modIsLoaded ~= nil and g_modIsLoaded[\"FS25_precisionFarming\"] then\n        self.disabled = true\n        DCLogger.info(\"Precision Farming detected - DairyCore standing down\")\n        return\n    end\n",
    "    self._discoveryRetries = 0\n    self._discoveryTimer = 0\n    self._discoveryPending = true\n    -- Zero Precision Farming compatibility: stand down fully if PF is present.\n    if g_modIsLoaded ~= nil and g_modIsLoaded[\"FS25_precisionFarming\"] then\n        self.disabled = true\n        DCLogger.info(\"Precision Farming detected - DairyCore standing down\")\n        return\n    end\n    self:_resetCollectionRefusalSession()\n", 1)],
  "the reset sits below the PF stand-down return, so a PF load keeps the old map"),
 ("L6-no-reset-on-delete", MGR,
  [("function DairyCoreManager:onMissionDelete()\n    self:_resetCollectionRefusalSession()\n", "function DairyCoreManager:onMissionDelete()\n", 1)],
  "mission delete keeps the session map"),
 ("L7-removal-keeps-record", MGR,
  [("                -- DC-14: a confirmed removal clears its explanation.\n                self:_clearCollectionRefusal(barnId)\n", "", 1)],
  "a removed barn's explanation lingers in the map"),
 ("L8-registration-owner-change-keeps-record", MGR,
  [("        -- DC-14: a barn that changed hands carries no old owner's explanation.\n        self:_clearCollectionRefusal(barnId)\n", "", 1)],
  "re-registration under a new owner keeps the old owner's explanation"),
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
