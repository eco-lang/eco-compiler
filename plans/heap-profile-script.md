# `heap-profile.py` — single-run + sweep heap profiler

## Motivation

Today `heap-sweep.py` runs a fixed 13-variant matrix for 5 minutes each, scrapes
GC stats from stdout/stderr, and appends rows to `/tmp/heap-sweep/results.tsv`.
We now want a more scientific harness:

- One driver for both single runs and sweeps.
- Per-machine results location, configured via a non-checked-in local config.
- Machine-name + timestamp folder structure, one folder per run group.
- All metrics in `.tsv` (tab-separated, human-readable).
- Markdown report per run group linking the per-block TSVs.
- Script verifies the binary is up-to-date before each run.

## Stage 1 — File rename + module split

1. `git mv heap-sweep.py heap-profile.py`. Update top-of-file docstring to cover
   single-run + sweep modes.
2. Internally split into three sections (still one file): config resolution,
   run driver, stats extraction + report writing.

## Stage 2 — Per-machine local config

3. Add a non-checked-in config file `/work/heap-profile.local.json` (next to
   the script). Schema:
   ```json
   {
     "machine_name": "ws-dev-01",
     "results_root": "/var/data/heap-profile"
   }
   ```
4. **First-run UX:** if `heap-profile.local.json` does not exist, prompt the
   user (interactive `input()` on stdin) for `machine_name` and
   `results_root`, write the file, then continue. The hostname is **not**
   used as a fallback.
5. Resolution order:
   - `--machine` / `--results-root` CLI flags (highest priority),
   - values from `heap-profile.local.json`,
   - if either is missing in non-interactive mode (`--no-prompt`), exit with
     a clear error.
6. Add `heap-profile.local.json` to `.gitignore`. Commit
   `heap-profile.local.example.json` showing the schema.

## Stage 3 — CLI surface

7. `argparse` with subcommands:
   - `run` — single run with one config file. Default config:
     `compiler/build-kernel/heap-config.json`.
   - `sweep` — runs the hard-coded `VARIANTS` matrix.
   Common flags:
   - `--config PATH` (run only) — heap config JSON.
   - `--variants NAME[,NAME...]` (sweep only) — restrict to a subset.
   - `--wall-seconds N` — per-run wall budget. **Shared default: 60.**
   - `--label STR` — short label embedded in the run-group folder.
   - `--results-root PATH`, `--machine NAME` — override the local-config
     values.
   - `--no-prompt` — fail instead of prompting if local config is missing.
   - `--dry-run` — print resolved paths and config without executing.
   - `--list-variants` — print the variant matrix and exit.
   `VARIANTS` stays hard-coded inside the script.

## Stage 4 — Build freshness check (script handles rebuilds)

8. Before any run, compare the mtime of `eco-compiler` (and
   `eco-boot-native`) against the runtime sources under `runtime/src/**` and
   the linker-input static libs. If the binary is older than any source/lib,
   automatically:
   - run `cmake --build build --target eco-boot-native` (and any other
     affected target),
   - re-lower `compiler/build-kernel/bin/eco-compiler.mlir` via
     `eco-boot-native` to refresh `eco-compiler`,
   - print one summary line per rebuild step.
9. Add `--skip-rebuild` to bypass the check; default behaviour rebuilds when
   stale.
10. Record the rebuild outcome in `args.json` (`rebuilt: yes/no`,
    timestamps).

## Stage 5 — Per-run directory layout (TSV everywhere)

11. Replace `/tmp/heap-sweep/` with
    `<results_root>/<machine>/<UTC-timestamp>__<label-or-mode>/`.
    - Timestamp format: **`YYYY-MM-DDTHH-MM-SSZ`** (UTC, filename-safe).
    - Label suffix: `__run-<label>` for `run`, `__sweep` for `sweep` (with
      `--label` overriding).
12. Single-run group contains one variant folder (named after the label or
    `default`). Sweep group contains `variants/<name>/` per entry.
13. Per-variant subfolder contents:
    - `heap-config.json` — exact config used.
    - `stdout.log`, `stderr.log` — full captured output.
    - `summary.tsv` — one-row TSV with the columns from the existing
      `HEADER`.
    - `gc_timing.tsv` — major / minor totals, helper bucket totals,
      mutator seconds.
    - `alloc_size_nursery.tsv`, `alloc_size_oldgen.tsv` — allocation-size
      histograms (one bucket per row).
    - `residency_cumulative.tsv`, `residency_latest.tsv` — block-occupancy
      histograms.
    - `freelist_cumulative.tsv`, `freelist_latest.tsv` — free-list
      size-class histograms.
14. Run-group root contains:
    - `report.md` — Markdown report linking every TSV.
    - `runs.tsv` — combined summary, one row per variant (resume marker).
    - `args.json` — exact CLI args, resolved machine + root, timestamp,
      rebuild outcome.

## Stage 6 — Markdown report

15. `report.md` template:
    - Header: machine, UTC timestamp, command line, wall-seconds budget.
    - For sweep: a summary table — one row per variant with the key columns
      from `runs.tsv` plus relative links to `summary.tsv`,
      `residency_latest.tsv`, `freelist_latest.tsv`.
    - For single run: same shape, one row.
    - Per-variant H2 sections: change description, key totals inline (wall,
      major, minor, helper, mutator, alloc, peak commit, final live), and a
      list of relative links to the per-variant TSVs.
    - Footer: links to `runs.tsv` and `args.json`, plus a note that all
      `.tsv` files use `\t` as field separator.

## Stage 7 — Stats extraction

16. Extend the parser to also produce:
    - The cumulative + latest residency histograms (parse the labelled
      "Old-Gen Page Residency Histogram (cumulative …)" and "(latest: …)"
      blocks).
    - The cumulative + latest free-list size-class histograms.
    - The nursery and old-gen allocation-size histograms.
17. Emit one row per non-zero bucket. Raw byte counts as integers
    (no MB rounding) so downstream analysis owns the unit conversion. The
    existing `summary.tsv` columns are preserved.
18. Centralise TSV writing in a `write_tsv(path, columns, rows)` helper:
    - Field separator: `\t`. Line ending: `\n`.
    - First line: column names (snake_case).
    - No quoting; raise if any field contains `\t` or `\n` (none of our
      fields can).
    - Integers written as ints; floats via Python's default `repr`.

## Stage 8 — Resume + idempotency

19. `--resume-dir PATH` re-uses an existing run-group folder; variants
    already in that folder's `runs.tsv` are skipped. Without
    `--resume-dir`, every invocation creates a fresh timestamped folder.
20. The old shared `/tmp/heap-sweep/results.tsv` cumulative file goes away.

## Stage 9 — Validation

21. Smoke test: `./heap-profile.py run --wall-seconds 30 --label smoke` —
    confirms folder layout, TSVs, `report.md`, and rebuild check.
22. Smoke test: `./heap-profile.py sweep --variants baseline,A_nb16
    --wall-seconds 30` — confirms sweep folder layout and resume behaviour.

## Files touched

- `heap-sweep.py` → `heap-profile.py` (renamed + rewritten).
- `heap-profile.local.example.json` (new, committed).
- `.gitignore` (add `heap-profile.local.json`).

## Resolved decisions (from review)

- Local config lives next to the script.
- Machine name comes from local config or CLI; first-run prompts; never
  hostname-derived.
- Timestamp format `YYYY-MM-DDTHH-MM-SSZ` (UTC).
- One TSV per histogram block; no long-form merged file.
- Shared 60s default `--wall-seconds`.
- No git revision capture.
- Script handles rebuilds (verifies mtime, rebuilds if stale).
- `VARIANTS` hard-coded for now.
- TSV format throughout for all stats files.
