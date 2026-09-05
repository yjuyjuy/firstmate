# One-shot import artifacts

This directory holds frozen source data and generated artifacts for one-off imports of fleet data into an external tracker. It is deliberately separate from `docs/`'s narrative documents: these files are evidence for a specific migration, not instructions that stay true forever.

## DEV-46: firstmate done-archive to Linear

| File | What it is |
| --- | --- |
| `dev-46-done-archive.md` | Frozen snapshot of one fleet home's `data/done-archive.md`, taken 2026-09-04 |
| `dev-46-linear-import.csv` | The Linear import CSV generated from that snapshot |
| `dev-46-dry-run.md` | Generated dry-run summary: counts, date range, label distribution, unparsed lines |

The converter is [`bin/fm-linear-archive-csv.py`](../../bin/fm-linear-archive-csv.py); its header is the authoritative description of the grammar it parses, the columns it emits, and the date semantics it chose. Its behavior tests are `tests/fm-linear-archive-csv.test.sh`.

Regenerate both artifacts from the frozen snapshot with:

```sh
python3 bin/fm-linear-archive-csv.py docs/imports/dev-46-done-archive.md \
  --csv docs/imports/dev-46-linear-import.csv \
  --summary docs/imports/dev-46-dry-run.md \
  --strict
```

The output is deterministic, so a regeneration on an unchanged snapshot produces byte-identical files and shows an empty diff.

### Why the archive is frozen here

A fleet home's `data/` is gitignored personal state, so the live archive is not reviewable and keeps growing while the import is being prepared. Copying it here makes the import auditable: the pull request that adds the converter also carries the exact bytes the CSV was generated from, so a reviewer can regenerate the CSV and compare, and a future question about an imported issue resolves against a file that has not moved. `docs/` is the natural home because this is reviewable documentation of a migration rather than tooling configuration; nothing here is read at runtime by any fleet script.

This snapshot is not tracked personal fleet state in the sense the CI invariant guards: it is a deliberate, one-time, content-reviewed copy committed under `docs/`, not a live `data/` path wired into a running home.

### Why the CSV is committed

The CSV is generated, and a generated artifact usually does not belong in git. It is committed here anyway for two reasons specific to this import. First, the captain uploads it from a phone or another machine, so it must be reachable as a raw download from the repository rather than as a path on the fleet host. Second, the import is a one-shot action over 1,409 issues that is tedious to undo, so the exact bytes that were uploaded should be recoverable afterwards.

### Duplicate detection

Every generated description carries a marker line:

```
fm-meta: v1 id=<task-id> line=<line-in-snapshot> archived=<YYYY-MM-DD> digest=<sha256-prefix>
```

The digest covers the task id, the archive date, and the full body, so a task id that appears twice in the archive still yields two distinct markers. Searching Linear for a digest answers whether that specific archived task is already imported, which is what makes a second import safe to reason about.

Print every marker without generating a CSV:

```sh
python3 bin/fm-linear-archive-csv.py docs/imports/dev-46-done-archive.md --keys
```
