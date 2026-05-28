# Copilot instructions — SmugMug → Lightroom Collections migrator

## Project at a glance

- Lightroom Classic SDK plugin, written in Lua, lives entirely under
  `SmugMugMigrator.lrplugin/`.
- Lightroom embeds **Lua 5.1**. Tests run on whatever local Lua is
  installed (currently Homebrew Lua 5.5), but the only true target is
  Lightroom's Lua 5.1 — do not use 5.2+ syntax (`goto`, integer division
  `//`, `table.unpack` over `unpack`, etc.) in `*.lua` files inside the
  plugin.
- Pure-logic modules (`NameMapping`, `Planner`, `Preflight`) have unit
  tests under `SmugMugMigrator.lrplugin/tests/`. SDK-touching modules
  (`Migrator`, `MigrationMain`, the dialog files, `Logger`,
  `ArchiveTarget`, `SmugMugDiscovery`) are **not** unit-tested because
  they need a live Lightroom — they are validated by `luac -p` and by
  real dry-runs.

## Version-bump policy (read before every commit)

**Every commit that changes runtime behavior of the plugin must bump
`VERSION` in `SmugMugMigrator.lrplugin/Info.lua` in the same commit.**
Lightroom caches plugin bytecode; without a version bump the operator
cannot tell from the log whether their reload actually took effect.
`MigrationMain` logs the version on line 2 of every run, so a bumped
version is the operator's single point of verification.

- **Bump required** when modifying any of:
  - `SmugMugMigrator.lrplugin/*.lua` (anything that ships in the plugin
    and executes inside Lightroom)
  - `SmugMugMigrator.lrplugin/Info.lua` itself
- **Bump NOT required** for changes scoped to:
  - `README.md`, `.gitignore`, anything under `.github/`
  - `SmugMugMigrator.lrplugin/tests/**`
  - Pure comment-only / docstring-only edits to plugin Lua files
    (use judgment — if in doubt, bump)

Bump rules — the version 4-tuple is `{ major, minor, revision, build }`:

- **Bug fix** → `revision +1`, reset `build` to 0
- **New behavior / feature / observable change** → `minor +1`, reset
  `revision` and `build` to 0
- **Breaking redesign / new workflow / output format change** →
  `major +1`, reset the rest

Always update the version in the same commit as the change; do not let a
"forgot to bump" follow-up commit happen — that defeats the purpose.

## Lightroom SDK gotchas (each of these has burned a real run)

1. **Never wrap a yieldable SDK call in standard `pcall`.** Lua 5.1 will
   raise `"Yielding is not allowed within a C or metamethod call"`. Use
   `LrTasks.pcall` instead. Known yielding APIs: `catalog:withWriteAccessDo`,
   `LrDialogs.presentModalDialog`, `LrDialogs.message`, `LrTasks.sleep`,
   anything in `LrHttp`, anything that takes a callback that may run on
   another fiber. **Standard `pcall` is fine** for non-yielding code
   (file I/O, `string.format`, `LrProgressScope:done()`, `Logger`).

2. **`catalog:createCollectionSet(name, parent, canReturnExisting)`
   requires `parent = nil` for a top-level set.** Passing the catalog
   object itself raises `"assertion failed!"`. `LrCatalog` responds to
   `getChildCollections()`/`getChildCollectionSets()` the same way an
   `LrCollectionSet` does, so it's tempting to pass `catalog` to make
   read-side code uniform — keep `catalog` for reads, but pass `nil` to
   the create call. `ArchiveTarget.findOrCreate` is the reference.

3. **Newly created collection sets are not reliably introspectable in
   the same write gate** they were created in. `Migrator.ensureSetCreated`
   creates one missing level per `withWriteAccessDo`, exits the gate,
   then re-resolves before creating the next level. Don't try to
   "optimise" this into a single write gate.

4. **Per-album writes go in their own `withWriteAccessDo`** with a TOCTOU
   re-check at the top of the gate (a collection with the same name may
   have appeared between preflight and execution). Photos are resolved
   and de-duped *before* the write gate.

5. **`LrView` factory calls** take a single table where positional
   entries become children and named entries (`spacing`, `bind_to_object`,
   ...) become properties. Build a `rows` table and pass it once via
   `f:column(rows)` to avoid Lua's "is this a positional or named?"
   ambiguity.

## Pre-commit checks (mandatory for any plugin `.lua` change)

```bash
cd SmugMugMigrator.lrplugin
for f in *.lua tests/*.lua; do luac -p "$f" || echo "FAIL $f"; done
(cd tests && for t in test_*.lua; do lua "$t" | tail -1; done)
```

- `luac -p` catches syntax errors that Lightroom would otherwise only
  surface at plugin load.
- The three unit-test suites (NameMapping, Planner, Preflight) should
  all report `all passed`. If adding a behavior to a pure-logic module,
  add or extend tests in the matching `tests/test_*.lua` file.

## Logging conventions

- Logs land at `~/Documents/SmugMugMigrator/migration-YYYYMMDD-HHMMSS.log`.
- `[INFO ]` for normal events; `[WARN ]` for non-fatal anomalies (incl.
  `[gallery-name]` rename misses and `[dry-run]` previews); `[ERROR]`
  for per-album failures. Fatal task-level errors come out of the outer
  `LrTasks.pcall` and are also surfaced via `LrDialogs.message`.
- When adding new failure modes, log both the source path AND the
  target path so the operator can act without opening the catalog.

## Hard rules

- The SmugMug publish service and its records are **read-only**. The
  plugin must never call mutating SmugMug-side APIs or modify publish
  records — migration is one-way SmugMug-publish → native collections.
- No network calls, telemetry, or external dependencies. Plugin must
  run entirely offline.
- No `xpcall` over yieldable SDK code — see SDK gotcha #1.
