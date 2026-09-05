#!/usr/bin/env python3
"""fm-linear-archive-csv.py - convert a firstmate done-archive into a Linear CSV import file.

This is the one-shot converter for DEV-46: it turns firstmate's append-only
completed-task archive (`data/done-archive.md` in a fleet home) into a CSV in the
shape Linear's own "Linear (CSV)" importer reads, so the fleet's completed work
becomes searchable history inside Linear instead of a 10k-line Markdown file.

Input grammar (verified against the real archive, 10,768 lines):

    ## Archived YYYY-MM-DD        archive-date header; may carry zero or more bullets
    - [x] <task-id> - <body>      one completed task
      <continuation>              indented lines belong to the preceding bullet

A header with no bullets is legal (30 occur in the real archive) and contributes
no issue. Three headers in the real archive instead carry an indented block with
no bullet above it - captain decision records appended without a task line. Those
are real content, so they become issues too, with the synthetic id
`archive-note-L<line>` and the label `kind:archive-note`, rather than being
dropped. Every remaining non-blank line shape is reported as unparsed rather than
dropped: `--strict` turns any unparsed line into a non-zero exit.

Output columns are the subset of Linear's export schema that the importer reads
(see packages/import/src/importers/linearCsv/LinearCsvImporter.ts):

    Id,Title,Description,Status,Priority,Project,Labels,Created,Completed

`Archived` is deliberately NOT emitted: the importer skips any row with a
non-empty Archived value, so emitting it would silently import nothing.

Date semantics, chosen because the archive records two different moments:
  - Completed is the `## Archived` header date, the date the fleet recorded the
    task as finished. It always exists, so every row has a completion date.
  - Created is the earliest in-body date signal (`(done ...)`, `(reported ...)`,
    `(merged ...)`) when present, else the same archive date. Created is
    therefore never later than Completed.

Every description carries one machine-readable `fm-meta:` line. It makes the
import idempotent in practice: a second import can be detected by searching
Linear for `fm-meta: v1 id=<task-id>`, and any imported issue traces back to its
exact source line in the frozen archive.

Usage:
  fm-linear-archive-csv.py <archive.md> --csv <out.csv> [--summary <out.md>]
  fm-linear-archive-csv.py <archive.md> --keys            # one fm-meta key per line
  fm-linear-archive-csv.py <archive.md> --csv - --quiet   # CSV on stdout

Options:
  --csv <path>       write the Linear import CSV ('-' for stdout)
  --summary <path>   write a Markdown dry-run summary ('-' for stdout)
  --keys             print the stable fm-meta key of every issue and exit
  --project <name>   value for the Project column (default: empty)
  --status <name>    value for the Status column (default: Done)
  --strict           exit non-zero if any input line could not be classified
  --quiet            suppress the stderr one-line report
  -h, --help         print this header

Determinism: output depends only on the input bytes and the flags. Running twice
on the same archive produces byte-identical CSV, which is what makes a dry run
meaningful before a one-shot 10k-issue import that would be tedious to undo.

Exit status: 0 on success, 1 on a usage or IO error, 2 under --strict when the
parser could not classify at least one line.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import re
import sys
from collections import Counter
from dataclasses import dataclass, field

FM_META_VERSION = "v1"
DEFAULT_STATUS = "Done"
TITLE_MAX = 120

HEADER_RE = re.compile(r"^## Archived (\d{4}-\d{2}-\d{2})\s*$")
BULLET_RE = re.compile(r"^- \[x\] (\S+) - (.*)$")
CONTINUATION_RE = re.compile(r"^\s+\S")
FIELD_RE = re.compile(r"\((repo|kind|harness): ([^)]*)\)")
DATE_FIELD_RE = re.compile(r"\((done|reported|merged) (\d{4}-\d{2}-\d{2})\)")

# Leading characters a spreadsheet would read as a formula. Linear's own export
# escapes these with a leading apostrophe and its importer strips that
# apostrophe back off, so matching the convention keeps the round trip lossless.
FORMULA_LEAD = "+-=@\u2211\u221a\u220f<>\uff1c\uff1e\u2264\u2265\uff1d\u2260\u00b1\u00f7\u00d7"


@dataclass
class Issue:
    task_id: str
    body: str
    continuations: list[str] = field(default_factory=list)
    archived: str = ""
    line_no: int = 0
    # An orphan indented block under a bullet-less archive header: real content
    # with no task line of its own, kept as an issue so nothing is lost.
    note: bool = False

    @property
    def full_body(self) -> str:
        parts = [self.body] + [c.strip() for c in self.continuations]
        return "\n".join(p for p in parts if p)

    @property
    def repo(self) -> str:
        return self._field("repo")

    @property
    def kind(self) -> str:
        return self._field("kind")

    def _field(self, name: str) -> str:
        for match_name, value in FIELD_RE.findall(self.body):
            if match_name == name:
                return value.strip()
        return ""

    @property
    def created(self) -> str:
        """Earliest in-body date signal, else the archive date."""
        dates = sorted(value for _, value in DATE_FIELD_RE.findall(self.full_body))
        if dates and dates[0] <= self.archived:
            return dates[0]
        return self.archived

    @property
    def completed(self) -> str:
        return self.archived

    @property
    def digest(self) -> str:
        payload = f"{self.task_id}\n{self.archived}\n{self.full_body}"
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]

    @property
    def key(self) -> str:
        """Stable duplicate-detection key, also embedded in the description."""
        return (
            f"fm-meta: {FM_META_VERSION} id={self.task_id} line={self.line_no} "
            f"archived={self.archived} digest={self.digest}"
        )

    @property
    def labels(self) -> list[str]:
        out = ["fm-archive"]
        if self.repo:
            out.append(f"repo:{self.repo}")
        if self.kind:
            out.append(f"kind:{self.kind}")
        elif self.note:
            out.append("kind:archive-note")
        return out

    @property
    def title(self) -> str:
        if self.note:
            return truncate_title(self._note_title())
        summary = self.body.split("\n", 1)[0].strip()
        # Drop the trailing metadata parens; they live in the description and in
        # labels, and they crowd out the human-readable part of a title.
        summary = FIELD_RE.sub("", summary)
        summary = DATE_FIELD_RE.sub("", summary)
        summary = re.sub(r"\(resume: [^)]*\)", "", summary)
        summary = re.sub(r"\s+", " ", summary).strip(" -")
        title = f"{self.task_id}: {summary}" if summary else self.task_id
        return truncate_title(title)

    def _note_title(self) -> str:
        """Best human title for an orphan note: its own Markdown heading if it has one."""
        for line in self.full_body.split("\n"):
            stripped = line.lstrip("# ").strip()
            if line.lstrip().startswith("#") and stripped:
                return f"Archive note {self.archived}: {stripped}"
        first = self.full_body.split("\n", 1)[0].strip()
        return f"Archive note {self.archived}: {first}" if first else f"Archive note {self.archived}"

    @property
    def description(self) -> str:
        return f"{self.full_body}\n\n{self.key}"


def truncate_title(title: str) -> str:
    if len(title) <= TITLE_MAX:
        return title
    cut = title[: TITLE_MAX - 1]
    if " " in cut[TITLE_MAX // 2 :]:
        cut = cut[: cut.rfind(" ")]
    return cut.rstrip() + "\u2026"


def escape_formula(value: str) -> str:
    """Match Linear's export convention for cells a spreadsheet would evaluate."""
    if value and value[0] in FORMULA_LEAD:
        return "'" + value
    return value


@dataclass
class ParseResult:
    issues: list[Issue]
    headers: int
    empty_headers: int
    unparsed: list[tuple[int, str]]
    notes: int = 0


def parse_archive(text: str) -> ParseResult:
    issues: list[Issue] = []
    unparsed: list[tuple[int, str]] = []
    headers = 0
    empty_headers = 0
    current_date: str | None = None
    header_had_bullet = False
    current: Issue | None = None

    for line_no, line in enumerate(text.split("\n"), start=1):
        header = HEADER_RE.match(line)
        if header:
            if current_date is not None and not header_had_bullet:
                empty_headers += 1
            current_date = header.group(1)
            header_had_bullet = False
            current = None
            headers += 1
            continue

        bullet = BULLET_RE.match(line)
        if bullet:
            if current_date is None:
                unparsed.append((line_no, line))
                continue
            current = Issue(
                task_id=bullet.group(1),
                body=bullet.group(2).strip(),
                archived=current_date,
                line_no=line_no,
            )
            issues.append(current)
            header_had_bullet = True
            continue

        if not line.strip():
            continue

        if CONTINUATION_RE.match(line):
            if current is None:
                if current_date is None:
                    unparsed.append((line_no, line))
                    continue
                # Orphan indented block: open a note issue for this header scope.
                current = Issue(
                    task_id=f"archive-note-L{line_no}",
                    body="",
                    archived=current_date,
                    line_no=line_no,
                    note=True,
                )
                issues.append(current)
                header_had_bullet = True
            current.continuations.append(line)
            continue

        unparsed.append((line_no, line))

    if current_date is not None and not header_had_bullet:
        empty_headers += 1

    notes = sum(1 for issue in issues if issue.note)
    return ParseResult(issues, headers, empty_headers, unparsed, notes)


CSV_COLUMNS = [
    "Id",
    "Title",
    "Description",
    "Status",
    "Priority",
    "Project",
    "Labels",
    "Created",
    "Completed",
]


def write_csv(issues: list[Issue], handle, status: str, project: str) -> None:
    writer = csv.writer(handle, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    writer.writerow(CSV_COLUMNS)
    for issue in issues:
        writer.writerow(
            [
                issue.digest,
                escape_formula(issue.title),
                escape_formula(issue.description),
                status,
                "No priority",
                project,
                ", ".join(issue.labels),
                issue.created,
                issue.completed,
            ]
        )


def render_summary(result: ParseResult, source: str, status: str, project: str) -> str:
    issues = result.issues
    label_counts: Counter[str] = Counter()
    for issue in issues:
        for label in issue.labels:
            label_counts[label] += 1
    dates = sorted(issue.completed for issue in issues)
    id_counts = Counter(issue.task_id for issue in issues)
    repeated = sorted(i for i, n in id_counts.items() if n > 1)

    out = io.StringIO()
    out.write("# DEV-46 archive conversion dry run\n\n")
    out.write(f"- source: `{source}`\n")
    out.write(f"- issues: {len(issues)}\n")
    out.write(f"- archive-date headers: {result.headers} ({result.empty_headers} with no task)\n")
    out.write(f"- of those issues, orphan archive notes (indented block, no task line): {result.notes}\n")
    out.write(f"- completion date range: {dates[0] if dates else 'n/a'} .. {dates[-1] if dates else 'n/a'}\n")
    out.write(f"- Status column: `{status}`\n")
    out.write(f"- Project column: `{project or '(empty)'}`\n")
    out.write(f"- unparsed lines: {len(result.unparsed)}\n")
    out.write(f"- task ids appearing more than once: {len(repeated)}\n")
    if repeated:
        out.write("  (an id is reused when the same lane ran twice; the fm-meta digest still separates them)\n")
        for task_id in repeated:
            out.write(f"  - `{task_id}` x{id_counts[task_id]}\n")

    out.write("\n## Label distribution\n\n")
    out.write("| Label | Issues |\n| --- | --- |\n")
    for label, count in sorted(label_counts.items(), key=lambda kv: (-kv[1], kv[0])):
        out.write(f"| `{label}` | {count} |\n")

    out.write("\n## Issues per archive month\n\n")
    month_counts = Counter(d[:7] for d in dates)
    out.write("| Month | Issues |\n| --- | --- |\n")
    for month, count in sorted(month_counts.items()):
        out.write(f"| {month} | {count} |\n")

    out.write("\n## Unparsed lines\n\n")
    if result.unparsed:
        for line_no, line in result.unparsed:
            out.write(f"- L{line_no}: `{line[:200]}`\n")
    else:
        out.write("None. Every non-blank line was classified as a header, a task, or a task continuation.\n")
    return out.getvalue()


def open_out(path: str):
    if path == "-":
        return sys.stdout, False
    return open(path, "w", encoding="utf-8", newline=""), True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("archive", nargs="?")
    parser.add_argument("--csv")
    parser.add_argument("--summary")
    parser.add_argument("--keys", action="store_true")
    parser.add_argument("--project", default="")
    parser.add_argument("--status", default=DEFAULT_STATUS)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args(argv)

    if args.help or not args.archive:
        sys.stdout.write(__doc__ or "")
        return 0 if args.help else 1

    try:
        text = open(args.archive, encoding="utf-8").read()
    except OSError as exc:
        sys.stderr.write(f"fm-linear-archive-csv.py: cannot read archive: {exc}\n")
        return 1

    result = parse_archive(text)

    if args.keys:
        for issue in result.issues:
            sys.stdout.write(issue.key + "\n")
        return 2 if (args.strict and result.unparsed) else 0

    if not args.csv and not args.summary:
        sys.stderr.write("fm-linear-archive-csv.py: nothing to do; pass --csv, --summary, or --keys\n")
        return 1

    if args.csv:
        handle, close = open_out(args.csv)
        try:
            write_csv(result.issues, handle, args.status, args.project)
        finally:
            if close:
                handle.close()

    if args.summary:
        handle, close = open_out(args.summary)
        try:
            handle.write(render_summary(result, args.archive, args.status, args.project))
        finally:
            if close:
                handle.close()

    if not args.quiet:
        sys.stderr.write(
            f"fm-linear-archive-csv.py: {len(result.issues)} issues, "
            f"{result.headers} archive headers, {len(result.unparsed)} unparsed lines\n"
        )

    if result.unparsed and args.strict:
        for line_no, line in result.unparsed[:20]:
            sys.stderr.write(f"unparsed L{line_no}: {line[:160]}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
