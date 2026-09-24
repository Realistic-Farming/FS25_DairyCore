# DC-14 host slice C mutation battery: the Esc floor's data binding (src/gui/DairyRfPdaGuest.lua)
# and the demand end (src/DairyCollectionRoute.lua). Rows live in dc14_collection_refusal_esc_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work (mutate_dc14a.py is
# slice A's, mutate_dc14b.py slice B's).
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the side rail's breed truths for the selected barn (herd, milk, stored feed): the bench's
#     barns carry no DC-27 breed surface, so breedRowFor finds nothing and only the label paints;
#     the breed painters themselves are DC-27's, unchanged, and were card code before this slice;
#   - the label fallback for a row with no label ("Barn " plus the key's tail): the producer never
#     publishes a row without a label (its own fallback runs first, DairyCollectionRefusal.lua:323);
#   - the host page's onClickFwSheetRow and light-tick dispatch (RfPdaMenuPage.lua, the shared
#     door file): the bench calls the registered descriptor exactly as the host does; the shared
#     file is not this mod's to mutate (the shared-file invariant);
#   - dayClock's clamps for a negative or infinite hour: the producer publishes only finite,
#     nonnegative hours (dc14IsFinite), so the clamp is a belt with no reachable row;
#   - the guest's own sort by barnKey (declared equivalent, it survived a run): the getter's rows
#     arrive sorted by contract (the producer sorts, DairyCollectionRefusal.lua:409, and the wire
#     keeps that order), so removing the guest's sort changes no order the bar can see. Kept as a belt.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, THROUGH THE TEST LOCK. A battery edits production files in place.
#
# Usage: py tools/test/mutate_dc14c.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GUEST = "src/gui/DairyRfPdaGuest.lua"
RT = "src/DairyCollectionRoute.lua"

MUTATIONS = [
 # ── the read: the getter and the demand ───────────────────────────────────
 ("E1-no-demand-pulse-on-read", GUEST,
  [("        if type(mgr.pulseCollectionDemand) == \"function\" then pcall(mgr.pulseCollectionDemand, mgr, \"ESC\") end\n", "", 1)],
  "a pure client's route never fetches: the sheet shows updating for good"),
 ("E2-light-tick-is-a-no-op", GUEST,
  [("function DairyRfPdaGuest.onLightTick(container)\n    refreshSheet(container or _sheetContainer, false)\n", "function DairyRfPdaGuest.onLightTick(container)\n", 1)],
  "the 2 s tick neither pulses demand nor repaints a changed row"),
 ("E3-registry-listener-keeps-demand", GUEST,
  [("        pcall(mgr.endCollectionDemand, mgr, \"ESC\")\n", "", 1)],
  "another module taking the door leaves the ESC demand running"),
 ("E4-end-demand-is-a-no-op", RT,
  [("    st.demand[tostring(consumer or \"ESC\")] = nil\n", "    local _ = st.demand\n", 1)],
  "endCollectionDemand clears nothing"),
 # ── the rows ──────────────────────────────────────────────────────────────
 ("R2-no-collision-suffix", GUEST,
  [("        if seen[row.label] > 1 then\n", "        if false then\n", 1)],
  "two barns with the same name are told apart by nothing"),
 ("R3-refused-reads-as-no-report", GUEST,
  [("    if row.code == ROW_REFUSED then\n        row.status = tr(\"dc14_collection_row_refused\", \"Milk left behind\")\n", "    if false then\n        row.status = tr(\"dc14_collection_row_refused\", \"Milk left behind\")\n", 1)],
  "a refused round's row reads No report"),
 ("R4-worker-cell-ignores-next-due", GUEST,
  [("    if row.nextDueHours ~= nil then\n        row.worker = tr(\"dc14_collection_worker_assigned\", \"Assigned\")\n", "    if false then\n        row.worker = tr(\"dc14_collection_worker_assigned\", \"Assigned\")\n", 1)],
  "every barn reads no worker and no next due"),
 ("R5-other-farm-rows-shown", GUEST,
  [("    for _, r in ipairs(type(view) == \"table\" and view.rows or {}) do\n", "    for _, r in ipairs(type(view) == \"table\" and (getMgr() and getMgr()._collectionRefusalRows and getMgr():_collectionRefusalRows(2) or {}) or {}) do\n", 1)],
  "the sheet reads another farm's rows instead of the getter's"),
 ("R6-day-clock-wrong-base", GUEST,
  [("    local day = math.floor(h / 24)\n", "    local day = math.floor(h / 24) + 1\n", 1)],
  "the day number is off by one"),
 # ── the band ──────────────────────────────────────────────────────────────
 ("B1-band-omits-next-due", GUEST,
  [("        lines[#lines + 1] = string.format(tr(\"dc14_collection_next_due\", \"Next collection due: day %s at %s.\"), d, c)\n", "", 1)],
  "the selected barn with a worker shows no next due"),
 ("B2-band-says-no-worker-always", GUEST,
  [("    if row.nextDueHours ~= nil then\n        local d, c = dayClock(row.nextDueHours)\n        lines[#lines + 1] = string.format(tr(\"dc14_collection_next_due\"", "    if false then\n        local d, c = dayClock(row.nextDueHours)\n        lines[#lines + 1] = string.format(tr(\"dc14_collection_next_due\"", 1)],
  "a barn with a worker reads as having none"),
 ("B3-band-refused-reads-no-report", GUEST,
  [("    if row.code == ROW_REFUSED then\n        local d, c = dayClock(row.attemptHours)\n", "    if false then\n        local d, c = dayClock(row.attemptHours)\n", 1)],
  "the refused barn's band carries no past attempt"),
 ("B4-band-shows-with-no-selection", GUEST,
  [("    if row == nil then\n        setVis(band, false)\n        setText(band, \"\")\n        return\n    end\n    local lines = { row.label }\n", "    if row == nil then row = _sheetRows[1] end\n    if row == nil then\n        setVis(band, false)\n        setText(band, \"\")\n        return\n    end\n    local lines = { row.label }\n", 1)],
  "the band shows the first row's sentence before any click"),
 # ── the selection ─────────────────────────────────────────────────────────
 ("S1-selection-survives-row-loss", GUEST,
  [("        if not still then clearSelection() end\n", "", 1)],
  "a demolished barn stays selected and its band stays up"),
 ("S2-selection-survives-door-change", GUEST,
  [("    if host ~= nil and host.activeModuleId == PANEL_ID then return end\n    clearSelection()\n", "    if host ~= nil and host.activeModuleId == PANEL_ID then return end\n", 1)],
  "another module taking the door leaves Dairy's selection and band"),
 ("S3-selection-survives-farm-change", GUEST,
  [("    if _lastFarmId ~= farmId then\n        clearSelection()\n", "    if _lastFarmId ~= farmId then\n", 1)],
  "the farm switch keeps the old farm's selection"),
 ("S4-click-past-rows-keeps-selection", GUEST,
  [("    if row == nil then\n        clearSelection()\n    else\n        _selectedKey = row.key\n    end\n", "    if row ~= nil then\n        _selectedKey = row.key\n    end\n", 1)],
  "a click past the rows leaves the previous selection"),
 # ── the states and the chrome ─────────────────────────────────────────────
 ("T1-waiting-reads-unavailable", GUEST,
  [("    if view.state == \"WAITING\" then return tr(\"dc14_collection_updating\", \"Updating collection status.\") end\n", "", 1)],
  "a client before its first snapshot reads unavailable, not updating"),
 ("T2-settings-off-reads-unavailable", GUEST,
  [("    if view.reason == \"SETTINGS_OFF\" then return tr(\"dc14_collection_settings_off\", \"Dairy simulation is off.\") end\n", "", 1)],
  "settings off reads as a generic unavailable"),
 ("T3-sheet-shown-in-a-state", GUEST,
  [("        _sheetRows, _lastSignature = {}, nil\n        clearSelection()\n        setVis(box, false)\n", "        _sheetRows, _lastSignature = {}, nil\n        clearSelection()\n        setVis(box, true)\n", 1)],
  "the empty sheet box stays up under the state hint"),
 ("T4-thrash-fence-removed", GUEST,
  [("    if full or sig ~= _lastSignature then\n", "    if true then\n", 1)],
  "every light tick reloads the list, the scroll nudging the player"),
 ("T5-headings-not-set", GUEST,
  [("    setText(findOnPage(container, \"rfFwColB\"), tr(\"dc14_collection_heading_status\", \"Collection\"))\n", "", 1)],
  "the second column keeps whatever heading the last module left"),
 ("T6-cards-left-visible", GUEST,
  [("    for slot = 1, CARD_SLOTS do\n        setVis(cardEl(container, slot), false)\n    end\n    setVis(findOnPage(container, \"rfDairyCardsHint\"), false)\n", "", 1)],
  "the old card frames stay on screen under the sheet"),
 ("T7-no-sheet-row-registered", GUEST,
  [("            onSheetRow = DairyRfPdaGuest.onSheetRow,\n", "", 1)],
  "the host's row click reaches no handler: nothing can be selected"),
 ("T8-no-light-tick-registered", GUEST,
  [("            onLightTick = DairyRfPdaGuest.onLightTick,\n", "", 1)],
  "the host's soft refresh falls back to the fat show every two seconds"),
]

def sha(b): return hashlib.sha256(b).hexdigest()

def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], capture_output=True, text=True, cwd=p("tools/test"), encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    fails = [l.strip() for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [l.strip() for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes

only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]: print("   " + l)
    for l in crashes[:5]: print("   " + l)
    sys.exit(2)
print("baseline green")

killed, survived, bad, weak = 0, 0, 0, 0
for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only): continue
    path = p(rel)
    original = open(path, "rb").read()
    before = sha(original)
    crlf = b"\r\n" in original
    text = original.decode("utf-8").replace("\r\n", "\n")
    ok = True
    for old, new, count in edits:
        if text.count(old) != count:
            print("  BAD EDIT %s: anchor found %d times, want %d" % (mid, text.count(old), count)); ok = False; break
        text = text.replace(old, new)
    if not ok: bad += 1; continue
    open(path, "wb").write((text.replace("\n", "\r\n") if crlf else text).encode("utf-8"))
    try:
        rc, fails, crashes = run_suite()
    finally:
        open(path, "wb").write(original)
        assert sha(open(path, "rb").read()) == before, "restore failed for " + rel
    if rc != 0:
        killed += 1
        star = "*" if (len(fails) == 0 and len(crashes) > 0) else " "
        if star == "*": weak += 1
        print("  KILLED%s  %s  [%s]" % (star, mid, rel))
        for l in fails[:4]: print("        " + l)
        for l in crashes[:2]: print("        " + l)
    else:
        survived += 1
        print("  SURVIVED %s  [%s]  (%s)" % (mid, rel, why))

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (killed, weak))
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(0 if survived == 0 and bad == 0 and weak == 0 else 1)
