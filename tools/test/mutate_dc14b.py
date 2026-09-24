# DC-14 host slice B mutation battery: the routes a view travels (src/DairyCollectionRoute.lua),
# the DIRECT events (src/network/DairyCollectionStatusEvents.lua), the getter's client
# branch and row 94's live-miss latch (src/DairyCollectionRefusal.lua), and the two
# revision touches Bob named on #60 (src/DairyCoreManager.lua). Rows live in
# dc14_collection_refusal_transport_test.lua and dc14_collection_refusal_producer_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work (mutate_dc14a.py
# is slice A's, mutate.py RSF-F216's, mutate_f166.py RSF-F166's).
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - main.lua's two source() lines for the new modules: the load lists carry them as
#     main.lua does, and this repo has no load-path gate;
#   - the wire layouts' field order in DairyCollectionStatusEvents (write and read are
#     one table, E1 to E3 read them back through the typed stream model): a reordering
#     of one side alone is caught by the stream model's layout check as a fault, which
#     the bar reports as such, not as a mutation of behaviour;
#   - the route generation's wrap at 2^32 minus 1: unreachable in a bench run;
#   - the failover leaving the scoped replica in place: the getter reads only the selected
#     route's store and the route is DIRECT after a failover, so the scoped replica is
#     never read again (equivalent by the stores-never-cross rule);
#   - the first-due touch (DairyCoreManager.lua:1239) alone: assignment sets the next due
#     before any tick, so a barn with a worker and no due reaches that branch only from a
#     save that predates the milk round fields, which the bench does not carry;
#   - the response's in-memory row-count check (rows against chunkRowCount): unreachable
#     through the wire, since readStream reads exactly chunkRowCount rows and a header
#     claiming more faults the stream before the event runs (row X4); only a server that
#     builds its own header wrong could reach it.
#   - the owner-reconciliation touch (DairyCoreManager.lua:1201) alone: reconciliation runs
#     inside discoverBarns, whose census-change touch (:346) fires on the same pass, so
#     removing the inner touch changes no revision the bar can see (equivalent; row O3c
#     pins that the revision moves on reconciliation, whichever touch does it).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_dc14b.py [id-prefix ...]

import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

RT = "src/DairyCollectionRoute.lua"
EV = "src/network/DairyCollectionStatusEvents.lua"
RF = "src/DairyCollectionRefusal.lua"
MGR = "src/DairyCoreManager.lua"

MUTATIONS = [
 # ── route selection and the bounded wait ─────────────────────────────────
 ("RT1-registration-refused-still-scoped", RT,
  [("            st.route = \"DIRECT\"\n            rtLog(\"client route DIRECT (scoped registration refused)\")",
    "            st.route = \"NS_SCOPED\"\n            rtLog(\"client route DIRECT (scoped registration refused)\")", 1)],
  "a refused scoped registration is treated as a scoped route: the client waits on a replica that never comes"),
 ("RT2-wait-unbounded", RT,
  [("    if st.nsWaitMs >= rtCfg().NS_WAIT_MS then\n        st.route = \"DIRECT\"", "    if false then\n        st.route = \"DIRECT\"", 1)],
  "the scoped-service wait never ends: no DIRECT fallback"),

 # ── failover ──────────────────────────────────────────────────────────────
 ("RT3-failover-keeps-generation", RT,
  [("    st.generation = st.generation >= 4294967295 and 1 or st.generation + 1\n    st.route = \"DIRECT\"\n    st.nsFailedOver = true",
    "    st.route = \"DIRECT\"\n    st.nsFailedOver = true", 1)],
  "a failover keeps the route generation: a late scoped publication of the old generation can still apply"),
 ("RT5-no-failover-on-terminal", RT,
  [("        if st.nsFatal then\n            self:_collectionFailOver(\"TERMINAL\")\n            return\n        end", "        if st.nsFatal then\n            return\n        end", 1)],
  "a terminal scoped failure never fails over: the view waits forever"),
 ("RT6-availability-clock-unbounded", RT,
  [("                if st.nsClockMs >= rtCfg().NS_AVAILABILITY_MS then\n                    self:_collectionFailOver(\"NO_APPLIED_IN_TIME\")\n                end\n", "", 1)],
  "ten visible seconds without a replica never move the endpoint to DIRECT"),

 # ── DIRECT: the client side ───────────────────────────────────────────────
 ("RT7-direct-timeout-never", RT,
  [("            if out.ageMs >= rtCfg().DIRECT_TIMEOUT_MS then", "            if false then", 1)],
  "a DIRECT request never times out: no retry, no UNAVAILABLE"),
 ("RT8-foreign-chunk-applied", RT,
  [("    if out == nil or ev.routeGeneration ~= out.generation or ev.viewGeneration ~= out.viewGeneration\n        or ev.requestSequence ~= out.sequence then\n        return   -- a different generation, token or sequence: not ours any more\n    end",
    "    if out == nil then\n        return\n    end", 1)],
  "a reply of another generation, token or sequence is staged as ours"),
 ("RT9-farm-mismatch-applied", RT,
  [("    if farmId == nil or ev.farmIdOr0 ~= farmId then\n        rtDiscard(st, \"FARM\")\n        return\n    end",
    "    if farmId == nil then\n        rtDiscard(st, \"FARM\")\n        return\n    end", 1)],
  "a reply for another farm is applied as this farm's view"),
 ("RT10-header-mismatch-tolerated", RT,
  [("    elseif staging.totalRowCount ~= ev.totalRowCount or staging.chunkCount ~= ev.chunkCount or staging.farmId ~= ev.farmIdOr0 then\n        rtDiscard(st, \"HEADER\")\n        return\n    end",
    "    end", 1)],
  "chunks with inconsistent headers are merged into one staging set"),
 ("RT11-duplicate-chunk-tolerated", RT,
  [("    if staging.chunks[ev.chunkIndex] ~= nil then\n        rtDiscard(st, \"DUPLICATE_CHUNK\")\n        return\n    end\n", "", 1)],
  "a repeated chunk index overwrites and counts again"),
 ("RT12-population-mismatch-applied", RT,
  [("    if staging.rowsReceived ~= staging.totalRowCount then\n        rtDiscard(st, \"POPULATION\")\n        return\n    end\n", "", 1)],
  "a staging set whose rows do not add up to the header's total is applied"),
 ("RT13-timeout-keeps-replica", RT,
  [("                st.directOutstanding = nil\n                st.directReplica = nil\n                st.directTimedOut = true", "                st.directOutstanding = nil\n                st.directTimedOut = true", 1)],
  "a timed-out request leaves the previous DIRECT replica showing as current"),

 # ── DIRECT: the server side ───────────────────────────────────────────────
 ("RT14-rate-limit-off", RT,
  [("    return rec.count <= limit\n", "    return true\n", 1)],
  "the per-connection request rate is unlimited"),
 ("RT15-chunking-unbounded", RT,
  [("        if currentBytes + rowBytes > C.DIRECT_BUDGET_BYTES or #current >= C.DIRECT_MAX_ROWS_PER_CHUNK then", "        if false then", 1)],
  "every row goes in one chunk whatever the byte budget or the row cap"),

 # ── the wire ──────────────────────────────────────────────────────────────
 ("EV1-response-chunk-index-unchecked", EV,
  [("    if ev.chunkIndex >= ev.chunkCount then return false, \"COUNT\" end\n", "", 1)],
  "a chunk index past the chunk count is a valid response"),

 # ── the getter's client branch and row 94's latch ─────────────────────────
 ("RF1-live-miss-latch-removed", RF,
  [("            barn._collectionLiveMiss = true\n            self:_touchCollectionRefusal()\n", "            barn._collectionLiveMiss = true\n", 1)],
  "a demolished barn's row drops from the getter but the revision waits for the next discovery pass"),
 ("RF2-client-answers-local-rows", RF,
  [("    if not self:_isServer() then\n        return self:_collectionClientView(farmId)\n    end\n", "", 1)],
  "a pure client answers the local producer's rows instead of its route"),
 ("RT16-client-waiting-reads-as-ready", RT,
  [("    local function waiting(reason) return { state = C.STATES.WAITING, reason = reason, rows = {} } end",
    "    local function waiting(reason) return { state = C.STATES.READY, reason = nil, rows = {} } end", 1)],
  "a pure client with no snapshot reads no-report instead of updating (slice A's V8, re-homed with the client branch)"),

 # ── the two revision touches Bob named on #60 ─────────────────────────────
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
