# FS25_DairyCore self-tests

Offline logic tests. They run the **real** `src/` modules inside a Lua VM
([fengari](https://fengari.io/)) under a small engine mock, so an assertion here is
against shipped code rather than against a copy of it.

```bash
bash tools/test/run.sh      # installs deps on first run, then runs everything
```

Nothing here ships: `build.sh` packs an allowlist (`modDesc.xml`, `icon.dds`,
`main.lua`, `src`, `translations`) that does not include `tools`.

## Adding a test

Drop a `*_test.lua` in `lua/`. Declare which real source files it needs with a header
line, and the runner concatenates the prelude, those files, and your test into one
program:

```lua
--!load: src/Logger.lua, src/DairyConstants.lua, src/DairyCoreManager.lua
```

Assertions are `T.ok(name, cond)`, `T.eq(name, got, want)` and
`T.near(name, got, want, tol)`. `lua/prelude.lua` holds the engine mock; extend it
when a test needs more surface, and keep anything test-specific (an `XMLFile` stand-in,
a capturing logger) in the test file itself.

## What is covered

`dc13_persistence_sync_test.lua` pins DC-13, the four defects the member shipped
with. All four were **silent**: none raised, none logged, and three of them looked
like correct behaviour from outside. F80 the sheared sync array, F79 the ungated
ticks, F84 contracts that were never persisted without StateLedger, F83 a mycotoxin
countdown that was never saved.

It carries the finish-line condition DC-14 states as a test: no field on a client is
locally computed, **and** no field reports another barn's value. The second half is
there because the first does not catch a mis-aligned read.
