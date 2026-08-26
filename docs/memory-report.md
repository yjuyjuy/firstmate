# Memory report

`bin/fm-memory-report.sh` answers one question the same way every time: what is actually eating this machine's memory, and who owns it.
The script's own header owns its flags, exit codes, and contracts; this document records the empirical evidence behind its design decisions, in the backend-verification style `docs/*-backend.md` uses.

All measurements below were taken on 2026-07-24, macOS 24.6.0, on a 16 GB machine running the fleet.

## Why the script exists

On 2026-07-24 that question was answered wrong three times in a row, on a machine at 86% swap while two lanes sat parked waiting for memory.
Each wrong answer was a distinct, reproducible trap rather than bad luck.

1. A filtered process table was reported as truth.
2. The fleet was excluded by accident, because a `node` filter misses agents that run as `claude`.
3. Resident size was compared against Activity Monitor, which reports phys_footprint.
4. Ownership was guessed when `state/*.meta` plainly recorded it.

The script's header maps each trap to the defense that makes it impossible by construction, and `tests/fm-memory-report.test.sh` pins each defense.

## Trap 1 is real and was reproduced

`ps` really does occasionally return a truncated table on this machine.
The first `ps -Ao pid= | wc -l` run while building this script returned **31**.

```
$ ps -Ao pid= | wc -l
      31
```

Forty consecutive samples immediately afterwards returned 649 to 652.

```
$ for i in $(seq 1 40); do ps -Ao pid= | wc -l | tr -d ' '; done | sort -n | uniq -c
   1 649
  29 650
   8 651
   2 652
```

A 31-process reading on a 16 GB machine that is swapping hard is impossible, and it is exactly the reading that was reported as truth during the incident.
This is why the self-check refuses instead of trusting a single sample.

## Why top(1) is the primary measurement

`top`'s MEM column is phys_footprint, the same quantity Activity Monitor's Memory column shows.
Sampling eleven processes and comparing `top -l 1 -o mem -stats pid,mem` against `footprint -p <pid>`:

| pid   | top MEM | footprint |
| ----- | ------- | --------- |
| 32042 | 1044M   | 1044 MB   |
| 64353 | 1016M   | 1016 MB   |
| 159   | 581M    | denied    |
| 68028 | 500M    | 500 MB    |
| 61429 | 479M    | 479 MB    |
| 97979 | 463M    | 464 MB    |
| 99682 | 350M    | 350 MB    |
| 65736 | 343M    | 343 MB    |
| 51977 | 327M    | 328 MB    |
| 92746 | 325M    | 325 MB    |
| 11612 | 303M    | 303 MB    |

A later run through `--verify` reported 0.0% delta on ten of twelve rows.
The rows that differ are live processes drifting between two samples taken moments apart, not a disagreement about what is being measured; a Chrome renderer moved 388 MB to 450 MB to 373 MB across three consecutive runs on its own.

`top` is the primary source rather than `footprint` for two reasons.

Cost: one `top` call covers the whole machine in about 0.4 seconds, while `footprint` costs about 0.03 seconds per pid, roughly 20 seconds for 600 processes.

Coverage: `footprint` is denied on root-owned processes.
Reading pid 159 (WindowServer) returns nothing, so a footprint-only reading would silently drop the very system processes a total has to include.
`top` measures them.
`footprint` remains the cross-check, wired to `--verify`.

## Why rss is never the primary number

Under heavy swap most of a process's memory is compressed out of residency, so `rss` diverges from phys_footprint badly and unevenly - in both directions.

Measured on a live language server during acceptance: phys_footprint 44 MB, rss 99 MB.
Measured on a Chrome helper in the same reading: phys_footprint 1.19 GB, rss 1.49 GB.
Measured on an agent: phys_footprint 269 MB, rss 520 MB.

Ranking by `rss` therefore produces a different and wrong ordering, which is how "the agents are the hogs" was concluded.
The script ranks by phys_footprint and shows `rss` only in its own labelled column.

## Ownership comes from records and working directory, never ancestry

Ancestry lies exactly where attribution matters.
When a process's spawner dies the kernel reparents it to launchd, so it reports ppid 1 - indistinguishable by ancestry alone from a system daemon that launchd started legitimately.

Two processes on this machine were reparented while the script was being written:

```
pid=67870 ppid=1 cwd=/Users/cyuan/.no-mistakes/worktrees/1e4aa769aa9b/01KY8CGMK61NW15HM4JB3RDNKA
pid=76895 ppid=1 cwd=/Users/cyuan/workspace/work/firstmate
```

Both are plainly owned, and ancestry would call both orphans.
That is precisely the misjudgement that closed the incident: two 1 GB language servers were called orphans on the strength of ppid 1, when `state/*.meta` recorded live tasks owning worktrees 13 and 16, the very directories those servers were indexing.

So ownership resolves from the process's working directory, longest-prefix matched against paths read from durable records.
A parent's owner may be inherited only when the working directory is unreadable, and never through ppid 1.
Every row records how it was attributed, so a weaker attribution is always visible as one.

The inverse error matters too.
ppid 1 is normal for launchd-managed apps and daemons, so flagging every ppid-1 process as detached manufactured 98 false findings in an early draft.
The flag is now restricted to kinds that are always spawned by something else, and is labelled a hint that never overrides the owner column.

### pstree was evaluated and deliberately not used

`pstree` is installed here at `/opt/homebrew/bin/pstree`, and it is not an input.

It prints no memory column on macOS, and `pstree --help` documents that it reads `ps -axwwo user,pid,ppid,pgid,command` - the same ancestry this script already collects.
So it contributes no fact, only a rendering of the one axis that lies.
`--tree` groups by owner instead, which is the axis capacity decisions actually run on.
Nothing in the script depends on `pstree` being installed.

## Rollup: the true cost of a worker

An agent spawns its own language server, and on this fleet each costs about 1 GB - three to four times the agent process itself.
A flat per-process ranking therefore understates what a worker really costs, and that understated number is the one capacity decisions were being made on.

Verified end to end during acceptance by running a real `tsserver` with its working directory in a live task worktree:

```
  25546        44 MB      99 MB  lsp     cwd       task:build-fleet-memory-report node .../typescript/bin/tsserver
  task         build-fleet-memory-report              628 MB   14 proc (agent itself 289 MB + 1 language server 44 MB)
```

The owner group reports both the agent's own footprint and the total with children.
Note that the server's binary lives under a different task's worktree while its working directory is the owning task's: ownership followed the working directory, which is the correct answer and the one a binary-path guess would have got wrong.

Rollup is by ownership, not ancestry, so a language server whose parent editor was killed still rolls up to the task whose worktree it is indexing.
That is not hypothetical - during the incident two such servers survived their editor being killed, because they were never the editor's.

## A listening server is never a leftover, 2026-08-01

The reclaim list billed the fleet's shared dev backend as free memory and firstmate acted on it, killing the shared stack and costing a lane its test gate.
It is recorded here because the failure is the incident's exact shape one layer further out: a perfectly correct reading, a process the records genuinely did not claim, and a dangerous conclusion drawn from that absence.

The shared backend is a deliberately-started long-running server that serves the whole fleet.
One lane starts it, and that lane tears down while the server keeps running, so by design no task record claims it.
On the pre-fix code every reclaim-list criterion matched it at once: it ran as `node`, so its kind was `tooling`; it sat in a git checkout no record claimed, so it carried `unclaimed-checkout`; and its starting lane had exited, so it was reparented to `ppid 1` and flagged `no-live-parent`.
All three facts were true, and all three were irrelevant.

A shared stack has no owning task by design, so "unowned" is its natural state, not evidence it is disposable.
The missing signal was that the process holds a listening socket.
A process serving a port is serving something, which is positive evidence it is live work, not an abandoned leftover.

Three changes followed, mirroring the record-set fix that preceded them.

A new `server` class: a process with a `LISTEN` socket that no record claims is surfaced in its own class with its ports, never in the reclaim list.
The listen socket is read from `lsof -a -iTCP -sTCP:LISTEN` into the `FM_MEMREPORT_LISTEN` seam, so it is a fact about the kernel's socket table rather than a guess from the process's path or name.
This branch is checked before the unclaimed-checkout and tooling-leftover branches, so a `node` or `python` server in an unclaimed checkout can never fall through to a leftover class.

A `listening:<ports>` flag on every row, owned or not, so a server's ports always travel with it and a reader can see what it is serving.
The reclaim renderer carries a second, independent guard that excludes any row bearing that flag, so the exclusion does not depend on the classification order alone.

The reclaim context names the excluded servers and their total, the same way it already named excluded agents and applications, so nothing is silently dropped from the accounting.

Note what is deliberately not used: the absence of a local `mongod` is never a liveness test.
A shared stack's database is remote, so it needs no local `mongod`, and treating a missing local database as "the stack is dead" would resurrect exactly this bug.

### Why the tests did not catch it

Every reclaim-list fixture process was either a genuine leftover, an agent, an editor, or an application.
None held a listening socket, so the suite never exercised a server at all, and a class that is never constructed cannot be tested.

The suite now carries a shared-backend fixture (`pid 1010`) that reproduces every pre-fix trigger at once - `node` kind, unclaimed git checkout, reparented to `ppid 1` - and is kept out of the reclaim list solely by its listen socket.
Four tests pin the fix: the server is never reclaimable, it is surfaced in its own class with its ports, multiple ports read as one sorted deduplicated list, and a genuine leftover with no listen socket still reclaims, so the fix cannot have disarmed the class the script exists to make.

## The self-check thresholds

The summed footprint normally sits above used memory, because footprint counts compressed pages and charges shared regions to each process.
Five consecutive samples:

```
sum=13.4GB used=12.0GB ratio=111%
sum=13.4GB used=12.0GB ratio=111%
sum=13.4GB used=12.0GB ratio=111%
sum=13.3GB used=12.0GB ratio=111%
sum=13.4GB used=12.0GB ratio=111%
```

A separate reading under heavier load measured 17.6 GB summed against 14.0 GB used, or 126%.

The floor is therefore one-sided and set at 60%, a 1.85x margin below the lowest ratio actually observed, while still catching a listing that has lost most of the machine's memory.
A one-sided floor is correct here: a sum far above used memory is normal, so only an implausibly small total indicates truncation.

The remaining gates are the plausible-process-count floor, agreement between the `ps` and `top` enumerations, a parseable `PhysMem` line, and the requirement that the script's own pid appears in both listings.
Nothing can enumerate every process while missing the one doing the asking.

A refusal exits 3 and prints no ranking.
That is the correct output when the instrument is broken.

## Linux: /proc is the primary measurement, 2026-08-26

The fleet runs on Linux, where the macOS top call (`-l 1 -n 20000 -o mem -stats pid,mem`) prints nothing and the script died with RC=1 on every run.
The macOS top extraction above documents how the macOS side works; on Linux the primary source is /proc itself.
Each process's `Pss:` is read from `/proc/<pid>/smaps_rollup`, with `VmRSS:` from `/proc/<pid>/status` as the fallback when the mapping table is unreadable (a mapping table needs ptrace permission; `status` is world-readable).
PSS is the honest Linux analog of phys_footprint: it charges shared pages proportionally, so it never double-counts a shared library the way an rss sum does, and it never overstates a swapped-out process.
The reader emits the same normalized listing shape (`Processes:` / `PhysMem:` / `PID` rows) parse_top already reads, so every self-check gate and renderer is shared with the macOS path.
Host totals come from `/proc/meminfo`: `MemTotal` for total, `MemTotal` minus `MemAvailable` for used, and `SwapTotal` minus `SwapFree` for swap (a host with no swap reports `swap none`).
A process whose files race to exit between `ls` and read, a kernel thread, or a zombie gets a 0K row rather than dropping out of the count, so the two enumerations keep agreeing.

The one-sided 60% floor does not transfer to Linux.
Kernel memory and page cache are not process memory, so summed pss normally sits well BELOW used memory.
Measured on 2026-08-26 on the 31 GB fleet host: summed pss 2,956,340 kB against 9,600,480 kB used, a ratio of 30%.
The Linux floor is anchored to the process listing instead: summed pss is refused only when it falls below 30% of the ps listing's summed rss, and the same host measured 66% (2,956,340 kB of pss against 4,442,672 kB of rss), so the floor carries a 2.2x margin below the only observation.
The ceiling stays the 400% rule against used memory: pss cannot double-count a page, so a sum several times the machine's memory still means a broken listing.

## The attribution defect, 2026-07-24

The first version of this script shipped with 25 green tests and ownership broken against every real lane on the machine.
It is recorded here because the shape of the failure matters more than the fix.

Run from a disposable firstmate worktree without `FM_HOME`, the report classified every live crewmate and secondmate as `checkout no record claims` and rolled 4.23 GB across 76 processes into RECLAIMABLE.
Reproduced exactly:

```
  unowned      checkout no record claims             4.23 GB   73 proc (agent itself 2.14 GB)
```

The measurement was perfect.
The reading passed every self-check.
The failure was that `FM_HOME` fell back to the script's own code root, a worktree has no `state/` of its own, and so **zero records were read** - after which the report asserted "no record claims it" about work that several records plainly claimed.

The matching logic was not at fault, and this is worth stating precisely because it was the intuitive suspect.
`worktree=` and `home=` were both already registered, and matching already resolved a process running in a subdirectory of a recorded path, not only an exact path equality.
Once the records were actually read, all six named processes attributed correctly on the first try, including the three secondmates matched through `home=`.

The real fault was narrower and worse than a matching bug: **the script made a claim it had no evidence for**.
`unowned` means "the records were read and none matched".
With an empty record set the script was entitled to say nothing at all, and instead said the most dangerous available thing.

Three changes followed.

Home resolution: when `FM_HOME` is not set and the code root holds no records, the operating home is resolved through the git common dir, which for a worktree is the primary checkout's `.git`.
That is a durable fact rather than a guess about path shapes, and it is a no-op when the script already runs from the primary checkout.

A refusal on an empty record set: if no task or secondmate record was read, the script exits 3 and prints no table.
Nothing can be called unowned by a reader that has read nothing.

A loud warning when records were read but almost no agent matched one.
Fleet agents run inside recorded worktrees, so a high unowned share among agent-kind processes is the signature of reading the wrong home.
This warns rather than refuses, because the reading is genuinely correct for the home it was pointed at.

### Why the tests did not catch it

Every test wrote its own records into a temp home and then asserted against them, so the suite proved the matching logic and never once exercised record *discovery*.
A fixture the test authored cannot be missing in the way a real home can.

The suite now also drives the real `state/*.meta` records on the host: one synthetic agent per real record placed in the directory that record actually names, plus one a subdirectory deeper, each of which must attribute back to a record claiming that path.
That test also surfaced a real property worth knowing - two live records may name the same worktree - so it asserts the owner is one of the records claiming the path rather than a single expected id.

A separate test runs the script the way it was actually run when it failed: from a worktree, with no `FM_HOME`, asserting it does not read zero records.

## Buckets, and what "unowned" is allowed to mean

`unowned` means the durable records were read and none of them claimed the process.
It is never the default for something the script failed to classify - that is `unclassified`, a separate bucket for processes whose facts could not be read, and it never appears as a finding.

An early draft put Chrome and other user applications in `unowned`, which inflated the reclaim class with 6 GB of applications the captain was deliberately running.
Bundled applications are now read from the executable path into their own `app` bucket, so the reclaim list stays actionable.

The reclaim classes are disjoint, so their totals can be added without overstating the win.
Overlapping buckets would be their own kind of confident wrong answer.

## What is allowed into the reclaim list

The review gate before merge found that the reclaim list was offering live work as free memory, which is the original incident one layer further out.
At that point it billed 1.47 GB across 112 processes as reclaimable, and that set included a running `opencode` agent, a live `claude -p` gate worker, a Paseo agent, the MCP servers those agents were using, the captain's shells, `nginx`, and `iTerm2` - the terminal emulator hosting the tmux session every agent in the fleet runs inside.

The rule now is that a process is listed only when there is positive evidence nothing needs it, and four exclusions enforce that.

A running agent is never reclaimable.
An agent that no record of this home claims belongs to another tool, another home, or the captain directly, so it goes to a `foreign-agent` bucket and is reported as context.

A live agent adopts the tooling in its directory.
An MCP or language server started by an agent, in a checkout no firstmate record claims, would otherwise read as an abandoned leftover; killing it would break the agent using it.

Only language and build tooling can be a leftover.
A shell is a terminal someone is sitting in and a service is a service, and neither is abandoned merely because no fleet record names its directory.
The checkout test alone is far too weak to carry this conclusion, because `/opt/homebrew` is itself a git checkout, which is how `nginx` reached the list.

The editor is surfaced but never billed as free.
Closing it is the single largest available win and the report says so explicitly, but as a decision for a human rather than a figure in the reclaimable total.

Everything excluded is still named and totalled, so the reader can see what was left out and why rather than wondering where the rest of the machine went.
On the live fleet this took the reclaim total from 1.47 GB of mostly-live work to 91 MB that is genuinely abandoned.

## Scope boundary

This script does not replace or modify `bin/fm-resource-check.sh`.
That script answers a different question - host pressure and the concurrent-agent ceiling - and other code depends on its contract.
`fm-memory-report.sh` never calls it, and `tests/fm-memory-report.test.sh` asserts that.

The report is read-only over the system and the fleet.
It kills nothing, stops nothing, and never wakes firstmate, the same never-wakes contract `bin/fm-desk-refresh.sh` documents.
