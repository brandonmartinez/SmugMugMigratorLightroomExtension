# Lightroom Classic → SmugMug Publish Service to Collections Migrator

A Lightroom Classic SDK plugin that walks the official SmugMug publish
service in your catalog and creates matching built-in collection sets and
collections under a `_archive` root. Once it has finished and you've
verified the result, you can safely remove the SmugMug plugin — your
albums (and their photos) now live in regular Lightroom collections.

The plugin **only modifies Lightroom collections inside your catalog**. It
never touches photo files on disk, never re-uploads anything, and never
modifies or removes the SmugMug publish service itself.

---

## What it does

Given this structure inside the SmugMug publish service:

```
SmugMug  (publish service)
└── Client Download                    ← root folder, ignored
    └── <Client Name>                  ← folder (publish collection set)
        └── YYYYMMDD - Album Name      ← gallery (published collection)
            └── photos…
```

…it produces this inside your built-in `Collections` panel:

```
Collections
└── _archive                            (collection set, created if missing)
    └── <Client Name>                   (collection set)
        └── YYYY-MM-DD - Album Name     (regular collection, populated with
                                         the same photos)
```

Rules in detail:

- The immediate child set named **`Client Download`** is skipped; its
  children rebase directly onto `_archive`.
- Other folder (publish collection set) names are preserved as collection
  set names (with trimming).
- Gallery names matching `YYYYMMDD - Name` are rewritten to
  `YYYY-MM-DD - Name`. The 8-digit prefix is validated as a real calendar
  date (including leap years); names that don't match the pattern, or
  match but contain an invalid date, are copied verbatim and flagged in
  the report.
- If a target collection already exists, it is **skipped** (no photo
  changes, no overwriting). A separate per-album write transaction also
  re-checks before creating, so a concurrent change won't cause the run
  to clobber an existing collection.

---

## Modes

The plugin presents a mode picker on launch:

| Mode    | Behaviour                                                                          |
| ------- | ---------------------------------------------------------------------------------- |
| Dry-run | Walks the tree, computes mappings, runs preflight, and writes the full plan to a log file. **No changes** to your catalog. |
| Batch   | Runs the migration end-to-end with a single progress bar. Each album is its own short transaction so failures isolate to a single album. |
| Guided  | For each album, shows a Create / Skip / Abort dialog with the source path, target path, and photo count.                                |

A run report dialog appears at the end with counts and a button to reveal
the log file in Finder.

Logs are written under:

```
~/Documents/SmugMugMigrator/migration-YYYYMMDD-HHMMSS.log
```

---

## Installation

1. Quit Lightroom Classic if it's open.
2. Copy the `SmugMugMigrator.lrplugin/` folder to a stable location on
   your machine (e.g. `~/Library/Application Support/Adobe/Lightroom/Modules/`
   on macOS, or anywhere persistent).
3. Launch Lightroom Classic.
4. **File → Plug-in Manager…** → click **Add**, point at
   `SmugMugMigrator.lrplugin`, click **Add Plug-in**. The plugin should
   show as enabled with no errors.
5. Switch to the **Library** module.
6. **Library → Plug-in Extras → Migrate SmugMug to Collections…**

---

## Recommended workflow

1. **Back up your catalog first.** `File → Catalog Settings → General →
   Back up catalog: When Lightroom next exits.` Then exit and back up.
2. Launch the plugin in **Dry-run** mode and review the log. Confirm
   that:
   - The right SmugMug publish service was selected.
   - The expected number of albums was discovered.
   - There are no surprising warnings (invalid dates, duplicate target
     paths, non-standard folder names, `_archive` collisions).
3. Re-run in **Guided** mode for a small number of albums to verify
   behaviour, or jump straight to **Batch** mode if dry-run looks clean.
4. Once you've confirmed the new `_archive` tree looks right, you can
   remove the SmugMug plugin via `File → Plug-in Manager` → select
   SmugMug → **Remove**.

---

## Recovery / rollback

The plugin never deletes anything you didn't ask it to. If something
looks wrong after a run, the rollback is simple:

- Open the **Collections** panel.
- Right-click `_archive` → **Delete**. This removes the migrated
  collection sets and collections from your catalog. Your photos and the
  SmugMug publish service are untouched.

---

## Report fields

The summary dialog (and the log) tracks:

| Field                                           | Meaning |
| ----------------------------------------------- | ------- |
| Collection sets created                         | New `_archive`/client folders this run created. |
| Collection sets already present                 | `_archive` or client sets that already existed. |
| Collection set collisions                       | A required set's name was occupied by a collection. |
| Collections created                             | New album collections this run created.        |
| Collections skipped (already existed)           | Album collections that were already there.     |
| Collection collisions                           | Album target name occupied by a set, or ancestor blocked. |
| Collection duplicate-target conflicts           | Multiple source galleries mapped to the same target path (must be resolved upstream). |
| Photos added to collections                     | Total LrPhoto additions across all created collections. |
| Published photos that could not resolve         | Stale SmugMug publish records whose underlying photo could not be resolved. |
| Album errors                                    | Per-album exceptions from the SDK during the write transaction. |
| Name/structure warnings                         | Non-fatal: invalid dates, non-`Client Download` roots, root-level galleries, empty folder names. |

---

## Limitations / out of scope

- The SmugMug publish service and its published collections are left
  intact. Removing them is a manual step.
- The plugin does not modify photo files, re-upload to SmugMug, or
  download anything from SmugMug.
- Only regular (manual) collections are created — not smart collections.
- The plugin matches the SmugMug publish service by plugin id and
  display-name containing `smugmug` (case-insensitive). If multiple
  candidates are found, you're prompted to pick one (up to two are
  shown in the picker dialog; for more, disable extras and rerun).

---

## Development

Pure-logic modules (no Lightroom SDK dependency) are unit-tested with a
local Lua interpreter:

```sh
brew install lua  # one-time
cd SmugMugMigrator.lrplugin/tests
lua test_namemapping.lua
lua test_planner.lua
lua test_preflight.lua
```

Module layout:

```
SmugMugMigrator.lrplugin/
├── Info.lua                  plugin manifest + Library menu entry
├── MigrationMain.lua         entry point: mode dialog + async task
├── ModeDialog.lua            Dry-run / Batch / Guided picker
├── GuidedDialog.lua          per-album Create / Skip / Abort
├── ReportDialog.lua          final summary dialog
├── SmugMugDiscovery.lua      publish-service discovery + tree walk
├── NameMapping.lua           "Client Download" skip + date transform
├── Planner.lua               pure plan construction
├── Preflight.lua             SDK-aware classification (existing / collision / dup)
├── ArchiveTarget.lua         find/check _archive root set
├── Migrator.lua              executes the plan
└── Logger.lua                file-backed run log
```

---

## License

MIT (or whatever you prefer — adjust as needed).
