# One-shot import artifacts

This directory documents one-off imports of fleet data into an external tracker. It holds the reusable, publishable half of such an import: the converter's documentation and the contract its output satisfies. The data itself does not live here.

## DEV-46: firstmate done-archive to Linear

The converter is [`bin/fm-linear-archive-csv.py`](../../bin/fm-linear-archive-csv.py); its header is the authoritative description of the grammar it parses, the columns it emits, and the date semantics it chose. Its behavior tests are `tests/fm-linear-archive-csv.test.sh`.

### Where the data lives, and why not here

A fleet home's `data/` holds that captain's private operational history. For DEV-46 the source archive is a fleet's complete record of completed engineering work, which names internal systems, source locations, and identifiers belonging to the projects the fleet worked on. This repository is a shared, public template, so committing one fleet's archive here would publish that history permanently and irreversibly to everyone who clones the template.

So the frozen snapshot, the generated CSV, and the generated dry-run summary all stay in the operating home under `data/dev-46-prep/`, alongside the runbook and the spot-check evidence. Only the converter, its tests, and this document are shared.

The same rule applies to any future import: publish the tool, keep the payload in the home that owns it.

### Running the conversion

From a fleet home, against that home's own archive:

```sh
python3 bin/fm-linear-archive-csv.py <home>/data/done-archive.md \
  --csv <home>/data/<task>/linear-import.csv \
  --summary <home>/data/<task>/dry-run.md \
  --strict
```

`--strict` exits non-zero if any input line could not be classified as an archive header, a task, or a task continuation, so a silent drop cannot pass unnoticed. The output is deterministic: a regeneration over an unchanged archive produces byte-identical files, which is what makes a dry run meaningful before a one-shot import that would be tedious to undo.

### Duplicate detection

Every generated description carries a marker line:

```
fm-meta: v1 id=<task-id> line=<line-in-snapshot> archived=<YYYY-MM-DD> digest=<sha256-prefix>
```

The digest covers the task id, the archive date, and the full body, so a task id that appears twice in the archive still yields two distinct markers. Searching the tracker for a digest answers whether that specific archived task is already imported, which is what makes a second import safe to reason about.

Print every marker without generating a CSV:

```sh
python3 bin/fm-linear-archive-csv.py <home>/data/done-archive.md --keys
```

### Verifying against a real archive

The behavior tests run entirely on generated fixtures, so they pass in CI with no fleet data present. To additionally exercise the converter against a real archive, point `FM_DEV46_ARCHIVE` at one:

```sh
FM_DEV46_ARCHIVE=<home>/data/done-archive.md tests/fm-linear-archive-csv.test.sh
```

That case asserts the real file converts with zero unparsed lines and no malformed row. It is skipped, not failed, when the variable is unset.
