# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell script (`dirsize.ps1`) that measures disk usage of a folder tree
(local or `\\server\share`) without requiring admin rights, and handles paths longer than 260
characters (MAX_PATH). It scans once into an in-memory tree, then offers three ways to browse
the result: a WinForms GUI (`-Gui`, TreeSize-style drill-down), an interactive console mode
(default), or a fixed-depth report mode (`-Depth`). `Pastas.cmd` is a double-click
launcher (wraps `powershell -ExecutionPolicy Bypass -File ...`). No package manifest, no
automated test suite.

Target runtime: **Windows PowerShell 5.1** (the one shipped with Windows 11). Do not rely on
PowerShell 7 features — the intended machines do not have it.

The v2 script also: captures newest-mtime per folder (`MaxMtime`, for "big AND old = archive"),
tracks access-denied folders separately (`$script:Scan.DeniedDirs` / `$script:Scan.DeniedItems`,
listed in output/HTML), shows a WinForms progress window with Cancel during the scan
(`Show-ProgressWindow`, DoEvents pump; cancel yields a partial tree and exit code 2), and
exports HTML (`-HtmlOut`), JSON snapshots (`-SnapshotOut`) plus snapshot diffing
(`-CompareWith`). A per-user store in
`%APPDATA%\dirsize` keeps the recent-paths history (`recent.txt`) and GUI window
size/position (`settings.json`); all reads/writes there are best-effort (tolerate failure).

Comments, `Write-Host` output, and docs are in European Portuguese (pt-PT); keep new code
comments and user-facing strings consistent with that unless told otherwise. Console strings
avoid accented characters on purpose; HTML output (UTF-8) may use them.

## Running / testing changes

There is no build step. There are two test suites — `golden.ps1` (the frozen scanner) and
`diagnose.tests.ps1` (the Phase-2 tool); run the relevant one before committing. Also verify
by running the script directly under Windows PowerShell 5.1:

```powershell
# report mode + every exporter, no GUI (progress window suppressed)
.\dirsize.ps1 -Path . -Depth 2 -Top 10 -FlatTop 20 -ShowExtensions -NoProgressGui `
  -CsvOut out.csv -HtmlOut out.html -SnapshotOut snap.json

# snapshot diff (run once to make snap.json, change something, run again)
.\dirsize.ps1 -Path . -Depth 1 -NoProgressGui -CompareWith snap.json -HtmlOut evol.html

# GUI path (scan progress window + navigation window)
.\dirsize.ps1 -Path . -Gui

# if execution policy blocks local scripts, run without changing system settings
powershell -ExecutionPolicy Bypass -File .\dirsize.ps1 -Path .
```

**Regression harness.** Behaviour is pinned by a golden-output check (built for the v2.1
refactor). It builds a fixed tree (denied folder, junction, >260 path, mixed file types with
frozen mtimes), runs report + all exporters + a snapshot diff, normalises volatile fields
(durations, timestamps, output paths) and compares SHA-256 per artifact:

```powershell
.\golden.ps1 -Mode capture     # once, against known-good code -> MANIFEST.csv
.\golden.ps1 -Mode verify      # file diff: must print "SAIDA IDENTICA"
.\golden.ps1 -Mode invariants  # Complete + long paths + Get-FlatTop + snapshot schema: 41 asserts
.\golden.ps1 -Mode gui         # grid actions: 27 asserts, no window shown
.\golden.ps1 -Mode all         # verify + invariants + gui — run this before touching dirsize.ps1
.\golden.ps1 -Mode capture -Rebuild   # after changing the test tree
```

`verify` covers scan, console, CSV, JSON, HTML and compare, and fails loudly if `dirsize.ps1`
returns a non-zero exit code (a file can still be written by a run that ended badly).

`invariants` tests properties a file diff only catches by luck: `Complete` (denied folder →
`False`, propagation to parent and root, untouched branches staying `True`,
`Get-IncompleteCount`, both cancel paths, the `≥` marker), long-path metadata actually being
read, the extended prefix reaching the API, `ConvertTo-ExtendedPath` idempotency, and the
console `e` toggle reaching `Show-Ext`. Mutation-verified against dropping the cancel guard,
the child→parent propagation, the `enum-dir` marking, the `≥` prefix, and the extended prefix
on the enumeration root.

Both `invariants` and `gui` load the script's functions via AST — and also re-run its
`Add-Type` block, because `FsReparse.Native` is declared at script level, not inside a
function. Without it `Test-IsJunctionOrSymlink` throws, its `catch` returns `$false`, junctions
stop being skipped, and the harness silently measures a different tree than the real script.

`gui` loads the script's functions
via AST (without running its execution section), wires `$script:Ui` to a real `DataGridView`
parented to a Form that is created but never shown (columns/rows don't materialise until the
handle exists), and asserts on navigation, filter, sort, Top-global and row→node mapping.

Two things the GUI suite depends on, easy to break by accident:
- It sorts the view **ascending** before the drill-down assert, so row position ≠ `Idx`.
  In default order they coincide and an `Enter-GuiRow` regression to row-position is invisible.
- The tree contains folders named `50% desconto` and `entre [colchetes]`, and the filter
  asserts on the **exact row matched**, not merely "didn't throw" — an unescaped `LIKE` fails
  inside `Invoke-GuiFilter`'s `catch` and leaves the old filter in place, silently.

Both were verified by mutation: breaking the sort column, the `Idx` mapping, the filter
escaping, or the Top-global column name each makes the suite fail.

Known gaps, deliberately: the `'size'` error path (a file that enumerates but whose
`FileInfo.Length` throws) is untested — arranging one needs ACL edits that require
`SeSecurityPrivilege`, which a non-admin dev box does not have. Dialogs (`SaveFileDialog`,
`FolderBrowserDialog`), clipboard, Explorer launch,
and actual mouse/keyboard delivery are also uncovered. After GUI changes also launch `-Gui` once and confirm the
window opens, stderr is empty, and `%APPDATA%\dirsize\settings.json` is written on close (that
proves the `FormClosing` closure over `$form` survived).

Syntax-check without running:

```powershell
[System.Management.Automation.Language.Parser]::ParseFile('dirsize.ps1', [ref]$null, [ref]$null)
```

## Architecture

Everything is in `dirsize.ps1`, organized top-to-bottom as:

1. **Helpers** — `ConvertTo-ExtendedPath` (adds the `\\?\` / `\\?\UNC\` prefix to bypass
   MAX_PATH), `Format-Size`, `Test-Excluded` (wildcard folder exclusion), and the
   extension→category map (`$script:CategoryMap`, built from `$defs`) used to label folder
   content type without inspecting file contents.
2. **`Get-FolderNode`** — the single recursive scan. Enumerates with
   `[System.IO.Directory]::EnumerateFileSystemEntries` on the extended path, skips real
   junctions/symlinks by reparse tag (see invariants), routes per-entry errors through
   `Add-ScanError` (counts them, and adds access-denied paths to `$script:DeniedDirs` /
   `$script:DeniedItems`) so nothing aborts the scan, checks `$script:CancelRequested`
   (cooperative cancel from the progress window), and returns a node
   `{ Path; Name; Size; FileCount; DirCount; Children[]; Ext{ext->bytes}; MaxMtime; Complete }`
   with **cumulative** totals rolled up from children (`MaxMtime` = newest file write in the
   subtree; `Complete` = whole subtree fully observed — see invariants). Built once, reused by
   every view mode.
3. **Reporting / export helpers** — `Get-ParetoInfo`, `Get-CategoryBreakdown`/`Get-CategoryText`,
   `Get-FlatTop` (iterative walk → biggest folders anywhere in the tree), `Show-Children`/
   `Show-Report`/`Show-FlatTop`/`Show-Ext` (console), `Get-FlatFolderList` (single iterative
   flatten shared by CSV/snapshot/compare), `Export-TreeCsv`, `Export-Snapshot` (flat JSON:
   `meta` + `folders[]`, no deep nesting so `ConvertTo-Json` depth is a non-issue),
   `Compare-Snapshot`/`Show-Compare` (growers/shrinkers/new/removed vs a prior snapshot),
   `Export-HtmlReport` (self-contained HTML via `StringBuilder`; `ConvertTo-HtmlText` escapes).
4. **Progress window** — `Show-ProgressWindow`/`Update-ProgressWindow`/`Close-ProgressWindow`.
   Modeless WinForms form + `[Windows.Forms.Application]::DoEvents()` pumped from the scan's
   throttle point (every ~400 entries). Cancel button / window-close sets
   `$script:CancelRequested`; `$script:ProgClosing` guards the FormClosing handler so a
   programmatic close is not mistaken for a user cancel. Only shown for `-Gui` (unless
   `-NoProgressGui`); other modes keep `Write-Progress`.
5. **Three navigation front-ends over the same in-memory tree**, all read-only w.r.t. the tree:
   - `Start-Interactive` — console loop (`n`/`u`/`e`/`t`/`q`), default when no `-Gui`,
     `-Interactive`, or `-Depth` is given.
   - `Show-Gui` / `Update-GuiGrid` / `Enter-GuiRow` / `Select-FolderGui` — WinForms
     `DataGridView` browser. State (`$script:GuiRoot`/`GuiCurrent`/`GuiStack`/`GuiNodes`/
     `GuiFlat`, grid/label/button controls) is kept in `$script:` scope so the event handlers
     can reach it. Row→node mapping goes through a hidden `Idx` grid column (survives re-sort).
     Context menu + buttons: open-in-Explorer (`Invoke-OpenInExplorer`), copy-path
     (`Copy-PathToClipboard`, `Set-Clipboard`), export subtree CSV, "Top global" toggle
     (`$script:GuiFlat` → `Get-FlatTop`). `$script:GuiFilterBox` sets the DataView's
     `RowFilter` (LIKE on `Nome`/`Caminho`, with `'`/`[`/`%`/`*` escaped); cleared on every
     navigation in `Update-GuiGrid`. `Select-FolderGui` pre-fills a ComboBox from `recent.txt`. Window size/pos saved via `Save-AppSettings` on `FormClosing`. Falls back to
     `Start-Interactive` if WinForms is unavailable (e.g. Server Core).
   - `Show-Report` — non-interactive, fixed-depth printout.
6. **Execution section at the bottom** drives it: resolve/normalise `-Path` (relative → absolute
   against `$PWD.ProviderPath`, since `\\?\` needs a rooted path), `Add-RecentPath`, optionally
   `Show-ProgressWindow`, run `Get-FolderNode` once, print the summary (incl. `MaxMtime`,
   denied count, partial banner), run exporters (CSV/snapshot/compare/HTML), list denied folders
   and >260-char paths, then dispatch to the requested view mode. Exit code 2 if the scan was
   cancelled.

### Key invariants to preserve when editing

- The scan (`Get-FolderNode`) must remain single-pass; view modes must not re-scan the
  filesystem — they only re-render the tree already in memory.
- All filesystem paths passed to `System.IO` APIs must go through `ConvertTo-ExtendedPath` to
  keep long-path support working, including in any new code path that touches the filesystem.
  **`EnumerateFileSystemEntries` given a `\\?\` root returns entries that already carry the
  prefix**, so `$entry` inside the scan loop is already extended — `GetAttributes`,
  `[System.IO.FileInfo]` and `Test-IsJunctionOrSymlink` are correct as written (verified on a
  382-char path). Re-prefixing `$entry` is a no-op rather than a bug, because
  `ConvertTo-ExtendedPath` returns its input unchanged when it already starts with `\\?\`;
  keep that idempotency. What is **not** optional is the prefix on the root: drop it and long
  paths break on any machine where Windows' `LongPathsEnabled` is 0 — which is the default,
  and the assumption for the target corporate estate. Note the dev machine here has it set to
  1, so long-path tests pass either way; the suite therefore asserts the prefix directly, by
  checking that the denied-folder error message quotes a `\\?\` path.
- **`@($x)` throws on a `List[object]`** in this PS 5.1 build ("os tipos de argumentos não
  correspondem" / ArgumentException) — reproduced in a clean `-NoProfile` process.
  `List[string]` and `ArrayList` are fine; it is specific to the generic closed over `Object`,
  which is what every collection here uses (`Children`, `Errors`, `LongPaths`, `Nodes`, …).
  `@($list | …)`, `$list.ToArray()`, `[object[]]$list` and `,$list` all work — which is why the
  older `@($list | Sort-Object …)` code never hit it. Use `.ToArray()`.
- `return` **unrolls a one-element array to a scalar**. Any function whose result gets indexed
  (`Get-FlatTop` → `$script:Ui.Nodes[$i]`, reachable with `-FlatTop 1`) must return `,$array`.
- **`Sort-Object` is not stable in PS 5.1** (`-Stable` is PS 6+), so tie order is arbitrary.
  `Get-FlatTop` uses insertion order for ties instead, which is deterministic; the invariant
  suite therefore asserts *same sizes and same set*, plus determinism across calls — not
  position-by-position equality against `Sort-Object`.
- Code must run under **Windows PowerShell 5.1** (.NET Framework, STA console). Avoid
  PowerShell-7-only syntax/APIs (`ForEach-Object -Parallel`, `??`, ternary, `-AsHashtable`,
  etc.). Clipboard/WinForms rely on the 5.1 console being STA.
- The WinForms progress window uses a `DoEvents` pump, not a background runspace — keep it that
  way (5.1-safe, no threading). New long loops that should stay cancellable must poll
  `$script:CancelRequested` and call `Update-ProgressWindow`.
- CSV, snapshot and compare all flatten the tree via `Get-FlatFolderList` (one iterative walk).
  Snapshots are a **flat** `folders[]` array by design — don't switch to a nested structure
  (`ConvertTo-Json` depth + diff-by-path both depend on flat).
- The GUI grid's `Tamanho` column is a formatted **string**; it carries a hidden `Bytes` int64
  column and `SortMode = Programmatic`, and the `ColumnHeaderMouseClick` handler sorts the
  `DefaultView` by `Bytes`. Any new size/date column shown as text needs the same treatment
  (add a hidden real-typed column, don't let it auto-sort as text).
- `Pastas.cmd` runs `Unblock-File` on the `.ps1` before launching: a corporate
  `MachinePolicy` GPO overrides `-ExecutionPolicy Bypass`, so removing MOTW is what actually
  lets a downloaded copy run under `RemoteSigned`.
- Reparse points are inspected by tag (`Test-IsJunctionOrSymlink`, via `FindFirstFileW`):
  only **junctions/symlinks** are skipped (loops/double-counting), counted in
  `$script:SkipReparse` and reported in the summary ("Junctions/links"). **Cloud placeholders**
  (OneDrive/Dropbox "files on-demand") are also reparse points but are traversed normally —
  skipping them made the scan return 0 inside any synced folder. Don't revert to a blanket
  `ReparsePoint` skip, and keep the summary line in sync.
- Per-entry scan errors go through `Add-ScanError` (counts, `$script:Errors`, and — only for
  access-denied — `$script:DeniedDirs` for `enum*` tags / `$script:DeniedItems` for entry tags).
  `$ErrorActionPreference = 'Stop'` is global, so new filesystem calls in the scan need
  `try/catch`. `EnumerateFileSystemEntries` is **lazy**: the `foreach` over it in `Get-FolderNode`
  is itself wrapped in `try/catch` (`enum-iter`) so a mid-enumeration failure on a huge share
  loses only that folder's remainder, not the whole scan — keep that wrapper.
- `$script:LongPaths` records **both** files and dirs > 260 chars, each with a `Type`
  (`Ficheiro`/`Pasta`). `MaxMtime` on a node is the newest file mtime in its subtree — surfaced
  as "Fich. + recente" / CSV `NewestFileLocal`+`NewestFileUtc`, never plain "Modified".
- Script-scope state lives in three `[pscustomobject]` holders declared together near the top:
  `$script:Scan` (ErrCount, Errors, DeniedDirs, DeniedItems, LongPaths, Count, LastReport,
  SkipReparse, CancelRequested, Partial), `$script:Prog` (progress window: Form, LblPath,
  LblStats, Sw, Closing), `$script:Ui` (nav window: Root, Current, Stack, Nodes, Flat, FlatN,
  Grid, Lbl, BtnUp, FilterBox). Declare any new field in the holder — assigning an undeclared
  property on a PSCustomObject throws, which is deliberate (catches typos). **Never name a
  holder after a script parameter**: it was `$script:Gui` and silently clobbered the `-Gui`
  switch, hence `Ui` (same trap as `$Version` → `$script:AppVersion`).
- `Show-Gui` delegates construction to `New-GuiForm`, `Initialize-GuiPanel`, `New-GuiButtons`
  and `New-GuiContextMenu`. Handler **logic** lives in named functions (`Invoke-GuiFilter`,
  `Invoke-GuiSortBySize`, `Invoke-GuiUp`, `Set-GuiFlat`, `Select-GuiRow`) so `golden.ps1 -Mode
  gui` can call it without a window; the `Add_*` scriptblocks are thin wrappers. Handlers that
  close over **locals** (`$form` in FormClosing/Exit, `$btnFlat` for its caption) must stay
  inline in `Show-Gui` — moving those breaks the closure, and the file-diff suite would not
  notice. `New-GuiButtons` returns its controls for exactly this reason.
- Lower-bound size formatting goes through `Format-SizeQualified -Style Console|Gui|Html`
  (`>=`, `≥ `, `&ge; `). Don't hand-roll the prefix again.
- Every node has `Complete` (bool). It is set `$false` on `enum-dir`/`enum-iter`/`attr`/`size`
  failure and on cancel, and **propagates to ancestors** (`if (-not $child.Complete) { $node.Complete = $false }`).
  Cancellation needs its **own** check just before `return $node`: the cancel path leaves the
  loop via `break`, so no exception is raised and the `enum-iter` catch never runs. Without it,
  a folder interrupted mid-enumeration returns `Complete = $true` with partial numbers —
  invisible when the remaining entries were files, since files create no child to propagate
  from. Covered by `golden.ps1 -Mode invariants`.
  `$false` means Size/FileCount/… are lower bounds. Surfaced as CSV column `Complete`, snapshot
  `c`, the summary `Cobertura:` line (via `Get-IncompleteCount`), and a `≥` prefix on affected
  sizes in console/GUI/HTML. `Compare-Snapshot` only reads path→bytes, so it is unaffected.
  Any new code that skips or short-reads content must set `Complete = $false`.

## Repo contents

`dirsize.ps1` (the frozen scanner), `Pastas.cmd` (double-click launcher), `golden.ps1`
(scanner regression harness, dev-only), `diagnose.ps1` + `diagnose.tests.ps1` (Phase 2:
turns a baseline CSV into deterministic rankings — a *downstream consumer*, not a scanner
feature, so it is out of scope for the v2.1 freeze and has its own test suite), `README.md`,
`LICENSE`.

`diagnose.ps1` design rule: **it surfaces what needs a human decision; it never decides.**
Ownership, taxonomy and "this can be deleted" are governance judgements and stay with people.
All rules are fixed and visible at the top of the file (`$script:CategoriasPista`,
`$script:PadraoNomePista`, thresholds are parameters). Cleanup hits are always labelled
INVESTIGAR. Report `02-grande-e-antigo` only lists `Complete=True` subtrees — an incomplete
one has lower-bound size/age and belongs in `05` instead. `01b-areas-pareto` carries a
`TotalComplete` column (root coverage) so a partial baseline's percentages read as provisional.

Determinism is scoped: the **reports** (`0x-*.csv`) are byte-identical for the same CSV +
params; `_PARAMETROS.txt` is the deliberate exception (it has a timestamp), which is why the
determinism test filters it out. `Read-Baseline` is **fail-closed**: exactly one `Depth=0`
row, all numeric columns non-negative integers, `Complete` in {True,False}, `NewestFileUtc`
empty or ISO — otherwise it throws. `Get-RootRow` has no fallback (the source is a controlled
tool). `diagnose.tests.ps1`: 41 asserts on a fixed synthetic CSV + a `-Mutate` mode that
breaks each fixed rule (categories, cold cutoff, Pareto threshold, coverage sign, the `02`
Complete filter, the one-root check) and confirms the suite fails on each.
