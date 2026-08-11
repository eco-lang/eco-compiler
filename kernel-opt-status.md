# Kernel-Opt Loop — Status

State file for `guides/kernel-opt-loop.md`. One row per item in execution order; add
sub-rows (`14.1`, `14.3`, …) for multi-phase plans. Measurements live in
`benchmarks/kernel-opt.md` — this file records **state and disposition**, and points at the
run label.

Dispositions: `PENDING` / `IN-PROGRESS` / `KEPT-ON` / `LANDED` / `KEPT-DARK` / `PARTIAL` /
`REVERTED` / `BLOCKED`.

## Baseline

| quantity | value | source |
|---|---|---|
| `baseline_wall` | **3:31.59** (r1 3:33.92 / r2 3:29.25 mean); live spread 4.67 s ≈ 2.2% | Run D — loop-entry baseline |
| `baseline_counters` | 379,486,685 obj / 18,524.03 MB / 862 minor / 372,250,555 promoted (98.1%) / 10 major; RSS 5,111,732 kB; out.mlir 12,943,401 B | Run D |
| baseline binary | `build/compiler/build-kernel/bin/eco-kopt-base` (2026-08-10 19:53) | setup step 1 |
| `--target full` green count | **1632 / 1632, 0 failed** (~4 min per run) | measured 2026-08-10 20:20 |
| heap-validate green count | **not measured — gate removed from the loop** (user decision 2026-08-10). See `guides/kernel-opt-loop.md` §"Gates this loop deliberately does NOT run" for what that gives up. | |
| bootstrap fixed point | **removed from per-item gating**; one run at DONE only | |
| `elm-tests` count | **13066 passed / 12 failed** — the suite is **already red on the pristine tree**; all 12 are TYPE_007 constraint-generation suites + one golden fingerprint, none related to this track. "Green" for this gate means *still exactly these 12*. | pre-change run 2026-08-10 20:02 |
| series entry point | Run C (one-call Order materialization, 3:34.71) | `benchmarks/kernel-opt.md` |

Run D reproduces Run C's counters bit-for-bit (1-object jitter) and its `out.mlir` byte
size, so the tree is unmoved and the baseline is trustworthy.

Re-point `baseline_wall` / `baseline_counters` / `eco-kopt-base` after every **KEPT-ON** item.

## Items

| order | item | disposition | run | Δwall | counter deltas | notes |
|---|---|---|---|---|---|---|
| 1 | 07 kernel-facts-table | **LANDED** | E | −1.30% (FLAT) | objects identical; promoted +63 of 372M; minor/major identical | 52 rows, shim, 7 suites, `Utils_equal` trace deleted. **`out.mlir` byte-identical pre vs post on a frozen 243-module workload** ⇒ inert, proven. E2E 1632/1632; elm-tests 13066→13073 (+7 new suites), 12 pre-existing failures unchanged. Binary +173,400 B (plan predicted a shrink — wrong). Anchor rot from the deletion fixed: 11 `Utils.cpp` anchors re-pinned. |
| 2 | 01 list-cons → construct.list | **KEPT-ON** (`ECO_LIST_CONS_INTRINSIC=0` escapes) | F | +0.36% (FLAT) | promoted/minor/major identical; `Objects allocated` −38.7% is HEAP_034 counter blindness, **not** deleted allocation | **All 4,304 kernel cons sites → 0, zero declines.** EcoListTemplate parity bit-identical (rewritten=444, consRoots=0). Flag-off output byte-identical to pre-change on a frozen corpus. Gates: E2E 1633/1633 default-on; elm-tests 13073→13085 (+12 unit tests), 12 pre-existing unchanged. Plan Gate 3 was **unsatisfiable as written** (self-compile byte-identity vs an item that adds compiler source) — corrected in the plan file to a counts gate + fixed-corpus identity. Honest: billed as the series' best wall bet; ~147M dynamic kernel calls deleted for a flat wall. |
| 3 | 02 array-push churn | **KEPT** (lanes A + A′; no flag) | G | **−4.46% (REAL WIN)** | objects −5.44%, bytes −12.08%, minor 862→836, **promoted −2.96%**, GC time −6.04% | Census refuted the plan's premise (push traffic 6.3× lower than assumed) but confirmed H1 via a second stack frame: `UnionFind.fresh` = 4,739,084 calls doing 1 int + 2 box pushes. Lane A merged the 3 index-synchronised arrays into one `PointCell` array (12 files, type-checker core). **G2 byte-identity passed** — output preserved exactly. E2E 1633/1633; elm-tests unchanged at 13085/12. Also found: `Array.set` is 81% of all copying and needs its own plan; lane C is definitively closed (no growable-vector usage: max len 31/32, b33p=0). |
| 4 | 04 string.length / code_unit_at | **KEPT-ON** (`ECO_STRING_LENGTH_OP=0` escapes) | H | −0.12% (FLAT) | counters identical; minor 836, major 10, promoted equal both arms | **All 101 kernel `String_length` call sites → 0**, exact 1:1 with `eco.string.length`. Inline `header.size` load (one word serves all six String forms per HEAP_025/032) via a marker expanded at LLVM level; `ptr_ind` bit test, not `== 0x6`, so a Bool constant returns 0 instead of dereferencing address 4/5. `eco.string.code_unit_at` also lands with **no Elm emission** — it unblocks item 14's String-HOF phase. FORBID_HEAP_002 amended for the inline read. Gates: E2E **1636/1636 in both flag states**; elm-tests 13085/12 unchanged. |
| 5 | 05 Utils_append type split | **KEPT-ON** (`ECO_APPEND_SPLIT=0` escapes) | I | +0.80% (FLAT) | counters identical; minor 836, major 10, promoted equal | **3,468 kernel append sites → 67** (98.1% displaced); split reconciles exactly: 2,695 string + 706 list = 3,401. Residue is the MVar-operand population, by design. Stage-5 `.mlir` −6,773 B — the IR-size effect is the purchase the plan claims, and it is real but small. Both ops trait-free and absent from all four EcoGCPrepare lists (variable-size ⇒ RS4GC statepoints them). Phase 3 filled the `(Utils, append)` borrow axes POwned/POwned + resultAliases [0,1] and grew item 07's golden 33 → 34. Gates: E2E **1638/1638 both flag states**; elm-tests 13085/12. |
| 6 | 06 string ordering cmp3 | PENDING | — | — | — | must publish residue numbers for 03 Phase 5 |
| 7 | 03 value.eq fast path | PENDING | — | — | — | merges on top of 06 in `Intrinsics.elm` / `Config.elm` |
| 8 | 08 kernel gc-leaf stamp | PENDING | — | — | — | expect FLAT; deliverable is the census + size split |
| 9 | 09 GCPrepare barrier relaxation | PENDING | — | — | — | Phase 1 census is a hard precondition |
| 10 | 11 mono DCE + cost model | PENDING | — | — | — | authors `design_docs/debug-log-ordering-policy.md` |
| 11 | 13 mono CSE | PENDING | — | — | — | C1/D-C gate may close it at Phase 1 → PARTIAL |
| 12 | 10 MLIR CSE + folders | PENDING | — | — | — | census after 13; keep fold → CSE → mark → GCPrepare order |
| 13 | 12 eco.call purity attr | PENDING | — | — | — | owes the `eco.cse_safe` strip move (lands second vs 09) |
| 14 | 14 Elm-source List HOFs | PENDING | — | — | — | per-phase rows; symbol deletions are a separate step |

## Log

*(append one dated line per state change: item, what happened, gate counts, run label)*
