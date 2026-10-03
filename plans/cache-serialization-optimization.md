# Cache serialization optimization (`.ecot` / `.eci` / string tables)

**Status:** PLANNED 2026-10-03, implementation-ready.
- Draft written, adversarially reviewed (corrections in §4), then every item lowered to
  implementation detail (§5; cross-section decisions in §5.0).
- Nothing is implemented yet.

**Evidence:**
- cold Stage 9b self-compile profiles (perf with frame-pointer call graphs) in `stats-backend-opt/boot-1003-1354/`: `9b-fp.data`, `9b-stages.txt`, `ser-profile.txt`;
- three investigation reports and the `.ecot` decoder `/tmp/claude-1000/agentA/ecot.py` (with analyses `ana2.py`–`ana4.py`) and review scripts `/tmp/claude-1000/review/`.

## 0. Problem

A cold `eco make` of the compiler itself (330 modules) takes about 130 s:
- the front end takes about 111 s, all on one mutator thread;
- of that, "parse / check / build" is 70.8 s;
- of that, about **40 s is serializing per-module caches**.

Parse + canonicalize + type check + optimize of all modules together take only about 14 s. Warm builds (Stages 7a and 8a, E2E, every incremental build) pay a second price: they decode 449 MB of `.ecot`.

**Measured:**
- **Where the 40 s goes:** about 90 % is the typed artifact:
  - `typedModuleArtifactEncoder` (writing `.ecot`): 54 %;
  - `TOpt.computeVarSupers`, a second module-wide string collection that runs inside the typed optimizer (`LocalOpt/Typed/Module.elm:107,121`), not the writer: 35 %.
- **Leaf self time:** `Dict_balance` 25 %, `Dict_insertHelp` 18 %, string compare (`eco_string_cmp3` + `StringOps::compare`) ~21 %, `Dict_get` 6 %. Byte encoding (`writeEncoder` + `getWidths`) is about 6 %.
- **Size:** 275 `.ecot` files, 449 MB, ~2,000 unique strings each.
  - 96.7 % of the bytes are `Can.Type` encodings: 25.6 M type nodes, 440k top-level type occurrences.
  - The distinct nodes, summed over files, number 151,830 with the arrow slot (~550 per file) and 84,685 without it.
  - Nested `Filled` alias bodies carry most of the repetition.
  - Cause: `variableToCanType` (`Compiler/Type/Type.elm:470-530`) builds a fresh tree per expression, and the trees are later rebuilt again by `PostSolve` / `SolverRoots.stampArrowRoots`.
- **Per type node:** each `TType`/`TAlias` node costs 4 `Set.insert`s on collect and 4 `Dict.get`s on encode. Inserting a key that is already present still copies the path and rebalances; 99.9 % of inserts are repeats.
- **No IO waits:** the main thread is on-CPU 99.3 % of the phase. Writes are one copy and one `write(2)` per file, ~0.3 s for 449 MB.
- **Who reads `.ecot`:**
  - A cold build never reads it: Generate uses the in-memory graphs of `Fresh` modules (`Generate.elm:522-531`).
  - Warm builds do read it: Stage 7a/8a in the bootstrap (same `build-kernel` dir, only `*.ecot` deleted before Stage 5), the E2E harness (shared warm caches), and every incremental build.
- **Erased optimizer:** it runs on the typed path and its result is discarded (`Compile.elm:226`, `Generate.elm:702-737` `stripUntypedGraph`).

## 1. Goals and gates

**Goals:**
- Cold-build serialization (encode + `computeVarSupers`) from about 40 s to **under 6 s**.
- Warm-build `.ecot` decode **at least 10× faster**, and `.ecot` volume **at least 10× smaller**.
- Bootstrap fixed points (4b and 8c) preserved.

**Gates.** G1–G6 apply to every item; the format items (S3, S10) also need G7–G9. Run each test command once, tee'd to a file.

| id | gate |
|---|---|
| G1 | elm-tests: `cmake --build build --target elm-tests` (known baseline of 12 type-checker failures) plus the new codec tests (§5.3.8) |
| G2 | E2E: `cmake --build build --target full` |
| G3 | AOT E2E: `run-aot-e2e`. Move `build/test/aot-e2e/*/eco-stuff` aside first (stale-cache rule). Also the `mlir_equivalence` tool where the item touches caching |
| G4 | full bootstrap: `cmake --build build --target bootstrap` (4b and 8c), then `eco-verify` (9b) |
| G5 | **native cold→warm**: with the Stage 9 `eco`, a cold build writes `-o a.mlir`; rerun warm (decoding the native-written caches) to `b.mlir`; `cmp a.mlir b.mlir` |
| G6 | **incremental build**: cold build, touch one leaf module and one hub module, rebuild, compare with a cold build's MLIR. Run with and without `--builddir`. Script: `benchmarks/incremental-cache-check.sh` (new, §5.12) |
| G7 | **JS vs native encoder equality**: for 5 modules (largest `.ecot`s plus 2 small ones), the `.ecot` written by the Stage 5 JS compiler and by the native compiler are byte-identical |
| G8 | **stale format**: with a v1 `.ecot` tree and v1 package caches in place, a build recompiles (or relocates by version) and never fails with `GenerateCannotLoadArtifacts` or a "Corrupt File" banner |
| G9 | **LSS_022 kernel license check** (`kernel-license-check`, part of ALL) for any C++ kernel change. Re-audit per `plans/kernel-parametricity-license.md`; never just regenerate hashes |
| G10 | **timing**: one cold Stage 9b run with `--stats` (phase times) and `/usr/bin/time -v`. A warm 9b too, for decode items |

**Twin rule.** Every new Elm-visible kernel needs three twins:
- a C++ export;
- an `Eco/Kernel/*.js` kernel (JS stages 2–5);
- a pure-Elm `compiler/src-xhr/Eco/*.elm` twin (Stage 1 / `guida.js`, Gate A, elm-test-rs).

## 2. Items, revised after review

The savings are estimates, **marginal in the order listed**.

| id | Item | Format | Est. saving (cold 9b) | Priority / risk |
|---|---|---|---|---|
| S1 | `Set.member` guard in the hot string collectors | no | 10–12 s | P1 / none |
| S2 | `computeVarSupers` without the module-wide `Set` (byte-identical variant) | no | ~4 s after S1 | P1 / none |
| S3 | `.ecot` v2: per-file type table, deduplicated with a native deep hash (`Eco.Hash.deepWith`) + `==`; `computeVarSupers` from the same pre-pass (S3b) | yes | modelled: 25.6 M type nodes → 149.6k table entries; native cost ~0.6–1.7 s, so serialization ≈ 2–4 s (≈ 20 s saved after S1+S2) | P1 / medium |
| S5 | Skip the erased optimizer on the typed path (+ the `graphHasMain` fix in `Make.elm`) | no | 1–4 s + GC | P2 / low |
| S11 | Read-path fixes: no `strToIdx` on decode, direct-to-heap `readBytes`, no vector per short leaf | no | warm: ~0.5 s + less allocation | P2 / low |
| S12a | Format/version bump: `V.compiler` 0.1.1 → 0.1.2, `typedGraphFormatVersion` 1 → 2 | (S3) | — | P1 (with S3) / low |
| S12b | `--builddir` path mismatch (reproduced: every warm build in a build dir fails) + the harness pre-clean paths | no | — (correctness) | P2 / low–medium |
| S12c | Atomic artifact writes (temp file + rename; new kernel, three twins) | no | — (correctness) | P3 / medium |
| S12d | `ECOT_001`/`ECOT_002`/`ECOT_003` rows in `invariants.csv` | — | — | P1 (with S3) / none |
| S4 | One-shot mode (no `.ecot`/`.eci`/`d.dat` writes) for invocations nobody reuses | no | ≤ ~3–6 s after S3 | P3 / low |
| S9 | `StringOps::compare` hot/cold split + `resolveFast` (C++ only) | no | ~1 s before S3, ~0 after | P3 / low |
| S10 | `.ecot`-only varint encodings for regions and table ints, **bundled into the S3 format break** (§5.0.2) | yes | size: 17.8 → ~7 MB | P1 (with S3) / low |
| S6 | ~~Asynchronous `lowerAndLink` + deferred `.ecot` encode~~ | — | **DROPPED** (§4, R6) | — |
| S7 | ~~Hash-keyed string table~~ | — | **DROPPED**, subsumed by S3 (re-open only if strings stay hot) | — |
| S8 | `variableToCanType` memo per representative | no | **EXPERIMENT ONLY** (§5.8) | P4 |

**Order:**
1. S1, S2 (one change set);
2. S5;
3. the S3 prototype (§5.3.1, go/no-go);
4. S12a + S12d + S3 + S3b + S10 (one change set: the format break);
5. S12b;
6. S11 + S12c (one `File.cpp` license audit cycle);
7. S9, S4, the S8 experiment as wanted.

Each step is measured (G10) and gated.

## 3. Expected outcome

| | today | after S1+S2(+S5) | after S3+S10 (+ the rest) |
|---|---|---|---|
| serialization + `computeVarSupers` in cold 9b | ~40 s | ~20–24 s | ~2–4 s (the S3 prototype decides, §5.3.1) |
| cold 9b wall | ~130 s | ~110–114 s | ~92–96 s |
| `.ecot` volume | 449 MB | 449 MB | ~7 MB |
| warm `.ecot` decode | ~5–10 s | same | < 0.5 s |
| warm builds with `--builddir` | broken after the first build | broken | fixed (S12b) |

## 3a. Out of scope: future work

**String-specific eco dialect ops are deliberately excluded from this plan** (decision 2026-10-03).
This plan adds no eco ops and changes none: its kernels are ordinary `is_kernel` declarations
called through `eco.call`. Candidates for a later plan, to be re-measured after this one lands:

1. **`eco.string.cmp3` / `eco.string.eq` with an inline fast path at lowering.**
   - Pointer equality, then for two flat UTF-8 leaves: length + first 8 bytes inline, then `memcmp`.
     The kernel is called only for other forms.
   - Comparisons against literals fold or specialize.
   - Estimate ~1–2 s after this plan (the microbenchmarks give ~25 % per compare).
2. **String-concat fusion** (by analogy with bytes fusion). `++` / `String.concat` /
   `String.join` chains become one exact-size allocation, which keeps later compares, hashes and
   writes off the `collectSegs` rope/mixed slow path. In the cold 9b this is ~1.9 s, mostly in MLIR
   codegen. Estimate 1–3 s.
3. **`eco.string.hash` foldable for literals:** negligible here.

Cheaper first steps for that later plan, without new ops:
- give the MLIR bytecode writer's string-keyed dedup tables (`Mlir.Bytecode.AttrType.attrIndex` /
  `addAttrEntry`, `StringTable.addString`) the same treatment as §5.1/§5.3;
- consider an interned-`Name` ("atom") representation with a cached hash and pointer-equality fast
  paths.

## 4. Adversarial review: corrections applied

| # | Finding (evidence) | Change made |
|---|---|---|
| R1 | About 50 bare `Set.insert` sites in 9 modules, but the repeats come from three functions: `Can.collectStringsFromType` (`Canonical.elm:1601`), `ModuleName.collectStringsFromCanonical` (`ModuleName.elm:496`), `Pkg.collectStringsFromName` (`Package.elm:508`) | S1 targets those three plus the cheap point-free sites; the rest are optional |
| R2 | `superOfName` is a `String.startsWith` test over EVERY collected string, including literals, local names and fields. The current cache has 26 spurious `varSupers` entries (e.g. `"numbers!"`). Restricting to type positions would change bytes, and would need the alias-arg names (`AssignMVarIds.elm:1337-1350`) | S2 uses the **byte-identical** variant: same traversal, `Dict.insert` only on a prefix hit, no `Set`. Restricting to type positions is noted as a later, byte-changing option |
| R3 | The type-table key must include the arrow slot, the `FieldType` index, `Holey`/`Filled`, the record ext and the alias arg names. Elm has no identity, so a pure-Elm table walks all 25.6 M nodes with composite keys; ids cannot be threaded through `BE.Encoder`. "152k per file" was the sum (≈550/file) | S3 is redesigned: a native `Eco.Hash.deep` + native `==` give lookups that short-circuit per occurrence (descending only on misses). Ids are looked up again at encode time with the same cheap lookup, so no state threading is needed. Includes a prototype gate before the full rollout. Estimate revised to 20–30 s |
| R4 | The bootstrap does NOT wipe `eco-stuff`: only `*.ecot` before Stage 5; 7a/8a are warm and decode Stage 5's `.ecot`. E2E relies on warm shared caches. Skipping `.eci` while writing `d.dat` → `RBlocked` (`Build.elm:1244-1250`, `951-953`) | S4 also skips the `d.dat` locals write, is opt-in only, and is not used by the bootstrap. Re-estimated at ≤ 6 s after S3 |
| R5 | S4/S6 savings ignored S3, and `computeVarSupers` runs during compile regardless of writes | All estimates are restated as marginal |
| R6 | S6 keeps every fresh typed graph alive through mono, defeating `GcPoints.preLink` (`Make.elm:460-480`, `plans/frontend-heap-release.md` §6.3). `WaitService`'s `waitpid(-1)` races `ExecuteAndWait`. After S3 it saves ≤ 6 s | S6 dropped |
| R7 | `PostSolve` / `stampArrowRoots` rebuild every node after `toCanTypeBatch`, so a memo yields no lasting sharing, and the encoder can't see sharing anyway | S8 downgraded to a measured allocation experiment |
| R8 | An inline cmp3 fast path touches REP_CONSTANT_003, HEAP_025/032, REP_LLVM_001/002 and the gc-leaf declarations; `UtilsExports.cpp` is LSS_022-pinned; mostly subsumed by S3 | S9 reduced to a C++-only hot/cold split in `StringOps` |
| R9 | A version mechanism exists: `V.compiler` (`Version.elm:166-178`) keys `eco-stuff/<ver>` and `~/.eco/<ver>`; `typedGraphFormatVersion` already fails decode. A `d.dat` salt would not catch a stale per-module `.ecot` (existence-only check, `Build.elm:884-894`) or package caches (`Details.elm:353-354` replaces a failed decode with an empty graph) | S12a bumps both versions and updates hard-coded `0.1.1` paths (`benchmarks/fhr-matrix.sh:18`, `l3-corunner.sh:24`, `fhr-gc-points-runs.sh:6`, `ecot.py`) |
| R10 | The build-dir mismatch is real and live: E2E/AOT pass `--builddir=<stem>` in parallel (`ElmE2ETestBase.hpp:481-482,560,596`, `aot_e2e_main.cpp:360`), so `.eci`/`.ecot` are shared and raced while `d.dat` is per dir | S12b threads `maybeBuildDir` into `CompileResultContext`; gated by G3/G6 |
| R11 | There is no rename kernel; it needs C++ + JS + xhr + io-handler twins and a license audit | S12c spelled out, priority P3 |
| R12 | `regionEncoder` is shared with `.eci` and other formats | S10 adds `.ecot`-only variants; priority P4 |
| R13 | Gate 8c compares two decodes of Stage 5's JS-written `.ecot`, so it never exercises the native encoder. There are no codec round-trip tests and no incremental-build suite. LSS_022 pins `File.cpp`/`NativeDriver.cpp`/`UtilsExports.cpp` | Gates G5–G9 added; new codec tests in §5.3.8 |
| R14 | `to.dat` (`Details.elm:311`) reads with `TOpt.globalGraphDecoder` but is never written | Noted in S3 (decoder change covers it); removal optional in S12b |

## 5. Implementation specifications

Each subsection is lowered to implementation detail: files, functions with line numbers (as of
2026-10-03, so re-grep after earlier steps shift them), code sketches, tests, gates and
measurement. §5.0 records the decisions that span sections. Where a subsection disagrees with
§5.0, §5.0 wins.

### 5.0 Integration notes (cross-section decisions)

1. **S2 versus S3 (`computeVarSupers`).**
   - S2 (§5.2) lands first, as the byte-identical `StringTable.Collector` variant built on the
     `collectStringsFrom*` walkers. That is correct only while those walkers still visit type positions.
   - S3 stops them visiting types: types come from the table. **S3 must therefore switch
     `computeVarSupers` to S3b (§5.3.7) in the same commit.** It computes `varSupers` from the
     type-table pre-pass plus the non-type strings, with an identical result.
   - Skipping this is a miscompile: mono loses `number`/`comparable` supers. Test: the `varSupers`
     completeness test and the v1↔v2 equivalence check over all 275 modules (§5.3.8).
2. **S10 is bundled into the S3 format break** (v2, `V.compiler` 0.1.2), as §5.10 recommends.
   - The S3 table's entry ints and `.ecot` regions use the S10 varints. Int literals stay float64.
   - A separate S10 later would need format v3, `V.compiler` 0.1.3 and another G7/G8 cycle.
   - Combined `.ecot` volume: about 449 MB → ~7 MB (S3 alone 17.8 MB; S10 removes ~10 MB of regions and ints).
3. **ECOT_003 text.** Use the §5.3 (step 10) description with the §5.12d column values
   (`ECOT_003;TypedOptimization;ArtifactSerialization;enforced;…;source`), to match ECOT_001/002.
   The csv header is `id;phase;category;status;description;source`, and descriptions contain no `;`.
4. **S5 needs the `graphHasMain` fix** (§5.5). `Terminal/Make.elm` `getMain`/`isMain`/`getNoMain`
   read `main` from the erased graph. They must read the typed graph's `main` when present, or
   every MLIR/ELF build fails with `MakeNonMainFilesIntoJavaScript`.
5. **S12b also fixes the E2E/AOT harness pre-cleans** (§5.12b). They target `eco-stuff/1.0.0` and
   `eco-stuff/aot_e2e_*`, but the real layout is `eco-stuff/<ver>/aot_e2e_*`, so ~596 stale build
   dirs survive today. This bug (warm builds in a `--builddir` fail with "CORRUPT CACHE") is the
   origin of the recurring "move eco-stuff aside before run-aot-e2e" rule.
6. **License audits (G9):**
   - S3's kernel goes in `Hash*.cpp`, which is not pinned: no audit.
   - S9 touches only allocator `StringOps`, not pinned: no audit.
   - S12c and S11(b) change `File.cpp`. That needs a re-audit of all 23 `File.*` rows (their evidence
     line numbers shift), so **do S11(b) and S12c in one audit cycle**.
7. **Version bump (S12a) lands in the same commit as S3+S10.** It must not land earlier: any
   old-format package cache written under 0.1.2 would decode silently as an empty graph.
8. **G7 step 0.** Before S3, confirm that today's v1 `.ecot` written by Stage 5 (JS) and by
   Stage 9b (native) are byte-identical for the G7 modules. Otherwise a pre-existing difference
   would be blamed on S3.

### 5.1 S1 — Set.member guard

**Problem.** `Set.insert k s` with `k` already present still descends, re-allocates every node on the path and re-runs `Dict.balance` (elm/core `insertHelp`, EQ case rebuilds the node, the parents call `balance`). In the string collectors 99.9 % of inserts are repeats, so the cost is pure allocation + balancing (`Dict_balance` 25 %, `Dict_insertHelp` 18 % of serialization self time).

**Helper.** It goes in `compiler/src/Compiler/AST/StringTable.elm`:
- All 8 collector modules already import `Compiler.AST.StringTable as StringTable exposing (StringTable)`: Canonical:105, TypedOptimized:84, TypeEnv:38, DecisionTree/Test:22, DecisionTree/TypedPath:20, Utils/Shader:40, Elm/ModuleName:83, Elm/Package:63.
- StringTable imports only `Array Bytes Dict Set Utils.Bytes.*`, so there is no import cycle.
- It is pure Elm, so Stage 1 (stock Elm / `guida.js`) compiles it. No twin is needed.

```elm
-- StringTable.elm: add to `exposing` and to @docs under a new "# Collection" heading
{-| Add a string to a string-collection set. On a hit, return the SAME set
(no path copy, no rebalance). 99.9 % of collector inserts are repeats. -}
addString : String -> Set String -> Set String
addString s set =
    if Set.member s set then
        set

    else
        Set.insert s set
```

If S1 and S2 land as one change set (plan order 1), implement §5.2's `Collector`/`add` directly. S1 then reduces to "every insert goes through `StringTable.add`". S1 is specified separately so it can be measured alone first.

**Miss cost.** On a miss, member + insert costs about 2× the string compares of a plain insert (2 × ~log2 n descents) but allocates the same. At about 2,000 unique strings per file against millions of occurrences, misses are under 0.1 %. Even a mostly-new key set (string literals, `Str`) would lose at most one extra no-allocation descent per key. Plain insert only wins when nearly all keys are new, which never happens here.

**Sites.** There are 56 `Set.insert` occurrences in 8 modules. Every one is an insert into the collection accumulator.

*Mandatory (the hot three; together these are the "4 inserts per `TType`/`TAlias` node"):*

| file:line | function | before → after |
|---|---|---|
| Canonical.elm:1610 | `collectStringsFromType` TVar | `Set.insert name acc` → `StringTable.addString name acc` |
| Canonical.elm:1616 | TType name | `\|> Set.insert name` → `\|> StringTable.addString name` |
| Canonical.elm:1626 | TRecord field | `(Set.insert k a)` → `(StringTable.addString k a)` |
| Canonical.elm:1633 | TRecord ext | `Set.insert s withFields` → `StringTable.addString s withFields` |
| Canonical.elm:1655 | TAlias name | same rewrite |
| Canonical.elm:1661 | TAlias arg name | same rewrite |
| ModuleName.elm:500 | `collectStringsFromCanonical` | `\|> Set.insert name` → `\|> StringTable.addString name` |
| Package.elm:511-512 | `collectStringsFromName` (author, project) | both lines |

*Point-free forms (cheap, do them):*

| file:line | before | after |
|---|---|---|
| Canonical.elm:1595 | `List.foldl Set.insert a (Dict.keys freeVars)` | `Dict.foldl (\k _ a2 -> StringTable.addString k a2) a freeVars` (also drops the key list) |
| Canonical.elm:1686 | `List.foldl Set.insert acc u.vars` | `List.foldl StringTable.addString acc u.vars` |
| TypedOptimized.elm:1715, 1726 | `Dict.foldl (\k _ a2 -> Set.insert k a2)` | `Dict.foldl (\k _ a2 -> StringTable.addString k a2)` |
| TypedOptimized.elm:1754 (×2), 1764 | same lambda forms | same |
| TypedOptimized.elm:1866 | `List.foldl Set.insert acc names` | `List.foldl StringTable.addString acc names` |
| TypedOptimized.elm:2104, 2108 | `Data.Set.foldr compare Set.insert` | `Data.Set.foldr compare StringTable.addString` |

*Optional (per-expression or cold; same mechanical rewrite, recommended for uniformity):*
- TypedOptimized.elm:1739, 1833, 1871, 1895, 1905, 1907, 1920, 1923, 1932, 1935, 1949, 1953, 1957-1959, 1970, 1982, 1996, 1997, 2022 (×2), 2035, 2040, 2053, 2065, 2077, 2116, 2131, 2137, 2144;
- TypeEnv.elm:248; DecisionTree/Test.elm:229, 244, 247; DecisionTree/TypedPath.elm:168; Utils/Shader.elm:201.

**Mechanical form.** Inside the collector sections only, run `sed -i 's/\bSet\.insert\b/StringTable.addString/g'` over these ranges:

| file | lines |
|---|---|
| Canonical | 1587-1694 |
| TypedOptimized | 1704-1767 and 1829-2196 |
| TypeEnv | 236-267 |
| Test | 220-252 |
| TypedPath | 146-171 |
| Shader | 197-202 |
| ModuleName | 494-501 |
| Package | 506-513 |

Then hand-fix Canonical:1595, which is better written as the `Dict.foldl` form above. Grep afterwards: `grep -n 'Set.insert' <ranges>` must be empty.

**Why byte-identical.**
- `addString` returns a set with the same members as `Set.insert`.
- `StringTable.build` uses only `Set.toList` (sorted), so the table, the indices and every byte of `.ecot`, `typed-artifacts.dat` and the TypeEnv preamble are unchanged.
- `computeVarSupers` folds over the same member set, so `varSupers` is unchanged.
- No MLIR change is possible.

**Tests and gates.**
- G1, G2, G3, G4 (4b/8c must stay byte-identical; nothing here can change bytes), G10.
- **Artifact identity check** (cheap, the decisive one for S1, S2 and S5). It does not need `--builddir`, which is affected by S12b/R10:
  1. Cold-build the compiler self-compile (Stage 9b inputs) with the baseline `eco`, then `mv eco-stuff eco-stuff.base`.
  2. Cold-build with the new `eco`.
  3. Run `diff -r --exclude=d.dat eco-stuff.base/0.1.1 eco-stuff/0.1.1` (`d.dat` holds build IDs and times). It must be empty: all `.eci` and `.ecot` files identical.
  4. Also `cmp` the two `-o *.mlir` outputs.
- **Measurement** (fast loop per the perf-loop rule; correctness gates batched at the end):
  - one cold 9b with `--stats` + `/usr/bin/time -v`;
  - `perf record -g` (frame-pointer build) of the same run. Read the inclusive time of `typedModuleArtifactEncoder` and `computeVarSupers`, and the self time of `Dict_balance` + `Dict_insertHelp`.
  - Expect serialization 40 s → about 28-30 s, and `Dict_balance`/`insertHelp` to nearly vanish from the collectors, with `Dict_get` rising instead.

---

### 5.2 S2 — computeVarSupers without the Set

**Today.**
- `TypedOptimized.elm:1816-1818`: `computeVarSupers graph = Set.foldl insertSuperOfName Dict.empty (collectStringsFromLocalGraph graph Set.empty)`.
- `varSupersOfType` (1824-1826) does the same over `Can.collectStringsFromType`. It is used only by `Monomorphize/AssignMVarIds.elm:275`, the test-only single-type entry.
- `superOfName` (1785-1799) tests `Name.isNumberType / isComparableType / isAppendableType / isCompappendType`. These are 4 `String.startsWith` calls (`Data/Name.elm:159-182`).
- The only caller is `LocalOpt/Typed/Module.elm:119-121` `withComputedVarSupers`, with `data.varSupers = Dict.empty` at that point, so the `varSupers` fold at TO:1715 contributes nothing.
- The cost is a full second module-wide `Set String` build: 35 % of the 40 s.

**Options.**

| option | change | verdict |
|---|---|---|
| (a) callback fold `foldStrings : (String -> acc -> acc) -> ... -> acc -> acc` | every collector (≈30 functions, 8 modules) gains a function parameter. Polymorphic `acc` | **No.** Every string becomes an unknown-closure call (generic `papExtend` dispatch, about 100 M calls across the self-compile) on the encoder's hot path too. A fast stamp would need LSS to prove singleton sets per spec, which is not guaranteed. Large diff |
| (b) dedicated `varSupers` walker | copy about 450 lines of traversal | **No.** It duplicates the ECOT_002 traversal, and the two copies drift |
| (c) keep the Set, rely on S1 | none | leaves about 11 string compares (member hit) per occurrence: the S1 residual of ~5 s |
| **(d) opaque `Collector` accumulator with a two-mode tag (pick)** | change the accumulator type of every collector from `Set String` to `StringTable.Collector`. After S1 every insert already goes through one function, so this is a **signature-only** diff plus the function body | a direct call plus a constructor `case` per string, no closure, no allocation on a hit. The supers mode does 4 prefix tests and touches a Set only on a prefix hit |

**Code (StringTable.elm).** Add `import Compiler.Data.Name as Name`. `Data/Name.elm` imports only `Utils.Crash`, so there is no cycle. `Vars.SuperType` cannot be imported here: `Compiler.Type.Vars` imports `ModuleName`, which imports `StringTable`.

```elm
-- exposing: Collector, collectAll, collectSupers, add, collected

{-| Accumulator of the string collectors (ECOT_002). `CollectAll` gathers
every emitted string (string-table build). `CollectSupers` keeps only the
strings `TOpt.superOfName` maps to `Just`, so the sweep that computes `varSupers`
never builds the module-wide set. -}
type Collector
    = CollectAll (Set String)
    | CollectSupers (Set String)

collectAll : Collector
collectAll = CollectAll Set.empty

collectSupers : Collector
collectSupers = CollectSupers Set.empty

add : String -> Collector -> Collector
add s c =
    case c of
        CollectAll set ->
            if Set.member s set then c else CollectAll (Set.insert s set)

        CollectSupers set ->
            if isSuperName s && not (Set.member s set) then
                CollectSupers (Set.insert s set)
            else
                c

collected : Collector -> Set String
collected c =
    case c of
        CollectAll set -> set
        CollectSupers set -> set

-- MUST be the exact disjunction of the Just-cases of TOpt.superOfName.
isSuperName : String -> Bool
isSuperName s =
    Name.isNumberType s || Name.isComparableType s
        || Name.isAppendableType s || Name.isCompappendType s
```

`addString` from S1 is replaced by `add`: `sed s/StringTable.addString/StringTable.add/`.

**Functions that change (signature only, `Set String` → `StringTable.Collector`, including let-annotations such as `withFields : Set String`):**
- Canonical: `collectStringsFromAnnotation`, `collectStringsFromType`, `collectStringsFromAliasType`, `collectStringsFromUnion`, `collectStringsFromCtor` (1592-1694).
- ModuleName: `collectStringsFromCanonical` (496).
- Package: `collectStringsFromName` (508).
- Shader: `collectStringsFromSource` (199).
- DecisionTree/Test: `collectStringsFromTest` (223).
- DecisionTree/TypedPath: `collectStringsFromPath`, `collectStringsFromHint` (149, 164).
- TypeEnv: `collectStringsFromModuleTypeEnv`, `collectStringsFromGlobalTypeEnv` (241, 257).
- TypedOptimized: every `collectStringsFrom*` (1709-1767, 1829-2196), including `collectStringsFromDecider : (a -> Collector -> Collector) -> ...`.

Add `exposing (StringTable, Collector)` to the imports where the annotations need it. Unused `Set` imports can be dropped; stock Elm does not fail on them.

**Call sites.**

```elm
-- TypeEnv.elm:161, 193 / TypedOptimized.elm:521, 569  (before)
StringTable.build (collectStringsFromLocalGraph graph Set.empty)
-- after
StringTable.build (StringTable.collected (collectStringsFromLocalGraph graph StringTable.collectAll))

-- TypedOptimized.elm:1816-1826  (before)
computeVarSupers graph =
    Set.foldl insertSuperOfName Dict.empty (collectStringsFromLocalGraph graph Set.empty)
varSupersOfType tipe =
    Set.foldl insertSuperOfName Dict.empty (Can.collectStringsFromType tipe Set.empty)
-- after
computeVarSupers graph =
    Set.foldl insertSuperOfName Dict.empty
        (StringTable.collected (collectStringsFromLocalGraph graph StringTable.collectSupers))
varSupersOfType tipe =
    Set.foldl insertSuperOfName Dict.empty
        (StringTable.collected (Can.collectStringsFromType tipe StringTable.collectSupers))
```

Update the doc comment at TO:1811-1814: the sweep is the same traversal in supers mode.

**Why byte-identical.**
- Let S be the set the old sweep built.
- The new set is `{ s ∈ S | isSuperName s }`, and `isSuperName s ⇔ superOfName s /= Nothing`.
- `insertSuperOfName` drops the `Nothing` strings, so the old and new folds insert the same keys with the same values, in the same ascending order (`Set.foldl`). The resulting `Dict` is identical, even in tree shape.
- `varSupersEncoderS` (TO:1683-1685) is `BE.stdDict` = `Dict.toList` → the bytes are identical.
- The 26 spurious entries (R2, e.g. `"numbers!"`) are deliberately kept.
- The encoder path (`CollectAll`) builds the same set as S1, so the table is unchanged.
- Guard against drift: a comment on `superOfName` saying that `StringTable.isSuperName` must match it. The new unit test (below) pins the two.

**Interaction with S3.**
- S3's type table makes the *encoder* visit each distinct type node once. The table must still contain every string, because a deduplicated node holds exactly the same strings as each occurrence. So the collected string set, and therefore anything derived from it, is unchanged.
- `computeVarSupers` runs in the optimizer before encoding, and its result is needed in memory (cold builds mono `Fresh` graphs), so S3 does not speed it up automatically.
- Post-S3 follow-up, only if S2's residual still shows: let the supers sweep use the same `Eco.Hash.deep` + `==` dedup to skip already-seen type nodes. This is byte-identical by the same set argument: `varSupers` depends only on the set of strings, and duplicates add nothing.
- The S3 encoder collection also adds the `varSupers` keys (TO:1715). This must stay, although they are already members.

**Cost estimate after S1.**
- After S1 the sweep is the traversal plus about 11 string compares per occurrence (member hits): about 5 s of the original 14 s.
- With S2, an occurrence costs at most 4 `startsWith` (most strings fail at the first byte) and no Dict work. A Set is touched only for `number*/comparable*/appendable*/compappend*` strings, a few dozen per module.
- Residual is about 1-1.5 s (pure traversal of the type trees), so S2 saves about 3.5-4 s, matching the plan's "~4 s after S1".
- The encoder path pays one extra tag `case` per string: negligible.

**Tests and gates.**
- New elm-test `compiler/tests/TestLogic/AST/VarSupersEquivalenceTest.elm`. For hand-built and fuzzed `Can.Type`s, assert that `TOpt.varSupersOfType t |> Dict.toList` equals a test-local reference. The type names, record fields, aliases, ext and `TVar`s are drawn from `["number","number1","numbers!","comparable","comparableX","appendable","compappend","compappendY","a","msg","Basics","elm","core"]`. The reference is `StringTable.collected (Can.collectStringsFromType t StringTable.collectAll)` filtered by a test-local mirror of `superOfName` (same `Name.is*Type` order).
- G1, G2, G3, G4; the artifact identity check of §5.1 (it covers `varSupers` bytes in every `.ecot`); G10. A perf profile confirms `computeVarSupers` inclusive time is ≤ 1.5 s.

---

### 5.3 S3 — .ecot v2: per-file type table

**Summary.**
- Every `Can.Type` position in the `.ecot` / `typed-artifacts.dat` body becomes a reference into a per-file **type table**. The table sits after the string table and is deduplicated under Elm `==`.
- Ids are assigned **children-first, in first-occurrence order of a pre-pass**. They never depend on the hash.
- The hash is a new kernel `Eco.Hash.deepWith : (a -> Int) -> a -> Int`:
  - native (C++): a generic structural walk; it ignores the argument;
  - JS and pure-Elm twins: apply the type-specific Elm fallback.
- Measured on today's 275 v1 files (§5.3.1): 449 MB → **17.8 MB**; 151,830 → **149,603** table entries; **728k lookups** in place of 25.6 M collector visits.

Line numbers below are as of 2026-10-03, **before S1/S2**. S1/S2 shift them, so re-grep before editing.

---

#### 5.3.1 Prototype and go/no-go (do this first)

**(a) Python model: done.**
- Script: `/tmp/claude-1000/lower/s3sim.py`. It subclasses `/tmp/claude-1000/agentA/ecot.py`, run in 6 shards over `build/compiler/build-kernel/eco-stuff/0.1.1/*.ecot`.
- Interning key: the arrow slot, the field index, Holey/Filled, the ext and the alias arg names.
- The lookup replay is the §5.3.3 algorithm exactly: whole subtree first, descend only on a miss.

| quantity (sum over 275 files) | value |
|---|---|
| top-level type occurrences (local graph) | 437,383 |
| type nodes encoded today | 25,637,374 |
| table entries (= misses) | 149,603 (avg 544/file, max 3,988 `MonoSolver-Translate`) |
| lookups in the pre-pass (top + descents on miss) | 728,136 (578,533 hits) |
| native node visits, pre-pass: hash / `==` on hits | 38.4 M / 25.5 M |
| native node visits, encode pass: hash / `==` | 25.6 M / 25.6 M |
| max `eqHelp` recursion depth reached by any type (heap levels) | **56** (`MonoSolver-Engine`); the C++ cap is 100 |
| largest single type | 6,002 nodes |
| table bytes (entry ints as `BE.int` f64) / with varints (S10) | 2.06 MB / 1.12 MB |
| ref width: 1 byte / 2 bytes | 132 files / 143 files |
| **total `.ecot` v2** | **17.8 MB** (16.9 MB with S10); typeEnv part unchanged at 0.24 MB |

The biggest modules:

| module | v1 | v2 | top-level occurrences | type nodes | table entries | lookups |
|---|---|---|---|---|---|---|
| `BytesFusion-Emit` | 70.4 MB | 0.31 MB | 7,330 | 3.92 M | 2,389 | 13,982 |
| `MonoSolver-Translate` | 69.8 MB | 0.61 MB | 16,863 | 4.07 M | 3,988 | 24,819 |
| `MLIR-Expr` | 55.8 MB | 0.66 MB | 17,549 | 3.10 M | 3,927 | 25,781 |

**Cost projection.**
- About 115 M native node visits in total, at ~5–15 ns each: **≈ 0.6–1.7 s**.
- Elm-side work: about 1.17 M `HashMap` probes plus 150k inserts: ≈ 0.2 s.
- Byte writing on 17.8 MB instead of 449 MB: ≈ 0.15 s (it is ~3.4 s today: `writeEncoder` + `getWidths`, `ser-profile.txt`).
- Comparison, a pure-Elm full-walk hash: ~64 M Elm node visits. At the measured ~40 ns/node self time of `collectStringsFromType` plus string-hash calls, that is **≈ 3–5 s**. This is why the hash is native (§5.3.2).

**(b) Native prototype on the biggest module.**
1. Build the kernel (§5.3.2), `Data.HashMap` additions, `TypeTable` (§5.3.3) and the `internTypesFrom*` pre-pass (§5.3.4).
2. Wire them into `TOpt.localGraphEncoder` as a **throwaway** extra prefix: the pre-pass, `TypeTable.encoder`, plus a sweep that calls `TypeTable.ref` on every type position. The v1 body stays. Feeding the result into the output stops the optimizer from dropping it. The `.ecot` from this binary is not readable, which is fine because a cold build never reads it.
3. Stage 9 `eco`, cold build of the compiler: `perf record --call-graph fp` on the main thread, as for `ser-profile.txt`. Sum the samples under `Compiler_AST_TypeTable_*`, `Eco_Kernel_Hash_deepWith`, `Utils_equal`/`eqHelp` and the `internTypesFrom*` frames.
4. For the per-module figure, `touch compiler/src/Compiler/Generate/MLIR/BytesFusion/Emit.elm`, rebuild warm (only Emit recompiles, since its interface is unchanged) and profile again. That run's type-table frames are Emit's alone.

**Go/no-go.** Emit carries 15.3 % of the type nodes. Budget: ≤ 3 s of type work for the whole build.

| type-table time for Emit (pre-pass + sweep) | decision |
|---|---|
| ≤ 0.5 s | **go** (projected ≤ 3.3 s for the full build) |
| 0.5–1.5 s | investigate before rollout (hash or `eqHelp` per-node cost; `resolve` overhead) |
| > 1.5 s | **no-go**: projected ≥ 10 s. Fall back to plan B (§5.3.9 R-5) |

Also record the whole-build sum. The plan's serialization target after S3 is 3–6 s.

---

#### 5.3.2 Kernel `Eco.Hash.deepWith` (three twins)

**API decision.** It is `deepWith : (a -> Int) -> a -> Int`, not `deep : a -> Int`.

Contract: the result is a hash consistent with `==`, so `x == y ⇒ deepWith f x == deepWith f y`.
- The native kernel computes it structurally and **never calls `f`**.
- The JS kernel and the pure-Elm twin return `f x`.
- `f` must itself be consistent with `==`.

Why this API:
- Stage 1 (stock Elm, `src-xhr`) cannot write a generic hash: there is no reflection.
- A constant hash collapses every bucket. The table would then cost O(lookups × entries), about 728k × 544 `==` calls on the self-compile, which is too slow for Stage 1 and the JS stages.
- Hashes never cross builds (`Data.HashMap` never serializes one, and ids come from insertion order, §5.3.4), so the twins need not agree **with each other**. Each only has to agree with its own `==`.

**How `string64` is registered today (mirror exactly).**

| registration | `string64` today | `deepWith` |
|---|---|---|
| Elm wrapper | `eco-kernel-cpp/src/Eco/Hash.elm` | add `deepWith`; extend `exposing` |
| JS kernel | `eco-kernel-cpp/src/Eco/Kernel/Hash.js` (`var _Hash_string64 = F2(...)`) | add `_Hash_deepWith` |
| C++ export | `eco-kernel-cpp/src/eco/HashExports.cpp` `Eco_Kernel_Hash_string64(int64_t, HPtr)` | add `Eco_Kernel_Hash_deepWith(HPtr, HPtr)` |
| C++ declaration | `eco-kernel-cpp/src/eco/KernelExports.h:229-232` | add next to them |
| implementation | `eco-kernel-cpp/src/eco/Hash.{hpp,cpp}` | add `Hash::deep` |
| pure twin | `compiler/src-xhr/Eco/Hash.elm` | add `deepWith` |
| CMake | target `EcoKernel_Hash` (`compiler/CMakeLists.txt:769,829`, `test/CMakeLists.txt`) | no change (same files) |
| `eco/kernel` `elm.json` | already exposes `Eco.Hash` | no change |
| LSS_022 license manifest | `Hash*.cpp` **not pinned**, no `KernelSetFacts` row | no row needed. Without a row, the fallback arrow is poisoned (LSS_004), which is harmless because natively it is never applied. G9 is still run |
| `KernelFacts` row (gc-leaf) | **none.** `Hash.hpp` says "gc-leaf", but `Context.registerKernelInstance` stamps `eco.gc_leaf` only from a `KernelFacts.lookup` row (`Generate/MLIR/Context.elm:773-776`), so `string64` calls are statepointed today | mirror: no row. Optional follow-up §5.3.9 step 12 |

**ABI.** A polymorphic kernel gets an all-boxed ABI (`Monomorphize/KernelAbi.elm:85-99`, `PreserveVars`): `!eco.value, !eco.value -> i64`.

**Elm wrapper** (`eco-kernel-cpp/src/Eco/Hash.elm`):
```elm
{-| Structural hash consistent with `==`, for `Data.HashMap` bucket keys only.
Native: a generic walk of the value; `fallback` is never called. JS / stock Elm:
`fallback value`. `fallback` must be consistent with `==`.
-}
deepWith : (a -> Int) -> a -> Int
deepWith fallback value =
    Eco.Kernel.Hash.deepWith fallback value
```

**JS** (`Eco/Kernel/Hash.js`):
```js
// The JS stages have the type-specific Elm fallback, which is exact by
// construction; a generic JS walk would have to replicate _Utils_eqHelp's
// debug/prod Dict/Set/Char cases. Unary Elm functions are plain JS functions.
var _Hash_deepWith = F2(function(fallback, x) { return fallback(x); });
```

**Pure twin** (`compiler/src-xhr/Eco/Hash.elm`): `deepWith fallback value = fallback value`.

**C++: what `==` does (the hash must not be finer).** From `elm-kernel-cpp/src/core/Utils.cpp` `eqHelp` (lines 521–734):
- strings are compared by content across all forms: `StringOps::equal`, `:533-535`;
- byte buffers are compared by view;
- lists are compared by content across Cons and ConsChunk (`eqListHybrid`);
- Dicts (ctor `0xFFFF`, `:45`) are compared by **in-order (k,v)**, ignoring colour and shape (`dictEq`, `:747-797`);
- Custom and Record are compared field-wise, with mixed boxed/unboxed Int/Float/Char equal by value (`eqUnboxableSlot`, `:100-140`);
- Float uses `==` (NaN ≠ NaN, −0 = 0);
- an embedded constant equals only the identical word (`resolveAndCompare`; `UtilsExports.cpp:94-105`);
- closures compare as false;
- **at depth > 100 it returns true** (`:560-563`, recorded as a divergence in `KernelFacts`).

The JS `_Utils_eqHelp` also compares Dicts and Sets by content:
- debug build: the `$ === 'RBNode_elm_builtin'` branch;
- prod build: the `x.$ < 0` branch;
- it is exact at depth (the deferred `stack`).

**C++ sketch** (`Hash.cpp`). The skeleton mirrors `eqHelp`, so the review is a side-by-side diff:
```cpp
namespace {
constexpr int kMaxDepth = 1024;          // C-stack guard only; see note below
constexpr u16 CTOR_DICT_RBNODE = 0xFFFF; // == Utils.cpp:45 == Compiler.Data.CtorTag
constexpr uint64_t kEmpty=0x6a09e667f3bcc909ULL, kStr=..., kList=..., kInt=..., kFlt=...,
                   kChr=..., kTup=..., kCus=..., kRec=..., kArr=..., kDict=..., kByt=...,
                   kConst=..., kOpaque=..., kDeep=...;   // distinct odd constants

inline uint64_t mix(uint64_t h, uint64_t x) {           // order-sensitive
    return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}
inline uint64_t hFloat(double f) { if (f == 0.0) f = 0.0; uint64_t b; std::memcpy(&b,&f,8); return mix(kFlt,b); }
uint64_t hStr(void* s);       // FNV-1a over UTF-16 units: utf8 fast path + charAt loop,
                              // exactly string64's loops; length 0 -> kEmpty
uint64_t hObj(Allocator& a, void* o, int depth);

uint64_t hBits(Allocator& a, uint64_t bits, int depth) {
    if (isConstantBits(bits))                      // True/False/NullCons/Empty words
        return isEmptyConstBits(bits) ? kEmpty      // "" [] () Nothing {} share kEmpty
                                      : mix(kConst, bits);
    return hObj(a, a.resolve(hpFromBits(bits)), depth);
}
uint64_t hSlot(Allocator& a, Unboxable v, uint32_t kind, int depth) {
    switch (kind) {                                 // boxed and unboxed agree, like eqUnboxableSlot
        case 1: return mix(kInt, uint64_t(v.i));
        case 2: return hFloat(v.f);
        case 3: return mix(kChr, v.c);
        default: return hBits(a, hpBits(v.p), depth + 1);   // same +1 as eqUnboxableSlot
    }
}
uint64_t hDict(Allocator& a, Custom* n, int depth) {      // in-order, colour/shape ignored
    Custom* st[128]; int sp = 0; uint64_t h = kDict;          // LLRB height <= 2 log2 n
    auto left = [&](Custom* c){ while (c && c->ctor == CTOR_DICT_RBNODE) { assert(sp < 128); st[sp++] = c; c = resolveCustom(a, c->values[3].p); } };
    left(n);
    while (sp) { Custom* c = st[--sp];
        h = mix(h, hSlot(a, c->values[1], fieldKind(c->unboxed,1), depth));
        h = mix(h, hSlot(a, c->values[2], fieldKind(c->unboxed,2), depth));
        left(resolveCustom(a, c->values[4].p)); }
    return h;
}
uint64_t hObj(Allocator& a, void* o, int depth) {
    if (!o) return kEmpty;
    if (depth > kMaxDepth) return kDeep;
    if (alloc::isString(o)) return hStr(o);                       // all 6 heap forms
    if (alloc::isByteBuffer(o)) return /* FNV over byteBufferView, len 0 -> kEmpty */;
    if (isListNode(o)) {                                          // Cons and ConsChunk alike
        alloc::ListCursor c(a.wrap(o)); if (c.done()) return kEmpty;
        uint64_t h = kList;
        for (; !c.done(); c.next()) h = mix(h, hSlot(a, c.current(), c.currentKind(), depth));
        return h;
    }
    switch (getTag(o)) {
        case Tag_Int:   return mix(kInt, uint64_t(((ElmInt*)o)->value));
        case Tag_Float: return hFloat(((ElmFloat*)o)->value);
        case Tag_Char:  return mix(kChr, ((ElmChar*)o)->value);
        case Tag_Tuple2: case Tag_Tuple3: /* kTup; fields via tupleFieldKind(hdr->unboxed, i) */
        case Tag_Custom: { auto* c = (Custom*)o;
            if (c->ctor == CTOR_DICT_RBNODE) return hDict(a, c, depth);
            uint64_t h = mix(mix(kCus, c->ctor), c->header.size);
            for (u32 i = 0; i < c->header.size; ++i) h = mix(h, hSlot(a, c->values[i], fieldKind(c->unboxed,i), depth));
            return h; }
        case Tag_Record: /* as Custom with kRec, r->unboxed */
        case Tag_Array:  /* mix(kArr,length); uniform kind header.unboxed & 3 */
        default: return mix(kOpaque, getTag(o));   // closures, DynRecord, tasks: eq is false/identity
    }
}
} // namespace
int64_t deep(uint64_t bits) { return int64_t(hBits(Allocator::instance(), bits, 0)); }
```
```cpp
// HashExports.cpp
int64_t Eco_Kernel_Hash_deepWith(HPtr /*fallback: JS/Elm twins only*/, HPtr value) {
    return Hash::deep(value.toBits());
}
```

**Kernel guarantees.**
- **No Elm allocation and no callback.** It reads only, through `Allocator::resolve` as `eqHelp` does, and uses a fixed-size dict stack, so no C++ heap is used either. No GC can run during the call: single mutator (CR-012 option F); the concurrent marker does not move objects. It would be gc-leaf-eligible under `KernelFacts` (`gcAlloc = GcNone`, `cppAlloc = False`, `callsBack = HofNo`); see step 12.
- **No coarse cap.** `kMaxDepth = 1024` only protects the C stack. A hash cap ≤ 100 would make the hash *and* `eqHelp`'s depth-100 "assume equal" blind to the same tail, which is a deterministic false merge (a miscompile). With a full-depth hash, a false merge needs a type whose difference lies only below heap depth 100 **and** a 64-bit collision. The measured maximum is 56.
- Shared helpers:
  - `CTOR_DICT_RBNODE` is static in `Utils.cpp` (also duplicated in `HttpExports.cpp:78`), so define it locally with a comment naming both;
  - `isListNode` and `resolveCustom` mirror `Utils.cpp` and `dictEq`'s lambda;
  - the Const_Empty predicate is `Heap.hpp:331-334`.

**Pure-Elm fallback** (lives in `TypeTable`, §5.3.3). It follows the `Store.groundHash` precedent (`MonoSolver/Store.elm:3844-3846`): `mix h x = modBy 67108864 (h * 33 + modBy 67108864 x + 7)`, which is exact in JS doubles, with names hashed by `Eco.Hash.string`. It is a full walk:
- records go through `Dict.foldl`, i.e. key order, i.e. content;
- `TLambda` hashes `Can.arrowSlotToInt slot`;
- `TAlias` hashes `Holey`/`Filled` and the arg names.

It runs only on Stage 1, the JS stages 2–5 and elm-test-rs. Estimated cost on the JS self-compile: ~64 M node visits, a few seconds. Gate A's E2E programs are tiny.

---

#### 5.3.3 `Compiler/AST/TypeTable.elm` (new) and `Data.HashMap` additions

**`Data.HashMap` additions** (`compiler/src/Data/HashMap.elm`). These avoid hashing twice on a miss: `insert` re-hashes and re-scans, `HashMap.elm:129-152`.
```elm
getHashed : Int -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
getHashed h eq key (HashMap _ _ buckets) =
    case Dict.get h buckets of
        Nothing -> Nothing
        Just bucket -> scanBucketBy eq key bucket

{-| PRECONDITION: `key` is absent (the caller just missed with `getHashed h`). -}
insertNew : Int -> k -> v -> HashMap k v -> HashMap k v
insertNew h key value (HashMap count nextSeq buckets) =
    HashMap (count + 1) (nextSeq + 1)
        (Dict.insert h (( nextSeq, key, value ) :: Maybe.withDefault [] (Dict.get h buckets)) buckets)
```

**Module skeleton.**
```elm
module Compiler.AST.TypeTable exposing
    ( Builder, empty, add, intern, size, collectStrings
    , TypeTable, freeze, ref, encoder
    , Decoded, decoder, refDecoder
    , hashType, hashTypeElm )

type Entry                                   -- one table row; child refs are ids < own id
    = ELambda Int Int Int                    -- arrowSlotToInt slot, a, b
    | EVar Name
    | EType ModuleName.Canonical Name (List Int)
    | ERecord (List ( Name, Int, Int )) (Maybe Name)   -- (field, FieldType index, type id), Dict.toList order
    | EUnit
    | ETuple Int Int (List Int)
    | EAlias ModuleName.Canonical Name (List ( Name, Int )) Bool Int   -- args, True = Filled, body id

type Builder = Builder { ids : HashMap (Can.Type Name) Int, rev : List Entry, count : Int }
type TypeTable = TypeTable { ids : HashMap (Can.Type Name) Int, entries : List Entry, count : Int, width : Int }

hashType : Can.Type Name -> Int
hashType =
    Eco.Hash.deepWith hashTypeElm     -- point-free CAF: no closure built per call (check the MLIR)

empty : Builder
add : Can.Type Name -> Builder -> Builder
add t b = Tuple.second (intern t b)

intern : Can.Type Name -> Builder -> ( Int, Builder )
intern t ((Builder r) as b) =
    let h = hashType t in
    case HashMap.getHashed h (==) t r.ids of
        Just id -> ( id, b )                                  -- hit: never descends
        Nothing ->
            let ( entry, Builder r1 ) = internChildren t b    -- children first
                id = r1.count
            in ( id, Builder { ids = HashMap.insertNew h t id r1.ids, rev = entry :: r1.rev, count = id + 1 } )

internChildren : Can.Type Name -> Builder -> ( Entry, Builder )
internChildren t b =
    case t of
        Can.TLambda slot x y -> let (ix, b1) = intern x b; (iy, b2) = intern y b1 in ( ELambda (Can.arrowSlotToInt slot) ix iy, b2 )
        Can.TVar n -> ( EVar n, b )
        Can.TType home name args -> let (is, b1) = internList args b in ( EType home name is, b1 )
        Can.TRecord fields ext ->
            let (rev, b1) = Dict.foldl (\k (Can.FieldType i ft) (acc, bb) -> let (id, bb1) = intern ft bb in ( (k, i, id) :: acc, bb1 )) ( [], b ) fields
            in ( ERecord (List.reverse rev) ext, b1 )
        Can.TUnit -> ( EUnit, b )
        Can.TTuple x y cs -> ... ( ETuple ix iy ics, b3 )
        Can.TAlias home name args at ->
            let (revArgs, b1) = List.foldl (\(n, a) (acc, bb) -> let (id, bb1) = intern a bb in ( (n, id) :: acc, bb1 )) ( [], b ) args
                ( filled, body ) = case at of Can.Holey x -> ( False, x ); Can.Filled x -> ( True, x )
                ( ib, b2 ) = intern body b1
            in ( EAlias home name (List.reverse revArgs) filled ib, b2 )

freeze : Builder -> TypeTable          -- entries = List.reverse rev; width = 1 | 2 | 4 by count (StringTable's rule)

ref : TypeTable -> Can.Type Name -> BE.Encoder
ref (TypeTable r) t =
    case HashMap.getHashed (hashType t) (==) t r.ids of
        Just id -> refEncoder r.width id
        Nothing -> Utils.Crash.crash "TypeTable.ref: type not interned by the pre-pass (internTypesFrom*/encoder drift)"

collectStrings : Builder -> Set String -> Set String   -- strings of DISTINCT entries only
--   EVar n -> n;  EType/EAlias -> ModuleName.collectStringsFromCanonical home + name (+ alias arg names);
--   ERecord -> field names (+ ext)
```

**Notes.**
- **Key = the whole `Can.Type`, eq = `(==)`.** That is exactly the R3 key: slot, field index, Holey/Filled, ext and alias arg names are all constructor data that `==` compares. `TypeIds.ArrowSlot` has `Arrow` too; it cannot occur in `Can.Type Name` (`Canonical.elm:358-376`) and encodes as 0, the same as v1.
- **Lossless dedup.** `==`-equal types have identical v1 encodings: `TRecord` goes through `BE.stdDict`, i.e. `Dict.toList` in key order (content, not tree shape), and strings are content. So one entry per `==` class loses nothing.
- **`TRecord` canonicalisation.** `Dict.toList` order (sorted by field name). Each field carries its `FieldType` index and the type id; ext comes after. On decode, `Dict.fromList`.
- **Expose** from `Canonical.elm`: `arrowSlotToInt`, `arrowSlotFromInt`, `freeVarsEncoderS`, `freeVarsDecoderS`.

---

#### 5.3.4 The pre-pass and determinism

**Decision: the pre-pass order need NOT match the encoder's.** Byte equality between the JS-written and native-written `.ecot` (G7) follows from these points:
1. Ids come from a counter in the pre-pass's visit order, and the table is emitted in id order. The hash only selects a bucket; `getHashed` + `(==)` decide. So the hash implementation (C++ vs Elm fallback) cannot change a byte.
2. The pre-pass is the same Elm code on both hosts, and folds only over ordered structures (`Data.Map.foldl compareGlobal`, `Dict.foldl`, lists).
3. JS `==` and native `==` agree on `Can.Type`. Both compare Dicts and strings by content. Native's only divergence is the depth-100 cap: measured max 56, and with a full-depth hash a merge also needs a 64-bit collision.
4. The string table is unchanged: it is a sorted `Set`, ECOT_002.

**Fixing the encoder order instead buys nothing.** The decoder reads the whole table before the body.

The pre-pass is a **types-only twin** of the string collectors, placed in `TypedOptimized.elm` next to them (§"STRING COLLECTORS", `:1705`). Every function that reaches a `Can.Type` gets a twin, and all of them take `TypeTable.Builder -> TypeTable.Builder`:

| new twin | type positions it adds (via `TypeTable.add`) |
|---|---|
| `internTypesFromLocalGraph` | `data.nodes` (`Data.Map.foldl compareGlobal`), then `data.annotations` (`Dict.foldl`, the `Forall` body) |
| `internTypesFromGlobalGraph` | nodes, then annotations (both `Data.Map.foldl compareGlobal`) |
| `internTypesFromNode` | `Define`/`TrackedDefine`/`PortIncoming`/`PortOutgoing`: expr, then `meta.tipe`; `Ctor`/`Enum`/`Box`: tipe; `Cycle`: values' exprs, then defs; `Link`/`Manager`/`Kernel`: none |
| `internTypesFromDef` | `Def`: expr, tipe; `TailDef`: arg types, expr, tipe |
| `internTypesFromExpr` | sub-expressions per variant (below), then `typeOf expr` (`:183`; every variant's meta) |
| `internTypesFromDestructor` | `meta.tipe` |
| `internTypesFromDecider` | `Leaf (Inline e)` → expr; `Jump` → none; `Chain`/`FanOut` → sub-deciders in order (DT paths and tests carry no `Can.Type`: `DecisionTree/Test.elm:43-44`) |

**Sub-expressions per `Expr` variant.**
- `List`: values.
- `Function`: arg types, then body.
- `TrackedFunction`: arg types, then body.
- `Call`: func, then args.
- `TailCall`: arg exprs.
- `If`: branches (cond, then body), then final.
- `Let`: def, then body.
- `Destruct`: destructor, then body.
- `Case`: decider, then jumps.
- `Access`: record.
- `Update`: record, then field exprs (`Data.Map.foldl A.compareLocated`).
- `Record`: `Dict.foldl`.
- `TrackedRecord`: `Data.Map.foldl A.compareLocated`.
- `Tuple`: a, b, cs.
- All others: none.

**Missing a position is caught loudly.** If the encoder reaches a type the pre-pass never interned, `TypeTable.ref` crashes. Tests run every standard case through the encoder (§5.3.8), so drift cannot ship silently.

**Combined pre-pass** (used by the encoders and by `computeVarSupers`, §5.3.7):
```elm
prePassLocal : LocalGraph Name -> ( Set String, TypeTable.Builder )
prePassLocal graph =
    let tb = internTypesFromLocalGraph graph TypeTable.empty
    in ( TypeTable.collectStrings tb (collectStringsFromLocalGraph graph Set.empty), tb )
-- prePassGlobal likewise with the GlobalGraph variants
```

---

#### 5.3.5 Wire format v2

```
.ecot      := localGraph(v2) moduleTypeEnv(v1, own string table — unchanged)
graph(v2)  := u8 version=2  stringTable(ECOT_002, unchanged)  typeTable  body
typeTable  := u8 refWidth(1|2|4)  u32 count  entry{count}          -- entry i refs only ids < i
entry      := 0 BE.int(slot) ref ref                                -- TLambda (slot: 0 none, idx+1 SolverRoot)
            | 1 str                                                 -- TVar
            | 2 str str str str BE.list(ref)                        -- TType author project module name args
            | 3 BE.list(str BE.int(index) ref) BE.maybe(str)        -- TRecord, Dict.toList order; ext
            | 4                                                     -- TUnit
            | 5 ref ref BE.list(ref)                                -- TTuple
            | 6 str str str str BE.list(str ref) u8(0 Holey|1 Filled) ref   -- TAlias
str        := StringTable.string st  (u8/u16/u32)
ref        := u8 | u16 BE | u32 BE   by refWidth (count ≤ 256 → 1, ≤ 65,536 → 2, else 4)
body       := as v1, with every Can.Type replaced by `ref`; an annotation is
              BE.list(str) freeVars + ref
```

- **Tags and field order are v1's** (`Canonical.elm:669-731`), with nested types replaced by refs. A v1 reader such as `ecot.py` ports in a few lines.
- **Ints in entries** stay `BE.int` (f64) for now; S10 may change them to varints (2.06 → 1.12 MB).
- **Unchanged:**
  - `TypeEnv.moduleTypeEnvEncoder` (`AST/TypeEnv.elm:156-167`) and `globalTypeEnvEncoder`;
  - `.eci` (`Can.annotationEncoder` with `StringTable.disabled`);
  - `Can.typeEncoderS`/`typeDecoderS`, still used by TypeEnv and interfaces.

**Version.**
- `typedGraphFormatVersion` 1 → **2** (`TypedOptimized.elm:1559-1561`).
- `V.compiler` 0.1.1 → **0.1.2** (`Compiler/Elm/Version.elm:178`, `Version 0 1 1`; extend the comment at `:168-177`). This is S12a, in the same change set.

---

#### 5.3.6 Site changes

**`TypedOptimized.elm` signatures.** Encoders gain `tt : TypeTable` after `st`. Decoders gain `tdt : TypeTable.Decoded`. Inside this module every `Can.typeEncoderS st` becomes `TypeTable.ref tt` and every `Can.typeDecoderS st` becomes `TypeTable.refDecoder tdt`; the edit is mechanical.

| lines | function | change |
|---|---|---|
| 516-530 | `globalGraphEncoder` | `( strs, tb ) = prePassGlobal graph`; `st = StringTable.build strs`; `tt = TypeTable.freeze tb`. Emit `TypeTable.encoder st tt` after `:525`. Then `:526` `nodeEncoderS st tt`, `:527` `annotationEncoderT st tt` |
| 535-551 | `globalGraphDecoder` | after `StringTable.tableDecoder` (`:540`), `andThen TypeTable.decoder st`; then `:547` `nodeDecoderS st tdt`, `:548` `annotationDecoderT st tdt` |
| 564-578 | `localGraphEncoder` | as for the global graph: `:574` nodes, `:575` annotations |
| 583-606 | `localGraphDecoder` | `:602` nodes, `:603` annotations |
| 625-632 | `metaEncoderS` / `metaDecoderS` | `metaEncoderS tt meta = TypeTable.ref tt meta.tipe`; `metaDecoderS tdt` (st dropped) |
| 640-711 | `nodeEncoderS` | types at 647, 655, 663, 670, 676, 703, 710; recursive calls at 646, 654, 689, 690, 702, 709 |
| 714-770 | `nodeDecoderS` | 722-723, 728-729, 735, 740, 743, 751-752, 762-763, 767-768 |
| 775-802 | `typedLocatedName{En,De}coderS`, `typedName{En,De}coderS` | 779, 787, 794, 802 |
| 805-1060 | `exprEncoderS` | 30 meta sites (813 … 1059) plus recursive calls; `:991` becomes `deciderEncoderS st (choiceEncoderS st tt) decider` |
| 1063-1262 | `exprDecoderS` | 30 `metaDecoderS st` → `metaDecoderS tdt` (1073 … 1258); `:1207` passes `choiceDecoderS st tdt` |
| 1265-1294 / 1297-1335 | `defEncoderS` / `defDecoderS` | 1274, 1282, 1284 / 1308, 1314, 1316 |
| 1337-1351 | `destructor{En,De}coderS` | 1342, 1351 |
| 1406-1436 | `choice{En,De}coderS` | add `tt` / `tdt` |
| 1354-1404 | `deciderEncoderS` / `deciderDecoderS` | **no change** (they take the inner codec) |
| new | `annotationEncoderT` / `annotationDecoderT` | `Can.freeVarsEncoderS st freeVars` + `TypeTable.ref tt tipe`; decoder mirrors it |

**Callers outside `TypedOptimized`: no code change.** They call the exposed graph codecs, so they switch format automatically:
- `TypedModuleArtifact.elm:68-82` (`.ecot`);
- `Builder/Elm/Details.elm`:
  - `:311`, the dead `to.dat` reader (R14): a v1 file fails decode, which gives `Nothing`, which is today's behaviour;
  - `:391/401` `packageTypedArtifacts`;
  - `:2140/2150` `typed-artifacts.dat`;
  - `:2265/2296` `DResult`;
- `Builder/Build.elm:2619-3119` (`BResult` MVar codecs);
- `Builder/Generate.elm:656`.

---

#### 5.3.7 String collection and `computeVarSupers` (interaction with S2)

**String collectors** (`TypedOptimized.elm:1705-2196`) **stop visiting types.** Type strings now come from `TypeTable.collectStrings`. The union is **the same set as v1**, so the string table is byte-identical to v1's, which is a free check in the prototype. The reason: every occurrence is either interned, so all its nodes are entries, or `==` to an interned tree with identical strings.

| function | change |
|---|---|
| `collectStringsFromAnnotationPair`, `collectStringsFromGlobalAnnotationPair` (`:1736-1748`) | `Can.collectStringsFromAnnotation ann` → free-var keys only |
| `collectStringsFromMeta` (`:1836-1838`) | delete; drop its 32 call sites in `collectStringsFromExpr` |
| `collectStringsFromNode` (`:1841-1887`) | drop `Can.collectStringsFromType` at 1845, 1848, 1851, 1854, 1857, 1884, 1887 |
| `collectStringsFromDef` (`:1890-1910`) | drop 1897, 1905, 1910 (keep arg names) |
| `collectStringsFromExpr` (`:1913-2110`) | `Function`/`TrackedFunction`: keep arg names, drop arg types |
| `collectStringsFromDestructor` (`:2113-2118`) | drop the meta |
| `…Global`, `…SchemeRoots`, `…GlobalSchemeRoots`, `…Path`, `…ContainerHint`, `…Decider`, `…Choice` | unchanged |

**`computeVarSupers` (`:1816-1821`) must change in the same commit.** Today it is `Set.foldl insertSuperOfName Dict.empty (collectStringsFromLocalGraph g Set.empty)`. Once that collector skips types, the result would silently lose every `number`/`comparable`/… type variable, and mono would lose super constraints: a **miscompile**, not just a byte diff.

**Decision.**
- **S3a, the minimal step.** `computeVarSupers` keeps S2's own traversal, which still walks type positions. S2's "byte-identical variant" must **not** be built on `collectStringsFrom*`. If it is, apply S3b in the same commit.
- **S3b, recommended and measured.**
  ```elm
  computeVarSupers graph =
      Set.foldl insertSuperOfName Dict.empty (Tuple.first (prePassLocal graph))
  ```
  - It is byte-identical by the set equality above: the same strings, including the 26 spurious literal hits of R2.
  - It replaces S2's Elm walk of all 25.6 M type nodes (~4 s estimated) with the native-hashed pre-pass (~0.5–0.8 s).
  - Cost: the pre-pass runs twice per module, once in the optimizer (`LocalOpt/Typed/Module.elm:107,121`) and once in the writer. Caching the `Builder` would need a new `LocalGraphData` field, so it is left out unless G10 shows it matters.
- `varSupersOfType` (`:1824`, used only by `AssignMVarIds.elm:275`) is unchanged.

---

#### 5.3.8 Tests and S3-specific gate procedures

**New elm-test-rs modules.** They are discovered automatically: every exposed `Test`, as in `tests/Compiler/Data/HashMapTest.elm`. They run on the pure twin, i.e. the Elm fallback hash.

1. **`compiler/tests/Compiler/AST/TypeTableTest.elm`**
   - **Dedup:**
     - `[Int, List Int, List Int, Int -> List Int]` → `size` = 3;
     - re-interning a type whose subtrees all exist adds exactly 1.
   - **Must not merge** (`size` grows by the expected count):
     - `NoArrow` vs `SolverRoot 0` vs `SolverRoot 7`;
     - `Holey t` vs `Filled t`;
     - field index 0 vs 1;
     - ext `Nothing` vs `Just "r"`;
     - alias args `[("a",Int)]` vs `[("b",Int)]`;
     - packages that differ only in author;
     - tuple arity 2 vs 3.
   - **Must merge:** two `TRecord`s whose `Dict` was built in opposite insertion orders (different tree shape, `==`) → one id.
   - **Round trip:** encode the table plus a list of refs, then decode; every type is `==` the original. Run it on the hand-written cases and on a depth-bounded `Fuzz (Can.Type Name)` (`Test.fuzzWith { runs = 200 }`).
   - **Widths:** 300 distinct `TVar`s give ref width 2 and still round-trip.
   - **Children-first:** hand-built bytes with a self or forward ref (`count=1`, entry `0 slot ref0 ref0`) give decode `Nothing`; a body ref ≥ count gives `Nothing`.
   - **Drift:** `ref` on an un-interned type crashes. Test this through `Expect` on a `Result`-returning internal variant (`refMaybe`), not on the crash itself.
2. **`compiler/tests/Compiler/AST/TypedOptimizedCodecTest.elm`.** It runs over `SourceIR.Suite.StandardTestSuites` via `TestPipeline.runToTypedOpt` (`tests/TestLogic/TestPipeline.elm:274`).
   - **Local round trip:** `bytes = encode localGraphEncoder g`; `g2 = decode bytes`.
     - `encode g2 == bytes` (re-encode idempotence);
     - `annotations g2 == annotations g` (no erasure applies);
     - per node, after a test-local erase (deps → empty, `meta.tvar` → `Nothing`, `Function`/`TrackedFunction` `SrcLambdaId` → `Nothing`, `Manager` → `Cmd`, `Kernel` → `[]`, as decoded at `:714-770`, `:1160-1170`), `node2 == erase node`.
   - **Global round trip:** the same through `globalGraphEncoder`. Expose `localGraphToGlobalGraph` (`TestPipeline.elm:691`).
   - **Determinism:** two independent `runToTypedOpt` runs give identical bytes.
   - **Prefix check:** after the version byte the bytes are `StringTable` then `TypeTable.decoder`. That decoded table's strings are the string table, and the string table equals the v1 `Set` (computed in the test as the collector set ∪ table strings).
   - **`varSupers` completeness:**
     - every `TVar n` in the decoded table with `superOfName n /= Nothing` is a key of `computeVarSupers g`;
     - every key has a super prefix.

**Native kernel E2E: `test/eco-kernel/src/HashDeepWithTest.elm`** (`-- CHECK: HashDeepWithTest: True`). For each pair that is `==` but differently represented, `Eco.Hash.deepWith (\_ -> 0) a == Eco.Hash.deepWith (\_ -> 0) b`. A fallback of `\_ -> 0` would make a twin trivially pass, so this exercises only C++. Pairs:
- Dicts from opposite insertion orders, and Sets;
- string literal vs `String.slice`/`++`/rope;
- `String.fromList` (UTF-8 vs UTF-16 forms);
- a boxed-Int list vs an `Array.toList`/`List.range` list;
- tuples holding Int/Float/Char;
- `-0.0` vs `0.0`;
- records;
- a large `Can.Type`-like nested custom value.

Plus 50 random distinct pairs: hashes are pairwise distinct.

**Gate procedures specific to S3** (in addition to G1–G4, G9, G10):
- **G5:** as in §1. Also run `cmp` on the `.ecot`s of a second cold build against the first (native determinism).
- **G7:**
  - Step 0, before S3: confirm that **v1** Stage 5 `.ecot` == Stage 9b cold `.ecot` for the 5 modules today. Otherwise a pre-existing non-S3 difference would be blamed on S3.
  - After S3:
    1. right after Stage 5, `cp build/compiler/build-kernel/eco-stuff/0.1.2/*.ecot /tmp/g7-js/`;
    2. delete `eco-stuff/0.1.2` and run Stage 9b cold (`eco-verify`), which writes into the same `build-kernel` dir;
    3. `cmp` the five files: `Compiler-Generate-MLIR-BytesFusion-Emit`, `Compiler-MonoSolver-Translate`, `Compiler-Generate-MLIR-Expr`, `Utils-Crash`, `Control-Loop`.
- **G8:**
  - **(a)** With the populated `eco-stuff/0.1.1` and `~/.eco/0.1.1` left in place, the S3 compiler uses the `0.1.2` dirs: packages rebuild, and there is no `GenerateCannotLoadArtifacts` and no "Corrupt File".
  - **(b) Negative control:** a v1 `.ecot` copied into `eco-stuff/0.1.2` still fails with `GenerateCannotLoadArtifacts`. The cause is the existence-only check, `Build.elm:878-894`. This is expected; record it as the known limit that the version bump exists to avoid.
- **v1 ↔ v2 semantic equivalence (new, offline).**
  - Extend the decoder to v2 (resolve refs into nested tuples) and commit it as `scripts/ecot.py` with v1 and v2 support, plus `0.1.2` paths (R9).
  - For all 275 modules, decode the v1 `.ecot` from the pre-S3 Stage 9 and the v2 `.ecot` from the S3 Stage 9 (same sources, cold). The expanded graphs, including `varSupers`, must be identical. This is the byte-identity proof for §5.3.7.

---

#### 5.3.9 Rollout checklist, risks

**Ordered steps.** These form one change set with S12a and S12d (the format break). Each step compiles on its own.

1. **Kernel** (§5.3.2): `Hash.hpp` and `Hash.cpp` (`deep`), `HashExports.cpp`, `KernelExports.h`, `Eco/Kernel/Hash.js`, `eco-kernel-cpp/src/Eco/Hash.elm`, `compiler/src-xhr/Eco/Hash.elm`. Add `HashDeepWithTest.elm`. Run G9.
2. **`Data.HashMap`:** `getHashed` and `insertNew`. Add cases to `HashMapTest.elm` (collision buckets).
3. **`Canonical.elm`:** expose `arrowSlotToInt`, `arrowSlotFromInt`, `freeVarsEncoderS`, `freeVarsDecoderS`.
4. **`Compiler/AST/TypeTable.elm`** (§5.3.3) and `TypeTableTest.elm`.
5. **Prototype measurement** (§5.3.1 b). Stop here on no-go.
6. **`TypedOptimized`:** add the `internTypesFrom*` twins, `prePassLocal` and `prePassGlobal` (§5.3.4), and drop types from the string collectors (§5.3.7).
7. **`computeVarSupers`:** switch to S3b in the **same commit** as step 6 (or confirm that S2's traversal is independent, S3a).
8. **Codec signatures and sites** (§5.3.6). Set `typedGraphFormatVersion = 2`. Add `TypedOptimizedCodecTest.elm`.
9. **S12a:** `Version.elm:178` → `Version 0 1 2`. Fix the hard-coded `0.1.1` paths in `benchmarks/fhr-matrix.sh:18`, `benchmarks/l3-corunner.sh:24` and `benchmarks/fhr-gc-points-runs.sh:6`, and in `ecot.py`.
10. **S12d:** add an **ECOT_003** row to `design_docs/invariants.csv`. Header: `id;phase;category;status;description;source`. Text:
    > `ECOT_003;Serialization;TypedArtifacts;tested;.ecot and typed-artifacts.dat (typedGraphFormatVersion 2) carry a per-file TYPE TABLE after the ECOT_002 string table; every Can.Type position in the body is a ref (u8/u16/u32 by table size) into it. Entries are deduplicated under Elm == with Eco.Hash.deepWith (C++ structural walk / JS and pure-Elm type-specific fallback) as the bucket hash only; dedup is lossless because ==-equal types have identical encodings (records by Dict.toList, strings by content). Ids are assigned children-first in first-occurrence order of TypedOptimized's internTypesFrom* pre-pass, never from the hash, so bytes are host-independent (JS == native, G7). Entry i references only ids < i; a bad ref or version byte fails decode. Every type the encoder emits must have been interned by the pre-pass (TypeTable.ref crashes otherwise). The string table is the same set as v1: body strings plus strings of distinct entries. computeVarSupers is computed from the same pre-pass. Any layout change bumps typedGraphFormatVersion AND V.compiler.;compiler/src/Compiler/AST/TypeTable.elm + compiler/src/Compiler/AST/TypedOptimized.elm`
11. **Gates:**
    - G1–G4 and G9;
    - the S3 procedures for G5, G7 and G8 and the v1 ↔ v2 equivalence check (§5.3.8);
    - G10 cold and warm 9b: record the serialization phase time, the `.ecot` total (expected ~17.8 MB) and the warm decode time;
    - update the §3 table with the measured values.
12. **Optional, measured separately:** a `KernelFacts` row `( "Hash", "deepWith" )`:
    - built from `auditedPure`, with `params = [PBorrowed, PBorrowed]`, `gcAlloc = GcNone`, `cppAlloc = False`, `callsBack = HofNo`;
    - evidence: `Hash.cpp` lines plus `HashExports.cpp`;
    - this gets `eco.gc_leaf` and drops the statepoint at ~1.2 M calls;
    - run `KernelFactsTest`.

    Rows for `string64`/`stringWithSeed` would follow the same audit.

**Risks and mitigations.**

| # | risk | mitigation |
|---|---|---|
| R-1 | Pre-pass and encoder drift: a type position not interned | `TypeTable.ref` crashes, never emits a wrong id. The codec test runs all standard suites; G2 and G4 run the compiler |
| R-2 | `computeVarSupers` silently loses type-variable names after the collector change, so mono loses supers | Same-commit rule (step 7); the `varSupers` completeness test; the v1 ↔ v2 equivalence check compares `varSupers` on all 275 modules |
| R-3 | Native `==` caps at depth 100 and could falsely merge two types | Full-depth native hash (only a 64-bit collision plus a > 100-deep type triggers it); measured max depth 56. The real fix, an explicit-stack `eqHelp`, touches LSS_022-pinned `Utils.cpp` and is out of scope; noted in ECOT_003 review |
| R-4 | Hash inconsistent with `==` (a missed representation case) gives duplicate entries | Only size and speed suffer, never correctness, because `==` decides. Caught by the E2E pair test and by an entry count above the model's 149,603 |
| R-5 | Native kernel blocked (ABI or LSS surprise with a function-typed kernel parameter) or too slow | Plan B: use `hashTypeElm` natively too (`hashType = hashTypeElm`). Same bytes, no kernel; costs ~3–5 s more cold (§5.3.1), still well below today's ~24 s after S1+S2 |
| R-6 | `hashType` builds a closure per call | Point-free CAF definition; check the MLIR for `eco.papCreate` in `TypeTable_hashType` |
| R-7 | Stale v1 caches | `V.compiler` bump relocates every cache (G8 a). Mixed trees inside one version dir fail loudly (G8 b) |
| R-8 | JS stages slower (Elm fallback full walk plus generic `_Utils_eq`) | ~64 M fallback visits plus ~51 M `eq` visits on the JS self-compile, a few seconds against the v1 Set-insert cost; measure Stage 5 wall in G4 |
| R-9 | Decoded graphs now share type subtrees | Elm values are immutable, so this is semantically invisible. It reduces warm-build heap (25.6 M → 150k nodes) and speeds up `==` (pointer fast path) |

### 5.4 S4 — one-shot mode

**Choice: CLI flag `--no-cache`, not an env var.**
- It is explicit per invocation, so it does not leak into child processes or the harness environment.
- `checkForUnknownFlags` already guards it.
- `eco make --help` shows it.

**Plumbing:**
1. **`Terminal/Main.elm`:**
   - Add `|> Terminal.more (Terminal.onOff "no-cache" "Do not write per-module caches (.eci/.eco/.ecot) or the local build state (d.dat); the next build sees nothing compiled by this one.")` after `stats` (`:309`).
   - Add a `noCache_` lambda argument and `|> Chomp.apply (Chomp.chompOnOffFlag "no-cache")` at `:340`, with `noCache = noCache_` in the record (`:326`).
2. **`Terminal/Make.elm`:**
   - Add `noCache : Bool` to `FlagsData` (`:88`).
   - Thread it as one positional `Bool` through `runHelp` → `runHelpWithScope` (`:203`) → `loadDetailsAndBuild` (`:214`) → `buildWithDetails` (`:226`) → `buildPaths` (`:567`).
   - `buildPaths` calls `Build.fromPathsWith (if noCache then Build.OneShot else Build.WriteCaches) …`.
   - `buildExposed` (docs) ignores the flag.
3. **`Builder/Build.elm`:**
   ```elm
   type CacheMode = WriteCaches | OneShot        -- exposed
   EnvData += cacheMode : CacheMode               -- makeEnv gains a CacheMode param (:116); :227 and :2012 pass WriteCaches
   fromPaths  = fromPathsWith WriteCaches          -- unchanged signature: API/Make.elm:132, Test.elm:1259 untouched
   fromPathsWith : CacheMode -> Reporting.Style -> FilePath -> Maybe String -> Maybe Pkg.Name -> Details.Details -> Bool -> FEStats.Handle -> NE.Nonempty FilePath -> Task Never (Result Exit.BuildProblem Artifacts)
   ```
   - `CompileResultContext` gets `cacheMode : CacheMode`, threaded exactly like `maybeBuildDir` in S12b (same four functions and two ctx literals). S4 goes after S12b.
   - `writeUntypedObjectsIfNeeded`, `writeTypedObjectsIfNeeded` and the `.eci` write: wrap each in `case ctx.cacheMode of OneShot -> Task.succeed (); WriteCaches -> <write>`. Skipping the write skips the `Bytes.Encode.encode` too, which is where the time goes.
   - **Keep the old `.eci` read** in the comparison. In a cold one-shot it is a missing-file stat. In a warm one-shot it keeps `RSame`, so unchanged-interface dependents stay cached in-run.
   - Without the read, every module would be `RNew`. That is also correct (RNew only over-invalidates dependents within this run), just slower when warm.
4. **`d.dat`: skip the write entirely, at all three local writers.**
   - `writeDetailsAndReturn` (`:345`, from `collectResultsAndWriteDetails :340`) — exposed path, never one-shot.
   - `writeDetailsAndCollectRoots` (`:535-536`, from `finalizePathBuild :523`): give it the `Env` and use `case envData.cacheMode of OneShot -> Task.succeed (); WriteCaches -> writeDetails …`.
   - REPL `:2086` — never one-shot.

   Leave `Details.load`'s regenerate writes (`Details.elm:861-863`) alone. They write package-level `o.dat`/`i.dat` and a `d.dat` with `locals = Dict.empty`, which claims no local artifact.

   Writing `d.dat` "with no locals" is worse: it would discard a previous normal build's valid locals for no benefit. Deleting stale `.eci`/`.ecot` is unnecessary (proof below).

**Why one-shot never yields `RBlocked` or `Corrupted`.**
- `Corrupted` is produced only by `loadInterface` (`Build.elm:1244-1250`), for a dep in state `Unneeded`, i.e. an `RCached` module (`:927-929`) whose `.eci` is missing or bad.
- `RCached` requires two things: a `locals` entry in `d.dat` whose time matches the source (`crawlWithTime :663-671`), and the `.ecot`/`.eco` on disk (`:884-894`).
- **Invariant:** one-shot writes none of {local entries of `d.dat`, `.eci`, `.eco`, `.ecot`}. The only exception is a `Details` regeneration, which sets `locals = ∅` and so removes claims rather than adding them.
- Therefore every (local entry, `.eci`, `.ecot`) triple that this run or any later run observes was produced by a normal build. A normal build writes `.eci` for every `RNew` (and keeps it for `RSame`) before it writes `d.dat`.
- So one-shot introduces no new `Corrupted` (`:1244-1250`) or `RBlocked` (`:951-953`, `:1158-1163`) states. The next normal build sees the world exactly as if the one-shot never ran: same `d.dat` and `buildID`, and the same artifacts, which still match their `locals` entries.
- Sources edited before or during the one-shot have a new mtime ≠ `locals.time`, so they are recompiled then.
- Residual: the crash window between `.ecot` and `.eci` exists in normal builds and is closed by S12c's reordering.

**Interface comparison:** covered in step 3 above. With no old `.eci`, every compiled module is `RNew`. That is correct. In a cold one-shot (the target case) everything is compiled anyway, so it is identical.

**Who should use it:**
- **Not the bootstrap stages (R4):**
  - 7a/8a decode Stage 5's `.ecot`;
  - 4b/8c compare warm runs;
  - fhr/mem-trace benchmarks measure the realistic cold build, writes included.
- **Candidates:**
  - `mlir_equivalence` and `aot_e2e`: they wipe their builddirs every run once the S12b pre-clean fix lands, so their caches are never reused;
  - ad-hoc CI/script invocations.
- E2E `ElmE2ETestBase` could pass it too (each re-run recompiles the changed single-module test anyway), but its modules are tiny, so there is no measurable gain.
- **Value:**
  - ≤ 3–6 s on a cold 9b after S3, which is the remaining `.ecot` encode. `computeVarSupers` still runs (R5).
  - Today, before S3, ≈20 s of the 40 s (the encoder share).

**Gates:**
- G1, G2.
- G6 extended: `incremental-cache-check.sh -n` runs a one-shot cold build after A. It checks that the one-shot MLIR equals A, that `eco-stuff` is byte-identical before and after (`find … -newer` is empty except the `build/` intermediate `.mlir`), and that the following warm build equals A.
- G4 is unaffected; run it anyway, since the compiler bytes change.

---

### 5.5 S5 — skip the erased optimizer on the typed path

**Today.**
- `Compiler/Compile.elm:224-247` `compileTyped` runs `optimize modul annotations canonical` (erased, `LocalOpt/Erased/Module.optimize`), then `typedOptimizeFromTyped`.
- The erased `Opt.LocalGraph` is stored in `TypedArtifactsData.objects` (field at Compile.elm:88).

**Who reads `objects` on the typed path** (`compileTyped` is called only when `needsTypedOpt` is set):

| consumer | reads | empty-tolerant? |
|---|---|---|
| `Build.handleTypedCompileResult` 1727 → `writeUntypedObjectsIfNeeded` 1572-1584 | skips the `.eco` write when `typedObjects = Just` | yes |
| `buildRSame`/`buildRNew` 1650/1666 → `addInside` 2553-2557 → `Fresh` | carried | yes |
| `Build.compileOutside` 2457 → `ROutsideOk` → `Outside`/`Fresh` (2592) | carried | yes |
| `Build.moduleEncoder`/`rootEncoder` 3058/3094 (MVar encoders) | encodes the graph | yes (cheaper) |
| `Generate.buildMonoGraph` 702-706 `stripUntypedGraph` 732-739 | discards it | yes (now a no-op) |
| `Generate.loadModuleObjects`/`lookupMain` 288-345 | JS backend only | n/a |
| **`Terminal/Make.elm` `getMain` 580, `isMain` 595, `getNoMain` 628** | `Opt.LocalGraph maybeMain` of `Fresh`/`Outside` | **NO**. `handleMlirOutput` (327) and `handleElfOutput` call `getNoMains` **before** Generate. An empty graph makes every root "no main", which fails with `MakeNonMainFilesIntoJavaScript` |
| `Details.handleTypedCompileResult` 1872 → `RLocal` | `gatherObjects` is only on the JS branch (1330); the typed branch already uses `Opt.empty` (1309-1312) | yes |
| `API/Make.elm` 144-170 | calls `Build.fromPaths ... False` (erased) | n/a |
| repl (`Build.elm:2102-2115`), tests | use `Compile.compile`. No test calls `compileTyped` | n/a |
| `--docs` | `makeDocs` uses `canonical` | n/a |

`shouldUseTypedOpt` (`Make.elm:242-252`) is True only for `MLIR`/`ELF` outputs. `Details.load` takes the same flag and regenerates when `hasTypedOpt` differs (`Details.elm:495`). A JS build never sees a typed module's objects: `.eco` is never written on the typed path, and Build's cached-artifact check requires `.eco` for JS (`Build.elm:884-894`). So `compileTyped` output never reaches the JS backend.

**Change.**

```elm
-- Compiler/AST/Optimized.elm: expose
emptyLocalGraph : LocalGraph
emptyLocalGraph =
    LocalGraph Nothing Data.Map.empty Dict.empty
-- and use it at Generate.elm:356 and 736 (optional tidy)

-- Compiler/Compile.elm:222-247  (after)
Ok () ->
    phase modName "typed-opt"
        |> Task.map
            (\_ ->
                typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots typedCanonical
                    |> Result.map
                        (\typedObjects ->
                            TypedArtifacts
                                { canonical = canonical
                                , annotations = annotations
                                -- S5: the erased graph is never read on the typed path
                                , objects = Opt.emptyLocalGraph
                                , typedObjects = typedObjects
                                , typeEnv = moduleTypeEnv
                                }
                        )
            )
```

Update the doc at Compile.elm:174-182 and at the `TypedArtifactsData.objects` field.

**Main detection (required, otherwise every MLIR/ELF build fails).** In `Terminal/Make.elm` add `import Compiler.AST.TypedOptimized as TOpt` and `import Compiler.Data.Name exposing (Name)`:

```elm
graphHasMain : Opt.LocalGraph -> Maybe (TOpt.LocalGraph Name) -> Bool
graphHasMain (Opt.LocalGraph maybeMain _ _) maybeTyped =
    case maybeTyped of
        Just (TOpt.LocalGraph data) -> Maybe.isJust data.main
        Nothing -> Maybe.isJust maybeMain

-- getMain 590:   Build.Outside name _ objs typed _ -> if graphHasMain objs typed then Just name else Nothing
-- isMain 598:    Build.Fresh name _ objs typed _ -> graphHasMain objs typed && name == targetName
-- getNoMain 638: Build.Outside name _ objs typed _ -> if graphHasMain objs typed then Nothing else Just name
```

This is equivalent to today:
- Both optimizers start from `main = Nothing` (Erased:76, Typed:95).
- Both set `Just` only in `addDefHelp`'s `addMain` (Erased:381-416 / Typed:470-497), under identical conditions: name = `main`, `deepDealias` to `VirtualDom.Node _` or `Platform.Program` with a payload that passes `Effects.checkPayload`.
- `NormalizeLambdaBoundaries.normalizeLocalGraph` (357) keeps `main`.
- `Cached` modules use `Details.Local.hasMain`, which is unchanged.

The alternative of a fake `Opt.Static` main in the stub works with zero Make.elm edits, but leaves a lying graph. It is rejected.

**Error parity.**
- The erased `optimize` can only fail via `ReportingResult.throw` at:
  - Erased:307 `BadCycle` (a `DeclareRec` containing `main`);
  - Erased:401/413/416 `BadType`;
  - Erased:410 `BadFlags`.
- The typed optimizer has the identical set at Typed:399/482/494/497 and 491.
- Both use the same `E = Compiler.Reporting.Error.Main` and `W`, and the same `Effects.checkPayload` and `Type.deepDealias`.
- Both run aliases → unions → effects → decls (no throws before decls).
- Both walk decls in the same order: `TCanBuild.toTypedDecls` (`TypedCanonical/Build.elm:64-79`) maps `Declare`/`DeclareRec` one to one.
- Both stop at the first throw (`ReportingResult.loop`).
- Compile.elm wraps both identically: `E.BadMains (Localizer.fromModule modul) errors` (604-608 vs 619-625). Warnings are discarded by `Tuple.second` in both.
- So the error text and order are unchanged.
- The only new exposure: on a module whose `main` is invalid, the typed optimizer now processes the decls before `main`. That is the same code that runs on every successful build.

**Byte identity.** The erased graph is never serialized on the typed path and never reaches mono. `.eci`, `.ecot` and MLIR are identical. GC behaviour changes, since less is allocated and fewer graphs are retained between Build and `stripUntypedGraph`.

**Tests and gates.**
- G1, G2 (any main-detection slip fails every E2E immediately), G3, G4, the §5.1 artifact identity check, G10. Measure the cold 9b phase time plus the major-GC count and peak RSS from `--stats`; expect −1 to −4 s.
- **Error parity check** (new, one-off; keep it in `benchmarks/incremental-cache-check.sh` or alongside it):
  - three tiny apps: `main = 5` (BadType), `main` in a `let`-free mutual-recursion group (BadCycle), and `Platform.worker` with a function-typed flags payload (BadFlags);
  - for each, `eco make --output=x.mlir` with the baseline and the new binary;
  - `diff` stderr and exit codes; they must be identical.

---

### 5.8 S8 — variableToCanType memo (experiment)

**Status: experiment, allocation-only.** It must not change any output byte. Run it only if a cheap A/B slot is free.

**Why sharing does not survive (R7, re-derived).**
- `Compile.elm:408-429` (`stampedNodeTypes`) runs `SolverRoots.stampArrowRoots` (`SolverRoots.elm:262-330`) over every node type with a var, via `Array.indexedMap`.
- Every structural arm (`TLambda`, `TType`, `TRecord`, `TTuple`, `TAlias Filled/Holey`) builds a new node unconditionally. That includes subtrees that contain no arrow.
- So a memo-shared DAG coming out of `toCanTypeBatch` is expanded back into a full tree one phase later.
- `PostSolve` is not the culprit. It replaces only Group-B entries (`arraySetJust`, `PostSolve.elm:1288`) and `applySubst` results (kernel inference). Most shared subtrees pass through it untouched.
- Downstream, `.ecot` collection and encoding walk the tree either way. S3 dedups by deep hash, not by identity.
- **Result:** the memo only saves the transient allocation and CPU of the conversion walk inside `toCanTypeBatch`. Those trees are nursery garbage once stamping has run.

**Possible follow-on (not part of this experiment): memoize `stampArrowRoots` too.**
- Within one batch, the stamped output is a pure function of `(rootIdx, node kind)`, because the memoized input `canType` for a given root is unique.
- Memoizing stamp by `(rootIdx, kind)` would carry sharing into `nodeTypes`, lowering retained heap until the module finishes.
- The `TAlias Filled` arm passes the same `var` to its body, so the key must include the kind, not just `rootIdx`.
- Only consider this if the S8 numbers justify it.

**Where the memo lives.**
- Add a field to `IO.NameState` (`System/TypeCheck/IO.elm:137`): `canMemo : CoreDict.Dict Int (Can.Type Name)`.
  - Initialize it in `emptyNameState` (`:149`) and in `Type.makeNameState` (`Type.elm:808-810`).
  - This needs `import Compiler.AST.Canonical as Can` in `IO.elm`. Checked: there is no import cycle; Canonical's transitive imports include neither `System.TypeCheck.IO` nor `Compiler.Type.Vars`.
- **Why `NameState` and not explicit threading:**
  - `withFreshNames` (`IO.elm:172-181`) already seeds and restores `names`. So the memo's lifetime is exactly one naming scope: one `toCanTypeBatch` call (`Type.elm:450-470`) or one `toAnnotation` call (`:426`).
  - That is precisely the scope in which a cached result is valid.
  - `State` keeps 4 fields, so solver-wide record-update copies don't grow.
  - Only conversion code touches `names`.
- **Key:** the union-find root index.
  - Use `UF.repr variable` (`UnionFind.elm:78`), then `Vars.Pt rootIdx` (`Vars.elm:48`, `type Point = Pt Int`).
  - Use `UF.get root` afterwards. `get` on a root is O(1); `UF.get` already calls `reprS`, so call `repr` once and pass the root.

**Name-generation safety.**
- `getFreshVarName` / `getFreshSuperName` write the new name back into the descriptor (`Type.elm:486-497`, `:505-513`).
- So after the first visit of a subtree, every flex var under it is named. A second conversion of the same root would call no fresh-name generator and return a structurally equal tree.
- The memo only skips such re-visits. First visits happen in the same order as today, so `NameState` evolves identically and the output is equal by construction.
- Validity needs no unification during the scope. That holds: the conversion only reads, plus the name write-back.
- **Do not memoize leaves.** `FlexVar`, `FlexSuper`, `RigidVar`, `RigidSuper`, `Unit1`, `EmptyRecord1` and `App1` with `[]` are O(1). A `Dict.insert` there would cost more than it saves.
- **Memoize** `Structure` with children (`App1` with args, `Fun1`/`FunL`, `Record1`, `Tuple1`) and `Alias`.

**Code sketch** (`Type.elm`):
```elm
variableToCanType : Variable -> IO (Can.Type Name)
variableToCanType variable =
    UF.repr variable
        |> IO.andThen
            (\root ->
                let (Vars.Pt rootIdx) = root in
                IO.getNames
                    |> IO.andThen
                        (\ns ->
                            case CoreDict.get rootIdx ns.canMemo of
                                Just t -> IO.pure t
                                Nothing -> variableToCanTypeMiss rootIdx root))

variableToCanTypeMiss : Int -> Variable -> IO (Can.Type Name)
variableToCanTypeMiss rootIdx root =
    UF.get root |> IO.andThen (\descProps ->
        case descProps.content of
            Structure term -> termToCanType term |> IO.andThen (memoize rootIdx term)
            Alias home name args real -> ...existing body... |> IO.andThen (remember rootIdx)
            _ -> ...existing leaf arms, unchanged (no insert)...)

remember : Int -> Can.Type Name -> IO (Can.Type Name)
remember rootIdx t =   -- re-read names: the subtree may have generated names
    IO.getNames |> IO.andThen (\ns ->
        IO.putNames { ns | canMemo = CoreDict.insert rootIdx t ns.canMemo } |> IO.map (\_ -> t))
-- memoize: remember only for App1 _ _ (_ :: _), Fun1, FunL, Record1, Tuple1
```
- In the leaf arms, `UF.modify variable` (the name write-back) must use `root`. That is equivalent, since `modify` resolves to the root.

**Experiment switch.**
- Env `ECO_CANTYPE_MEMO` (default off during the experiment).
- Read it in `Compile.elm` next to `stampGuardEnabled` (`:572`), so one binary serves both arms.
- Thread it as a `Bool` through `typeCheckTyped` → `Solve.runWithIds` (`Solve.elm:107-121`) → `Type.toCanTypeBatch`.
- When off, `remember` is skipped and lookups never hit, so behaviour is today's.
- **Hit census** (optional, same pattern as `emitStampGuard`, `Compile.elm:548`):
  - add `canMemoHits` / `canMemoMisses : Int` to `NameState`;
  - return them from `runWithIds`;
  - print `[canmemo] hits= misses= module=` to stderr only under `ECO_STAMP_GUARD_CENSUS`.

**Measurement.**
- Use the Stage 9 `eco` built with the change. Run `benchmarks/lss-loop-ab.sh` interleaved, 3 pairs. Arms: the same binary with `ECO_CANTYPE_MEMO=0` vs `=1` (wrap the binary in a 2-line env script per arm).
- (a) **Front-end allocation:** `[gc-stats]` "Bytes allocated" / "Objects allocated", minor GC count and minor GC time from each arm's stderr. These are exact per binary and tree; one pair suffices.
- (b) **Time:** G10 `--stats` "parse / check / build" wall, the "type check (constrain + solve)" bucket, and cold 9b wall. Take the median paired difference.
- (c) **Output equality (hard gate):** both arms' `out.mlir` and the whole `eco-stuff/0.1.x/*.ecot` tree are byte-identical (`cmp` / `diff -r`).
- **Upper-bound estimate:**
  - The encoded node types are 25.6 M nodes, against 151,830 per-file distinct nodes (with arrow slot).
  - So up to ~25 M conversions (~1 GB of nursery garbage plus 25 M `UF.get`s) can collapse. That is ≈ 8 % of the 13.2 GB run allocation.
  - By the "476 MB ≈ 0.62 s" rule (memory: lss-compile-opt-loop-complete) that is ≈ 1–2.5 s of allocation plus CPU.
  - Counter-cost: one `Dict.get` per visited node, plus one `Dict.insert` per miss on a structural node.

**Success criterion (all three):**
1. Bytes allocated fall by ≥ 0.5 GB.
2. The median paired parse/check/build wall falls by ≥ 1.0 s, which is beyond the 1.31 % noise floor.
3. Gate (c) holds.

If (1) holds but (2) does not, record the result as FLAT and do not ship. That is consistent with "judge on time, not allocation".

**Worth running?** Yes, as a cheap single-binary A/B (~60 lines of Elm, no format change), but it ranks below S1–S5. If it wins, the stamp memo above is the follow-on that turns the transient saving into a retained-heap saving.

**Tests if kept:**
- G1, plus a new elm-test `tests/Compiler/Type/CanMemoTest.elm`: for a module source with nested aliases (e.g. a `Task`/`IO`-style record alias used in 20 expressions), `toCanTypeBatch` with the memo on and off returns `==` arrays.
- G2, G4 (fixed points), and G5.

---

### 5.9 S9 — StringOps::compare hot/cold split

**Scope decision: change only `runtime/src/allocator/StringOps.hpp` / `StringOps.cpp`.**
- `UtilsExports.cpp` is LSS_022-pinned. `kernel-license-manifest.txt` has 8 `Utils.*` rows (`compare/equal/lt/le/gt/ge/notEqual/append`) on it, and 25 `Bytes.*` rows on `BytesExports.cpp`.
- The manifest deliberately does not pin `runtime/src/allocator/*` (`check-kernel-license-manifest.sh` scope note). So a `StringOps.hpp` change needs no re-audit.
- `eco_string_cmp3` (`UtilsExports.cpp:41-48`) includes `StringOps.hpp`. Once `compare`'s hot path is small, the compiler inlines it with no source change to the pinned file.
- **Drop the `BytesExports.cpp` part (`writeEncoder:195,208`):**
  - `perf script` attribution of the 9b profile shows zero `Allocator::resolve` samples under `writeEncoder`. The callers are `Terminal_Main_lambda_22247$cap`, `Array_set` and so on.
  - Touching the file costs a 25-row Bytes re-audit (G9).
  - Fold it into the next change that re-audits `BytesExports.cpp` anyway. Both sites already exclude embedded constants: the element is an Encoder `Custom`, and `ENC_UTF8` has `isEmptyString` checked first. So `resolveFast` is a drop-in there.

**Profile facts** (`stats-backend-opt/boot-1003-1354/9b-fp.data`, `perf annotate`):
- `StringOps::compare` is out-of-line. Its hot path is both-UTF-8 → `memcmp@plt` (offset `+0x475`).
- The prologue pushes 5 callee-saved registers plus `sub $0x58,%rsp`, because the vector lockstep path shares the frame.
- About 20 % of its self samples sit in that prologue and epilogue.
- In `eco_string_cmp3`, about 60 % of self samples are the two header loads (`and $0x1f` after `mov (%rsi)`), i.e. cache misses. The split cannot remove those.
- The `Allocator::resolve` calls inside `compare` are never sampled. Leaves need no resolve, and views are rare.
- Total string compare is ≈ 11–12 s of main-thread time (2.1 % of all cycles).

**Micro-benchmark** (`/tmp/claude-1000/lower/s9bench.cpp`; it emulates the current frame shape against the split; `g++ -O2`; binary search over UTF-8 leaves scattered in the heap, 20 M compares):

| keys | current | split | split + 8-byte prefix |
|---|---|---|---|
| 1,998 | 12.27 ns | 11.70 ns (−4.6 %) | 10.28 ns (−16 %) |
| 200 | 11.68 ns | 10.45 ns (−10.5 %) | 8.50 ns (−27 %) |

Estimated saving: 0.6–1.2 s cold 9b before S1/S3, ~half that after S1. With the prefix option, roughly double.

**Code shape** (`StringOps.hpp`, replacing `compare` at `:1544-1608`):
```cpp
// Cold: everything that needs singleSegmentView / collectSegs / std::vector.
// Defined in StringOps.cpp so its frame never merges into the hot path.
[[gnu::noinline, gnu::cold]] int compareSlow(void* a, void* b);

// Sign-only contract (all callers: eco_string_cmp3, Utils::cmp, tests use the sign).
inline int compare(void* a, void* b) {
    if (!a && !b) return 0;          // REP_CONSTANT_003: Empty handling unchanged
    if (!a) return -1;
    if (!b) return 1;
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);
    Tag ta = static_cast<Tag>(ha->tag), tb = static_cast<Tag>(hb->tag);
    bool u8a = (ta == Tag_StringUtf8Leaf) | (ta == Tag_StringUtf8View);
    bool u8b = (tb == Tag_StringUtf8Leaf) | (tb == Tag_StringUtf8View);
    if (__builtin_expect(u8a & u8b, 1)) {          // HEAP_032: all-ASCII ⇒ byte order == unit order
        const u8* pa; u32 la; const u8* pb; u32 lb;
        if (ta == Tag_StringUtf8Leaf) { pa = static_cast<ElmStringUtf8Leaf*>(a)->bytes; la = ha->size; }
        else { auto p = utf8Bytes(a); pa = p.first; la = p.second; }
        if (tb == Tag_StringUtf8Leaf) { pb = static_cast<ElmStringUtf8Leaf*>(b)->bytes; lb = hb->size; }
        else { auto p = utf8Bytes(b); pb = p.first; lb = p.second; }
        u32 m = la < lb ? la : lb;
#if ECO_STRCMP_PREFIX8 && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__   // optional S9b
        if (m >= 8) { u64 x, y; std::memcpy(&x, pa, 8); std::memcpy(&y, pb, 8);
                      if (x != y) return __builtin_bswap64(x) < __builtin_bswap64(y) ? -1 : 1; }
#endif
        int c = std::memcmp(pa, pb, m);
        return c != 0 ? c : static_cast<int>(la) - static_cast<int>(lb);
    }
    if (ta == Tag_String && tb == Tag_String) {    // UTF-16 leaves: existing loop, no vector
        const u16* pa = static_cast<ElmString*>(a)->chars;
        const u16* pb = static_cast<ElmString*>(b)->chars;
        u32 m = std::min(ha->size, hb->size);
        for (u32 i = 0; i < m; ++i)
            if (pa[i] != pb[i]) return static_cast<int>(pa[i]) - static_cast<int>(pb[i]);
        return static_cast<int>(ha->size) - static_cast<int>(hb->size);
    }
    return compareSlow(a, b);   // slices, large headers, ropes, UTF-8 vs UTF-16
}
```
- **`compareSlow` (`StringOps.cpp`):** the present single-segment-view and `collectSegs` lockstep code, verbatim.
- **`equal`** (`:1488-1532`) has the same vector-in-frame shape. Apply the identical split to it (`equalSlow`); it's cheap and in the same file.
- **`resolveFast` in `utf8Bytes` (`:88`, `:95`), `singleSegmentView` (`:625-636`) and `forEachSegmentEx` (`:288-359`):** swap `Allocator::instance().resolve(x)` / `allocator.resolve(x)` for `Allocator::resolveFast(x)`.

**`resolveFast` contract** (`Allocator.hpp:70-75`):
- The caller must have excluded embedded constants (`ptr_ind == 0`).
- It reinterprets the word as the address (HEAP_028), loads the header, and defers to the out-of-line `resolve()` loop only when the tag is `Tag_Forward`. Forwards are mutator-visible only during old-gen incremental compaction (HEAP_030 text).
- All the swapped fields are always heap pointers, never constants: view `base`, large-header `body`, slice `base`, rope `left`/`right`.
  - `append`/`makeUtf8View`/`slice` return `emptyString()` or the other operand instead of building nodes over Empty.
  - `StringOps.cpp` already calls `resolveFast` on the same fields 35 times.
- Permanent-space and rodata objects (HEAP_036, string literals) are never forwarded, so `resolveFast` returns them directly.
- **One difference:** `resolve()` carries `ECO_HEAP_VALIDATE` tripwires (stale-nursery and bounds asserts, `Allocator.cpp:1267-1287`) that `resolveFast` skips. That matches the 35 existing sites. Validate builds still catch stale pointers at every other `resolve`.
- The existing `if (!base)` checks stay as dead but harmless code.

**Invariants touched (no row text change):**
- **HEAP_025:** structure access stays inside `StringOps`.
- **HEAP_032:** the both-UTF-8 memcmp fast path relies on the all-ASCII invariant (already true today).
- **HEAP_028/HEAP_030:** `resolveFast` is the C++ twin of the inline forward check.
- **REP_CONSTANT_003:** Empty is still handled by the nullptr arms of `compare` and `eco_string_cmp3`.
- **gc-leaf:** `eco_string_cmp3` is declared gc-leaf (`EcoToLLVMRuntime.cpp:983-986`, CGEN_072 context). Both halves still never allocate on the GC heap. The cold half's only scratch is the C++-heap `std::vector`, and `resolve()` never allocates.
- **REP_LLVM_001/002:** untouched, since no codegen changes. This is the point of R8: no inline cmp3 in generated code.
- Stale comment, left alone: `UtilsExports.cpp:32-36` says "four paths". Do not edit it, because it is pinned.

**Unit tests** (`test/allocator/`, binary `build/test/test`, built by name: `cmake --build build --target test`, then `build/test/test --filter <pat>`):
- `Utf8StringTest.cpp`:
  - `test_binary_ops_cross_form` (`:177-226`) already checks `sign(compare)` over {u16 leaf, u8 leaf, u8 view}².
  - Add `test_compare_split_all_forms`, an RC property over ASCII and non-ASCII strings (including astral). Forms: {`Tag_String`, `Utf8Leaf`, `Utf8View`, `StringSlice`, rope mixing UTF-8 and UTF-16 children, `LargeStringHeader` (≥ 8 KiB), `Utf8View` over a `LargeByteHeader`}.
  - Assert `sign(compare(x,y)) == sign(u16string compare)` and `equal(x,y) == (x==y)` for all 7×7 pairs.
  - Pin prefix-equal cases (`"abc"` vs `"abcd"`, 8-byte common prefix of 7/8/9).
- `StringOpsTest.cpp:416/536` (slice and rope equality) are unchanged and must pass.
- If S9b (prefix) is enabled, add a property over lengths 0–24 that checks every byte position of the first difference.
- **Gates:** G1 (unit `test` binary), G2, G3, G4, G10.
- No G9: if `UtilsExports.cpp`/`BytesExports.cpp` are untouched, `kernel-license-check` must stay green with no `--update`.

---

### 5.10 S10 — .ecot-only varint ints and regions

**Today:**
- `Utils/Bytes/Encode.elm:51-53` `int = toFloat >> BE.float64` (8 B), and `Decode.elm:80-82` `int = float64 |> round`.
- `Annotation.regionEncoder` (`:201-226`) = 4 × `BE.int` = 32 B.
- Both are shared with `.eci`, `Optimized`, `Source`, error reports and so on (R12). They must not change.

**Measured on the current 275 `.ecot` (449.15 MB):**
- Instrumented decoder: `/tmp/claude-1000/lower/ecot_s10.py`. Analyses: `s10_measure.py`, `s10_table.py`.
- Results:

| field | count | today | after uLEB128 / scheme |
|---|---|---|---|
| regions | 330,269 | 10.57 MB | 4×uLEB 1.95 MB; **`row,col,Δrow,col` 1.64 MB (4.97 B/region)** |
| `type.fieldIndex` (in trees) | 12,290,263 | 98.3 MB | 12.3 MB (S3 table: 20,589 → 0.16 → 0.02 MB) |
| `type.arrowSlot` (in trees) | 247,571 | 1.98 MB | 0.56 MB (S3 table: 119,006 → 0.95 → 0.28 MB) |
| other TOpt/DT/TypeEnv ints | ~74k | 0.60 MB | 0.07 MB |
| Int literals (`expr` 3, `IsInt`) | 5,895 | 47 KB | keep float64 |

- **Negatives: none** in any field (regions, indices, literals).
- `endRow < startRow`: never. Region component maxima: rows 11,867, cols 1,957. `arrowSlot` max 1,302,037.
- All non-literal values are < 2^31.

**Format:**
- **`uintV` (unsigned LEB128, minimal).** 7 bits per byte, low group first, high bit = continuation, at most 5 bytes.
  - Precondition: `0 <= n < 2^31`. Indices, counts, arities, slots, rows and cols all satisfy it by construction.
  - Implement with `modBy 128` and `// 128`. On values < 2^31 these agree between JS (`//` is `|0`, 32-bit) and native 64-bit, so G7 holds.
- **`sintV` (zigzag + uLEB).** `z = if n >= 0 then 2*n else -2*n - 1`. Used only for the region's `Δrow` (insurance, since none is negative today).
- **Region:** `uintV startRow, uintV startCol, sintV (endRow - startRow), uintV endCol`.
- **Int literal sites keep `BE.int` (float64):**
  - `TypedOptimized.elm:836` `Int` and `Test.elm:157` `IsInt`.
  - Their values can be negative or ≥ 2^31: one is 407,199,254,740,991. That breaks JS `//`, and literal precision is a separate, pre-existing issue. 47 KB isn't worth the risk.

**New functions** (additions only; the shared ones are untouched):
```elm
-- Utils/Bytes/Encode.elm (expose uintV, sintV)
uintV : Int -> BE.Encoder
uintV n =
    if n < 0x80 then BE.unsignedInt8 n
    else if n < 0x4000 then BE.sequence [ BE.unsignedInt8 (0x80 + modBy 128 n), BE.unsignedInt8 (n // 128) ]
    else BE.sequence (uintVBytes n)
uintVBytes n = if n < 0x80 then [ BE.unsignedInt8 n ] else BE.unsignedInt8 (0x80 + modBy 128 n) :: uintVBytes (n // 128)
sintV n = uintV (if n >= 0 then 2 * n else -2 * n - 1)

-- Utils/Bytes/Decode.elm
uintV : BD.Decoder Int
uintV = BD.unsignedInt8 |> BD.andThen (\b0 -> if b0 < 0x80 then BD.succeed b0 else uintVMore (b0 - 0x80) 128 1)
uintVMore acc scale k =
    BD.unsignedInt8 |> BD.andThen (\b ->
        if b < 0x80 then BD.succeed (acc + b * scale)
        else if k >= 4 then BD.fail                       -- > 5 bytes: corrupt
        else uintVMore (acc + (b - 0x80) * scale) (scale * 128) (k + 1))
sintV = BD.map (\z -> if modBy 2 z == 0 then z // 2 else -(z + 1) // 2) uintV

-- Compiler/Reporting/Annotation.elm (expose regionEncoderV, regionDecoderV)
regionEncoderV (Region (Position r1 c1) (Position r2 c2)) =
    BE.sequence [ UBE.uintV r1, UBE.uintV c1, UBE.sintV (r2 - r1), UBE.uintV c2 ]
regionDecoderV = BD.map4 (\r1 c1 dr c2 -> Region (Position r1 c1) (Position (r1 + dr) c2)) UBD.uintV UBD.uintV UBD.sintV UBD.uintV

-- Compiler/Data/Index.elm: zeroBasedEncoderV / zeroBasedDecoderV (uintV); untyped Path.elm keeps zeroBasedEncoder
```
- For speed, the decoder's 1-byte case costs one `andThen`. It is no slower than today's `float64 |> round`.

**Every site to switch** (encoder and mirrored decoder in the same change):
- **`Compiler/AST/TypedOptimized.elm`, regions (22 encode sites):**
  - `nodeEncoderS` 653;
  - `exprEncoderS` 811, 819, 827, 835, 843, 858, 866, 874, 883, 891, 903, 911, 921, 948, 999, 1008, 1016, 1032, 1046;
  - `defEncoderS` 1271, 1280.
  - Decoders: 727, 1071-1247 (the matching `A.regionDecoder` arms), 1305, 1312.
- **`TypedOptimized.elm`, ints:**
  - `nodeEncoderS` 661 (Ctor index), 662 (arity), 669 (Enum index);
  - `exprEncoderS` 876 (VarEnum index), 992 (Case `jumps` key);
  - `choiceEncoderS` 1418 (Jump);
  - `pathEncoderS` 1485 (Index), 1493 (ArrayIndex);
  - plus the mirrored `BD.int` / `Index.zeroBasedDecoder` at 734, 1208, 1432, 1531 and the path decoders.
- **`Compiler/AST/DecisionTree/Test.elm` `testEncoderS`:** 140 (IsCtor index), 141 (numAlts), and their decoders (~191). 157 (`IsInt`) stays float64.
- **`Compiler/AST/DecisionTree/TypedPath.elm` `pathEncoderS`:** 107 and 357 (`Index.zeroBasedEncoder`), and decoders 132 and so on.
- **`Compiler/AST/Canonical.elm` S-encoders:**
  - `typeEncoderS` 685 (arrow slot) and `fieldTypeEncoderS` 784 (field index). These move into S3's type-table entry encoder; S3 must use `uintV` there.
  - `unionEncoderS` 850 (numAlts), `ctorEncoderS` 870-871 (index, numArgs). Used by `TypeEnv.moduleTypeEnvEncoder` / `globalTypeEnvEncoder`, i.e. the second half of `.ecot` and `typed-artifacts.dat`.
- **Not switched:**
  - `signedInt32` at 1292 / 1586 (scheme-roots `Vars.Pt`, 57 KB total);
  - `UBE.list` u32 length prefixes (`listhdr` 0.54 MB; an optional `listV` is a later S10b);
  - every non-`S` encoder (`.eci`, `Optimized`, `Source`, `Path.elm`).
- All S-encoder users are the typed-artifact family: `.ecot`, `typed-artifacts.dat`, `to.dat` (R14). They are covered together by the version bump.

**Interaction with S3: bundle into the S3 v2 change set (recommended).**
- A separate later S10 is a format break of its own. Per R9 it needs `typedGraphFormatVersion` 2→3 **and** `V.compiler` 0.1.2→0.1.3, plus the four hard-coded paths (`fhr-matrix.sh:18`, `l3-corunner.sh:24`, `fhr-gc-points-runs.sh:6`, `ecot.py`), and a full G7/G8 cycle again.
- S10 is ~120 lines of Elm. It touches the same encoders and decoders S3 rewrites, and S3's type table should use `uintV` for slot and field index from day one.
- If S3 must land first, do S10 as the v3 bump above. Do not let S10 hold up S3.
- In both cases update `ecot.py`: `region()` reads 4 varints, and the f64 int sites become uLEB. The `s10` copies in `/tmp/claude-1000/lower/` show the tagged sites.

**Bytes saved:**
- **Post-S3 (~17 MB).** What remains: regions 10.57 + string tables 1.27 + other TOpt structure ~3.1 + type table ~1.2 + type refs ~1 MB.
- S10 saves regions −8.93 MB, non-type ints −0.53 MB, and table ints −0.81 MB if S3 would otherwise store them as f64. **≈ −10.3 MB, leaving ~7 MB (−60 %).**
- **Pre-S3,** for reference: about −97 MB (449 → ~352 MB), mostly `fieldIndex` inside trees.
- Warm-decode time gain is marginal after S3, which is dominated by object construction.

**Tests (part of §5.3.8 codec tests, `compiler/tests/Compiler/AST/VarintCodecTest.elm`):**
- `uintV` round-trip fuzz on `[0, 2^31)` plus boundaries 0, 127, 128, 16383, 16384, 2^21−1, 2^21, 2^28, 2^31−1.
- Encoded length equals the minimal LEB length.
- `sintV` round-trip on ±2^30.
- `regionDecoderV (regionEncoderV r) == r` fuzz.
- A 6-byte overlong input fails.
- A v2 `localGraph` round-trip on a fixture module.
- **Gates:** G1, G2, G3, G4, G5, G6, **G7** (JS == native bytes; this exercises the `//`/`modBy` parity), **G8** (stale v1 → recompile), G10 (warm 9b).

---

### 5.11 S11 — read-path fixes

**(a) `StringTable.tableDecoder` builds an unused `strToIdx`** (`Compiler/AST/StringTable.elm:228-255`).
- `strToIdx` is read only by `StringTable.string` (`:143-171`, the encoder).
- The four decode users never pass their decoded table to an encoder; it is used only by `*DecoderS` / `stringDec`. They are `TypeEnv.moduleTypeEnvDecoder:174`, `TypeEnv.globalTypeEnvDecoder:208`, `TOpt.globalGraphDecoder:540` and `TOpt.localGraphDecoder:588`.
- No other module, test or `src-xhr` twin references `strToIdx`.
- Elm is strict, so "lazy" means "don't build it":
```elm
-- tableDecoder, inside BD.map:
(\strs -> { strToIdx = Dict.empty, idxToStr = Array.fromList strs, width = width })
```
- Document on `tableDecoder`: "A decoded table is DECODE-ONLY: `string` on it would emit index 0 for every string." The cleaner option is to split the type (`DecodeTable = { idxToStr, width }`), but that touches every `*DecoderS` signature. Defer it to S3, which rewrites those decoders anyway.
- **Saving (warm):** ~550k+ sorted-key `Dict.insert`s, each a string compare per level plus path copy ≈ 0.2–0.5 s and roughly 0.3 GB of allocation across 275 files × 2 tables, plus `typed-artifacts.dat`.
- No format change and no twins.
- **Tests:** `compiler/tests/Compiler/AST/StringTableTest.elm`, which checks `tableDecoder (tableEncoder (build s))` gives the same `idxToStr`/`width`, and `stringDec` round-trips for widths 1, 2 and 4 (sizes 3, 300, 70,000).
- **Gates:** G1, G2, G4 (8c decodes), G5.

**(b) `File.readBytesBody` copies through a `std::vector`** (`eco-kernel-cpp/src/eco/File.cpp:132-150`).
- Today it zero-fills a vector of `size`, reads into it, then `allocByteBuffer` copies again: 2× peak memory and memset plus memcpy.
- Latent bugs: `tellg() == -1` is unchecked (a huge vector), and a short read silently returns a zero-padded buffer.
- New body, modelled on `readStringBody` (`:79-130`):
```cpp
HPointer readBytesBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readBytes start path=%s", pathStr.c_str());
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) { int err = errno; ECO_KLOG(...fail...); return failErrno(err, pathStr, "could not open file for reading"); }
    std::streamoff sz = file.tellg();
    if (sz < 0) { int err = errno; return failErrno(err ? err : EIO, pathStr, "could not size file for reading"); }
    if (static_cast<uint64_t>(sz) > UINT32_MAX)      // ByteBuffer header.size is u32
        return failErrno(EFBIG, pathStr, "file too large for Bytes");
    size_t size = static_cast<size_t>(sz);
    if (size == 0) return succeed(Elm::alloc::emptyBytes());       // HEAP_071 constant, as today
    file.seekg(0, std::ios::beg);
    // Allocate FIRST, then read into the payload. Nothing allocates on the Elm heap
    // between here and succeed(): bb.bytes stays valid (BlankByteBuffer contract) and
    // bufHp is not stale when succeed() roots it.
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(size);
    HPointer bufHp = bb.hp;
    file.read(reinterpret_cast<char*>(bb.bytes), static_cast<std::streamsize>(size));
    if (!file || static_cast<size_t>(file.gcount()) != size) {
        int err = errno;
        ECO_KLOG("file", "readBytes short-read path=%s errno=%d", pathStr.c_str(), err);
        return failErrno(err ? err : EIO, pathStr, "could not read file contents");
    }
    ECO_KLOG("file", "readBytes done path=%s size=%zu", pathStr.c_str(), size);
    return succeed(bufHp);
}
```
- **GC safety:**
  - At or above LOT (8 KiB; every real `.ecot`), `allocByteBufferBlank` → `allocLargeByteBuffer(nullptr, n)`. That gives a nursery `Tag_LargeByteHeader` plus a body pinned in old gen (HEAP_026), and the body never moves.
  - Below LOT, the buffer is a nursery `ByteBuffer`. Its `bytes` pointer is valid until the next allocation, and none happens before `succeed`.
  - The blocking `read(2)` cannot race a GC:
    - only one mutator is allowed (HEAP_007 / CR-012);
    - minor and compaction work runs inside the mutator's allocation pauses;
    - concurrent and parallel mark helpers (HEAP_063) never move objects, and the body is pointer-free anyway.
  - `succeed(bufHp)` → `Scheduler::taskSucceed` roots its argument across the Task allocation. That is the same pattern as today's `succeed(allocByteBuffer(...))` and `readStringBody`'s `succeed(makeUtf8View(...))`.
  - **Error paths:** after a failed read, the buffer is unreachable garbage. `failErrno` allocates, which is fine because `bb`/`bufHp` aren't used afterwards. The large body is reclaimed at the next minor GC whose evacuation doesn't see the header (HEAP_026).
- **Behaviour change** (intended, C++ only): a short read or truncated file is now `Err IOError` instead of a zero-padded `Bytes`. The JS and xhr twins (`Eco/Kernel/File.js`, `src-xhr/Eco/File.elm:95`) are unaffected; the type is unchanged.
- **Saving:** one memset plus one memcpy plus a transient malloc per file. ≈ 0.1–0.2 s warm on 449 MB today, negligible after S3. Peak RSS falls by the largest file (~70 MB).
- **License (G9):**
  - `File.cpp` is pinned for all 23 `File.*` rows, so the hash changes and `kernel-license-check` fails as designed.
  - **Re-audit:**
    - `File.readBytes` stays `class: vacuous` (`String -> Task IOError Bytes`, no function-capable position). B2 (String captured by the binding wrapper) and B3 are unchanged.
    - Every `File.*` row's evidence cites `File.cpp` line numbers ≥ 600 (e.g. `readBytes:614-617`). Those shift by the inserted lines, so update all 23 evidence strings in `KernelSetFacts.elm:1251-1425` and advance their `audited:` date.
    - Then run `test/scripts/check-kernel-license-manifest.sh /work --update`.
  - Never just regenerate the hashes.
- **Tests:** new E2E `test/eco-kernel/src/FileReadBytesRoundtripTest.elm` (`-- CHECK: ... True`), Task-driven like the `MVar*` tests:
  - `writeBytes` then `readBytes` round-trip for sizes 0, 1, 31, 8,191 (sub-LOT), 8,192 and 8,200 (LOT edge), and 1 MiB, with byte-for-byte equality;
  - `readBytes` of a missing file gives `Err`;
  - run once under `benchmarks/heap-config-gc-pressure.json` so GCs land between the read and later allocations.
- **Gates:** G2, G3, G4, G5, G6, **G9**.

**(c) `makeUtf8LeafFromBytes` snapshots through a `std::vector`** (`runtime/src/allocator/StringOps.cpp:127-164`, the snapshot at `:156`).
- **Why the snapshot exists:** `bytes` may point into a movable heap object, and `eco_alloc_with_roots` may run a minor GC (or a compaction step) that relocates it. The in-heap callers are `read_string`'s short path (`BytesExports.cpp:630`, len < `utf8_view_min_len` = 32) and `slice`'s tiny path (`StringOps.cpp:334`, len ≤ `string_tiny_slice_limit` = 128).
- **Most calls don't need it:**
  - `fromInt`, `fromFloat` and `fromChar` (`StringOps.hpp:1185-1229`) and `tinyFromU16` (`StringOps.cpp:294-305`) pass C-stack buffers or rodata.
  - `tryMakeAsciiString` passes `std::string` C-heap data.
  - Today each of these pays a malloc/free.
- Change:
```cpp
    const u8* src = bytes;
    u8 small[256];
    std::vector<u8> big;
    if (allocator.isInHeap(const_cast<u8*>(bytes))) {      // movable: snapshot first
        if (len <= sizeof(small)) { std::memcpy(small, bytes, len); src = small; }
        else { big.assign(bytes, bytes + len); src = big.data(); }  // len < LOT here
    }
    void* obj = eco_alloc_with_roots(Tag_StringUtf8Leaf, total_size, nullptr, 0, 0);
    ... std::memcpy(leaf->bytes, src, len);
```
- `isInHeap` is the O(1) bounds check on the unified heap (`Allocator.hpp:265`). Permanent space (HEAP_036) and rodata lie outside it and never move.
- Apply the same `small`/`big` treatment to the two widen arms (`:139`, `:150`) only if they ever show in a profile. They are rare (UTF-8 disabled, or ≥ LOT).
- **Saving:** ~15–25 ns per call on every `String.fromInt`/`fromChar`/tiny slice. Cold 9b shows `makeUtf8LeafFromBytes` < 0.01 % self, so this is a small general win, mostly on warm decode of short table strings.
- No invariant text change: HEAP_032's creation sites are unchanged.
- **Tests:**
  - existing `Utf8StringTest` `test_seed_constructors` and `test_utf8_survives_gc`;
  - new `test_leaf_from_heap_bytes_under_gc`: a source `ByteBuffer` in the nursery, `ECO_GC_*` set so the leaf allocation triggers a minor GC, then assert content equality, for lengths 1, 31, 128, 256, 257.
- **Gates:** G1 (unit), G2, G4.

### 5.12a S12a — version bump

**Must change (same change set as S3).**

| file:line | change |
|---|---|
| `compiler/src/Compiler/Elm/Version.elm:179` | `Version 0 1 1` → `Version 0 1 2`. Extend the comment at 168-178: "BUMPED 0.1.1 -> 0.1.2 on <date> for `.ecot` v2 type table (plans/cache-serialization-optimization.md S3) — package `typed-artifacts.dat` decode failure is silent (`Details.elm:353-354` → empty graph), so only a cache-key bump invalidates it." |
| `compiler/src/Compiler/AST/TypedOptimized.elm:1559-1561` | `typedGraphFormatVersion = 1` → `2`. The doc at 1553-1557 already says "bump on any layout change" |
| `benchmarks/fhr-gc-points-runs.sh:6`, `benchmarks/l3-corunner.sh:24` | `REG=~/.eco/0.1.1/packages/registry.dat` → glob: `for REG in "${ECO_HOME:-$HOME/.eco}"/*/packages/registry.dat; do touch "$REG"; done` (the `heap-profile.py:1309` pattern). A literal would silently stop freezing the registry TTL and bring back the 134 s POST |
| `benchmarks/fhr-matrix.sh:18` | `touch ~/.eco/0.1.1/packages/registry.dat` → same glob |
| `/tmp/claude-1000/agentA/ecot.py:193` | `assert v==1` → `v==2`, plus the S3 type-table decoder. Note on R9: it has **no** `0.1.1` path; it takes the `.ecot` directory as `argv[1]` |

**No change (checked).**
- `version.txt` (`0.1.1`), the checked-in `Compiler/Elm/Version_Build.elm:25`, `compiler/cmake/Version_Build.elm.in` (`@ECO_VERSION_USER_FACING@`, generated by `compiler/CMakeLists.txt:102-103`), `docs/options.md:62` and `benchmarks/frontendstats.txt`:
  - these are the *user-facing* `eco --version`/HTTP user-agent string (`Builder/Http.elm:186`), not the cache key. They equal 0.1.1 only by coincidence; do not bump them.
  - After S12a, `eco --version` prints 0.1.1 while caches live in `0.1.2/`. Expected; say so in the commit message.
- `heap-profile.py:1281`: a docstring; the code globs (`1309`).
- `benchmarks/fe-opt-loop.md:246`, `benchmarks/gc-opt-loop.md:246`: historical logs. Update only if the recipe is reused.
- `test/aot_e2e_main.cpp:116,619` and `test/mlir_equivalence_main.cpp:469,496`: comments, already stale (`1.0.0`). The code wipes or uses `eco-stuff/` wholesale.
- CMake: the Stage 5 `.ecot` purge (`compiler/CMakeLists.txt:385-412`) is a recursive `*.ecot` under `build-kernel/eco-stuff`, and `clean` removes all of `eco-stuff` (1062-1073). Both are version-agnostic.
- `compiler/elm.json` `"elm-version": "0.19.1"` is `V.elmCompiler`. `eco-kernel-cpp/elm.json` `"version": "1.0.0"` is the package version. Neither is `V.compiler`.
- No checked-in JS bootstrap artifact contains `V.compiler`: `compiler/bin/*.js` are runners, Stage 1 compiles from source, and `dist/` holds 0.1.0-alpha release archives.

**Where the version lives.** `V.compiler` is read once: `Builder/Stuff.elm:126-128` `compilerVersion`. It keys:
- `<root>/eco-stuff/<ver>/` (`Stuff.elm:76`): `.eci`, `.eco`, `.ecot`, `d.dat`;
- `${ECO_HOME:-~/.eco}/<ver>/<name>` (`getCacheDir`, 396-404): `packages/` (sources, `registry.dat`, `artifacts.dat`, `typed-artifacts.dat`) and `repl/`.

There are no registry URLs keyed by it.

**Effect on existing caches.**
- `~/.eco/0.1.1` and every `eco-stuff/0.1.1` are simply ignored, and nothing reads them again.
- No code migration is needed.
- One-time cost: an empty `~/.eco/0.1.2/packages` means a registry fetch plus **re-download of every package source** on the first build (network), then a full package rebuild.

Recommended operator steps (document in the commit; not code):
1. Offline or slow-network seed, skipping the format-bearing caches:
   ```
   rsync -a --exclude artifacts.dat --exclude typed-artifacts.dat \
         --exclude '*.stale-*' --exclude '*.bak-*' ~/.eco/0.1.1/ ~/.eco/0.1.2/
   ```
   `registry.dat` and the sources are format-independent.
2. Disk cleanup: `rm -rf ~/.eco/0.1.1` (15 MB here) and `find build test -type d -path '*/eco-stuff/0.1.1' -prune -exec rm -rf {} +`. Each self-compile tree holds about 449 MB of v1 `.ecot`.
3. The `local-dev/dev.sh` home volume (`eco-dev-home`) and CI caches need the same seeding or a re-download.

**Ordering rule.** The bump MUST land in the same commit as the S3 format change. If any build with `V.compiler = 0.1.2` and format v1 runs (e.g. S12a merged ahead of S3), v1 package `typed-artifacts.dat` files land under `0.1.2/` and are later decoded silently as empty graphs. In that case, wipe `~/.eco/0.1.2` and `eco-stuff/0.1.2`.

**Tests and gates.**
- G1, G2, G3, G4.
- G8: put a v1 tree in place (`eco-stuff/0.1.1` plus `~/.eco/0.1.1` from a baseline build); the new compiler must build cold with no `GenerateCannotLoadArtifacts` and no "Corrupt File".
- Plus the negative control: copy a v1 `.ecot` into `eco-stuff/0.1.2/` and confirm that `formatVersionDecoder` (TO:1567-1577) rejects it with a decode failure, not a misparse.
- G5, G6.

---

### 5.12b S12b — `--builddir` path mismatch

**Defect (confirmed by reading the code).** Build reads and writes the per-module artifacts at `eco-stuff/<ver>/X.{eci,eco,ecot}`. `d.dat`, `i.dat`, `o.dat`, Generate's loads, and the intermediate `.mlir` all go to `eco-stuff/<ver>/<bd>/…`.

| Side | Site | Path today |
|---|---|---|
| Build | `Build.elm:889` `handleCachedDepsStatus` (artifact-exists check) | `Stuff.ecot root name` |
| Build | `Build.elm:892` (same check, untyped path) | `Stuff.eco root name` |
| Build | `Build.elm:1244` `loadInterface` (read the `.eci` of a cached dep) | `Stuff.eci root name` |
| Build | `Build.elm:1584` `writeUntypedObjectsIfNeeded` | `Stuff.eco ctx.root ctx.name` |
| Build | `Build.elm:1598` `writeTypedObjectsIfNeeded` | `Stuff.ecot ctx.root ctx.name` |
| Build | `Build.elm:1609` `checkInterfaceAndFinalize` (read old `.eci`, write new) | `Stuff.eci ctx.root ctx.name` |
| Generate | `Generate.elm:368` (`.eco`), `:496` (`.eci`), `:656` (`.ecot`, `streamLoadAndMergeCached`) | `*WithBuildDir root maybeBuildDir` |
| Details | `d.dat` / `i.dat` / `o.dat` (`Details.elm:469,861-863`, `Build.elm:1755`) | `*WithBuildDir` |

**Live consequence:** run a second build in the same `--builddir` where some local module is cached:
1. Build's existence check finds `eco-stuff/<ver>/X.ecot` and returns `RCached`.
2. Generate then reads `eco-stuff/<ver>/<bd>/X.ecot`, which is absent.
3. The build fails with `Exit.GenerateCannotLoadArtifacts` (`Generate.elm:660`). The user sees the **"CORRUPT CACHE"** banner.

**Reproduced on 2026-10-03** with the G6 script below (`synth` project, current Stage 9 `eco`):
- mode `root` passes every step;
- mode `builddir` passes the cold build A;
- every later build in that builddir (A0 and each `B-*`) fails with rc=1 and "CORRUPT CACHE".

This is very likely the "AOT CORRUPT CACHE on every re-run" in memory: the dead pre-clean (below) leaves the builddirs in place.

This bites on E2E re-runs of a test that imports a helper module. There are 5 such helpers:
- `stress-elm`: `Gen`, `StressHarness`, `Xorshift32`;
- `eco-kernel` and `elm-http`: `TestServerConfig`.

In addition, parallel E2E/AOT compiles race on the shared root-level `.eci`/`.ecot`, outside their per-builddir lock (`Stuff.withRootLockBuildDir`). That is R10.

**Where `maybeBuildDir` lives.** It is already a field of `EnvData` (`Build.elm:101`), set by `makeEnv` (`:126`, `:150`). Every Build function that touches an artifact either holds `Env` or has a `maybeBuildDir` parameter. Nothing new is needed in `Details`.

**Change: thread a `Maybe String` next to every `root` used to build an artifact path.**

1. `CompileResultContext` (`Build.elm:1480`): add the field `maybeBuildDir : Maybe String` after `root`.
2. Change these four signatures to take `-> Maybe String` right after the `FilePath` root, and set `maybeBuildDir = maybeBuildDir` in the two ctx literals (`:1548`, `:1718`):
   - `compileWithoutTypedOpt` (`:1498/1513`);
   - `handleCompileResult` (`:1518/1534`);
   - `compileWithTypedOpt` (`:1669/1684`);
   - `handleTypedCompileResult` (`:1689/1704`).
3. In `compile` (`:1472`, `:1475`), pass `envData.maybeBuildDir` after `envData.root`.
4. Artifact paths:
   ```elm
   -- :1584
   File.writeBinary Opt.localGraphEncoder (Stuff.ecoWithBuildDir ctx.root ctx.maybeBuildDir ctx.name) ctx.objects
   -- :1598
   File.writeBinary TMod.typedModuleArtifactEncoder (Stuff.ecotWithBuildDir ctx.root ctx.maybeBuildDir ctx.name) artifact
   -- :1609
   eciPath = Stuff.eciWithBuildDir ctx.root ctx.maybeBuildDir ctx.name
   -- :889 / :892 (handleCachedDepsStatus already binds envData)
   Stuff.ecotWithBuildDir root envData.maybeBuildDir name
   Stuff.ecoWithBuildDir root envData.maybeBuildDir name
   ```
5. Interface loading:
   ```elm
   loadInterfaces : FilePath -> Maybe String -> List Dep -> List CDep -> Task Never (Maybe (Dict ModuleName.Raw I.Interface))
   loadInterface  : FilePath -> Maybe String -> CDep -> Task Never (Maybe Dep)
   -- :1244
   File.readBinary I.interfaceDecoder (Stuff.eciWithBuildDir root maybeBuildDir name)
   ```
   Call sites:

   | Line | Function | New call |
   |---|---|---|
   | 936 | `handleCachedWithArtifactCheck` (has `env`) | destructure `(Env envData)`, then `loadInterfaces root envData.maybeBuildDir same cached` |
   | 1030 | `handleChangedDepsStatus` | same as 936 |
   | 1158 | `checkDepsHelp` | `loadInterfaces root maybeBuildDir same cached` |
   | 2132 | REPL | `loadInterfaces envData.root envData.maybeBuildDir …` |
   | 2418 | `checkRoot` | `loadInterfaces envData.root envData.maybeBuildDir …` |
6. `checkDeps` and `checkDepsHelp`:
   - New signatures:
     ```elm
     checkDeps : FilePath -> Maybe String -> ResultDict -> List ModuleName.Raw -> Details.BuildID -> Task Never DepsStatus
     checkDepsHelp : FilePath -> Maybe String -> ResultDict -> …   -- pass-through in all 11 recursive calls, :1118-1142
     ```
   - Callers:
     - `:859` `checkCachedModule` and `:1008` `checkChangedModule`: both hold `env`, so bind `(Env envData)`.
     - `:2087` `compileReplModules`: has `maybeBuildDir` in scope.
     - `:2410` `checkRoot`: `envData.maybeBuildDir`.
7. **Make the bug unrepresentable.** Delete `Stuff.eci`, `Stuff.eco`, `Stuff.ecot` and `toArtifactPath` (`Stuff.elm:6,36,135-158`). After step 4 they have no callers; `grep` confirms they are used only at the 6 sites above. Any future root-only use then fails to compile.

**The dead `to.dat` read (R14): remove it in S12b.** `typedObjectsWithBuildDir` is read at `Details.elm:311` and never written. No `to.dat` exists anywhere under `/work/build` or `/work/test` (checked). Today a missing file → `Nothing` → `combineTypedArtifacts Nothing pkgs = Just pkgs`. Removing the read is behavior-identical, and removes one stale-file hazard.

```elm
loadAllTypedObjects : Dict Pkg.Name V.Version -> Stuff.PackageCache -> Task Never (Maybe PackageTypedArtifacts)
loadAllTypedObjects deps cache =
    loadPackageTypedArtifacts cache deps |> Task.map Just
```
- Drop `root` and `maybeBuildDir` from `Details.loadTypedObjects` (`:298`). Its only caller is `Generate.elm:514`; `Generate.loadTypedObjects` keeps its own parameters, which it still needs for `.ecot`.
- Delete `combineTypedArtifacts` (`:359-370`) and `Stuff.typedObjectsWithBuildDir` (+ export/docs).
- Fix the comment at `Details.elm:496` ("o.dat/to.dat" → "o.dat").

**Effect on the harnesses.**

Counts are from the current `build/test`. E2E builddirs:

| Suite | Builddirs |
|---|---|
| elm | 633 |
| stress | 101 |
| elm-core | 104 |
| elm-bytes | 90 |
| elm-parser | 37 |
| elm-json | 31 |
| elm-http | 22 |
| eco-kernel | 14 |
| other | 11 |
| **Total** | **≈1,043** |

AOT has ≈902.

- **Disk.** Each builddir already holds `d.dat` and `i.dat`, ~135 KB each, about 270 MB per tree. This is unchanged.
  - The moved `.eci` + `.ecot` total 5.6 MB for E2E and 3.8 MB for AOT. They move one-for-one, except that the 5 helpers get one copy per importing test: 32 importers of `Gen` and about 100 of `StressHarness`. That adds ≲1 MB.
  - Net: under +1 %.
- **Time.** No change on cold runs:
  - A fresh builddir has empty `locals`, so every local module is compiled anyway.
  - The serial warm-up (`ElmE2ETestBase.hpp:555-567`, `aot_e2e_main.cpp:617-631`, `mlir_equivalence_main.cpp:494-510`) primes only what lies outside the builddir: `~/.eco/<ver>/packages` (`elm/core` etc. and the local `eco/kernel` typed artifacts). Keep the warm-up. Its comments are wrong after S12b ("shared `.eci/.ecot`"); reword them to "primes the shared `~/.eco` package caches".
  - Re-runs (`needsRecompile`: `.elm` newer than `.mlir`) recompile the changed test module. Helpers now come from the test's private cache, which fixes the `GenerateCannotLoadArtifacts` failure above. No time change.
- **ElmE2ETestBase.hpp (481-600): no change needed.** It keeps `--builddir=<stem>`. Do not drop `--builddir`: that would put back one shared `d.dat` racing across ≤N parallel compiles.
- **`aot_e2e_main.cpp:597-616` and `mlir_equivalence_main.cpp:469-490` must change.** Their pre-clean is dead code:
  - It removes `eco-stuff/1.0.0` and `eco-stuff/aot_e2e_*` / `eco-stuff/mlir_eq_*`.
  - The real layout is `eco-stuff/0.1.1/aot_e2e_<stem>/`: 596 such dirs survive in `build/test/aot-e2e/elm/eco-stuff/0.1.1/`.
  - This is the "AOT CORRUPT CACHE on every re-run" memory note.
  - Replacement:
    ```cpp
    // remove every version dir (anything but the harness's own "mlir" output dir):
    for (auto& ent : fs::directory_iterator(eco_stuff, ec))
        if (ent.is_directory() && ent.path().filename() != "mlir") fs::remove_all(ent.path(), ec);
    ```
    That matches the original "wipe 1.0.0" intent and survives the S12a bump to 0.1.2. Update the comments at `aot_e2e_main.cpp:116,360,598,619` and `mlir_equivalence_main.cpp:257-260,469-497`: the builddir is `eco-stuff/<ver>/<name>/`.
  - In `mlir_equivalence`, the `_s2` and `_s6` builddirs stop sharing `.eci`/`.ecot` across the JS and native compilers, which is what its line-8 comment already claims.
- `Terminal/Main.elm:281` help text says "eco-stuff/1.0.0/"; change it to "eco-stuff/<version>/".

**Gates:**
- G1 (elm-tests).
- G2 `full`: E2E uses guida with `--builddir`, so this exercises the change.
- G3: AOT with the fixed pre-clean (still move `eco-stuff` aside once for the first run), plus `mlir_equivalence`.
- G4: bootstrap. It never passes `--builddir`, so the paths are byte-identical; the compiler bytes change, so 4b/8c must hold.
- G6: the builddir mode of `incremental-cache-check.sh` fails before S12b at its step A0. That is the regression test.

**Risks:**
- A one-time cold rebuild of every existing builddir. The old root-level files are orphaned (harmless garbage until S12a's version bump or a wipe).
- Users who pass `--builddir` to share root caches deliberately lose that sharing. That sharing was the bug.

---

### 5.12c S12c — atomic artifact writes

**Today:** `Utils.binaryEncodeFile` (`Utils/Main.elm:1284`) → `Eco.File.writeBytes`:
- C++: `writeBytesBody`, `File.cpp:486-511`. It uses `std::ofstream` (truncate in place) and does not check write or close errors, so ENOSPC is silent.
- JS: `fs.writeFileSync`.
- xhr: `fs.writeFileSync` in `eco-io-handler.js:699`.

A reader in another process, or a crash mid-write, sees a truncated file. Under parallel E2E this produces the "Corrupt File" banner, or `GenerateCannotLoadArtifacts` for `.ecot`.

**Design.** Add one new kernel, `Eco.File.writeBytesAtomic : String -> Bytes -> Task IOError ()`, which does temp file + rename internally. Prefer this over a bare `rename` kernel:
- Elm cannot mint a per-process-unique name without a pid kernel.
- One call keeps cleanup in a single place.

Do not change `writeBytes` itself. Its other users write user-visible outputs (e.g. `Backend.elm:473` bytecode, possibly `/dev/stdout` or symlinks), where rename semantics would be wrong: they replace a symlink and drop the file mode.

**C++ (`eco-kernel-cpp/src/eco/File.cpp`)**, new body placed after `writeBytesBody`:
```cpp
#if defined(_WIN32)
#include <process.h>   // _getpid  (add to the _WIN32 include block)
#define ECO_GETPID _getpid
#else
#define ECO_GETPID getpid
#endif
std::atomic<uint64_t> gAtomicWriteSeq{0};   // anonymous namespace; plain integer, no heap value

HPointer writeBytesAtomicBody(HPointer captured) {
    HPointer pathHP, bytesHP;
    { Tuple2* tup = asTuple2(captured); pathHP = tup->a.p; bytesHP = tup->b.p; }
    std::string pathStr = toString(Export::encode(pathHP));
    std::string tmp;
    int fd = -1;
    for (int tries = 0; fd < 0 && tries < 16; ++tries) {           // O_EXCL: never share a temp
        tmp = pathStr + ".tmp-" + std::to_string((long long)ECO_GETPID()) + "-"
              + std::to_string(gAtomicWriteSeq.fetch_add(1, std::memory_order_relaxed));
        fd = _eco_open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_TRUNC, 0644);
        if (fd < 0 && errno != EEXIST) break;
    }
    if (fd < 0) { int err = errno; return failErrno(err, pathStr, "could not create temp file for writing"); }
    // NO Elm allocation between resolve and the last write (same rule as writeBytesBody).
    void* ptr = Elm::Allocator::instance().resolve(bytesHP);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    size_t off = 0; int err = 0;
    while (off < len) {
        auto n = _eco_write(fd, data + off, len - off);
        if (n < 0) { if (errno == EINTR) continue; err = errno; break; }
        off += (size_t)n;
    }
    if (_eco_close(fd) != 0 && err == 0) err = errno;
    if (err == 0) {
        std::error_code ec;
        std::filesystem::rename(tmp, pathStr, ec);       // POSIX rename(2): atomic replace
#if defined(_WIN32)
        for (int i = 0; ec && i < 5; ++i) {               // sharing violation while a reader holds it
            std::this_thread::sleep_for(std::chrono::milliseconds(10 << i));
            ec.clear(); std::filesystem::rename(tmp, pathStr, ec);
        }
#endif
        if (!ec) { ECO_KLOG("file", "writeBytesAtomic done path=%s wrote=%zu", pathStr.c_str(), len);
                   return succeedUnit(); }
        err = ec.value();
    }
    ::unlink(tmp.c_str());   // _unlink on Windows; best effort, error ignored
    ECO_KLOG("file", "writeBytesAtomic fail path=%s errno=%d", pathStr.c_str(), err);
    return failErrno(err, pathStr, "could not write file atomically");
}
uint64_t writeBytesAtomic(uint64_t path, uint64_t bytes) {   // exported section, mirrors writeBytes :619-626
    HPointer pathHP = Export::decode(path), bytesHP = Export::decode(bytes);
    Elm::StackRootGuard g(&pathHP, &bytesHP);
    HPointer payload = Elm::alloc::tuple2(Elm::alloc::boxed(pathHP), Elm::alloc::boxed(bytesHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeBytesAtomicBody>(payload));
}
```

Notes on the body:
- **Includes:** `<atomic>`, `<thread>`, `<chrono>`.
- **Temp files:** they sit in the same directory (rename needs the same filesystem). They are unique per process (pid), per call (`atomic` sequence), and O_EXCL guards against pid reuse across PID namespaces sharing a volume.
- **Leftovers:** a SIGKILL'd process can leave a `*.tmp-<pid>-<n>`. No reader globs `eco-stuff`; the harness pre-cleans and `rm -rf eco-stuff` remove them.
- **fsync: none.** The goal is atomicity against concurrent readers and killed processes, not power-loss durability. ext4's `auto_da_alloc` covers rename-over-existing in practice, and a torn file after power loss stays in today's "decode fails → Corrupt/rebuild" class.
- **Windows:**
  - `std::filesystem::rename` maps to `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)`. That replaces the target, but fails with a sharing violation while another process has the target open without `FILE_SHARE_DELETE` (our readers use `ifstream`/`_open`). Hence the bounded retry, then a failure.
  - Replacement is not guaranteed atomic, but a reader never sees a partial file.

**Exports:**
- `File.hpp`: `uint64_t writeBytesAtomic(uint64_t path, uint64_t bytes);`
- `FileExports.cpp`, after `:21-23`:
  ```cpp
  HPtr Eco_Kernel_File_writeBytesAtomic(HPtr path, HPtr bytes) {
      ECO_KERNEL_GUARD( return HPtr::fromBits(File::writeBytesAtomic(path.toBits(), bytes.toBits())); )
  }
  ```
- `KernelExports.h`, after `:71`: `// Write raw bytes via temp file + rename. Returns Task IOError ().` and `HPtr Eco_Kernel_File_writeBytesAtomic(HPtr path, HPtr bytes);`

**JS (`eco-kernel-cpp/src/Eco/Kernel/File.js`)**, after `_File_writeBytes`:
```js
var _File_atomicSeq = 0;
var _File_writeBytesAtomic = F2(function(path, bytes) {
    return __Scheduler_binding(function(callback) {
        var fs = require('fs');
        var tmp = path + '.tmp-' + process.pid + '-' + (_File_atomicSeq++);
        try {
            fs.writeFileSync(tmp, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), { flag: 'wx' });
            fs.renameSync(tmp, path);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            try { fs.unlinkSync(tmp); } catch (_) {}
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});
```

**Elm APIs:**
- `eco-kernel-cpp/src/Eco/File.elm`: export `writeBytesAtomic`, add it to `@docs`, and place it after `writeBytes` (`:96`):
  ```elm
  {-| Write raw bytes to a temp file beside `path`, then rename it over `path`
  (readers never observe a partial file). -}
  writeBytesAtomic : String -> Bytes -> Task IOError ()
  writeBytesAtomic path bytes =
      Eco.Kernel.File.writeBytesAtomic path bytes |> Task.mapError IOErr.ofKernelTuple
  ```
- xhr twin `compiler/src-xhr/Eco/File.elm`, with the same export/docs:
  ```elm
  writeBytesAtomic path bytes =
      Eco.XHR.sendBytesTask "File.writeBytesAtomic" [ Http.header "X-Eco-Path" path ] bytes
          |> Task.mapError IOErr.ofKernelTuple
  ```
- `compiler/bin/eco-io-handler.js` `handleEcoIOBinary` (`:697`): add `case "File.writeBytesAtomic"`. It does the same as JS, with a module-level `let atomicSeq = 0` and `process.pid` (the server is one process serving concurrent requests, hence the counter). Respond `200, ""`, or `500, ioErrorBody(e)`. `index.js` routes every `X-Eco-Op` generically, so no other change.
  - This twin matters most: the E2E harness runs guida (the xhr build) in parallel.

**Switch point (one line).** `Utils.binaryEncodeFile` (`Utils/Main.elm:1286`) → `Eco.File.writeBytesAtomic`. Every artifact write goes through `File.writeBinary` / `BW.writeBinary` → `binaryEncodeFile`:

| File | Write site |
|---|---|
| `.ecot` | `Build.elm:1598` |
| `.eco` | `Build.elm:1584` |
| `.eci` | `Build.elm:1626,1632` |
| `d.dat` | `Build.elm:1755`, `Details.elm:863` |
| `i.dat` | `Details.elm:862` |
| `o.dat` | `Details.elm:861` |
| typed-artifacts and `artifacts.dat` | `Details.elm:1321,1341` |
| `registry.dat` | `Registry.elm:132,201` |

All of them switch. `writeUtf8`, `writePackage`, and the backend output (`Backend.elm:473`) stay on `writeBytes`.

**Write ordering (recommended, same change).** Today `writeObjectsAndFinalizeCompile` (`Build.elm:1566`) writes `.ecot`/`.eco` and then `.eci`. But `RCached` is gated on the `.ecot`/`.eco` existing (`:884-894`), so a crash between the two leaves `.ecot` without `.eci`. The next build then calls `RCached` → `loadInterface` → `Corrupted` → `RBlocked`.

Reorder so the gating artifact is written last:
```elm
writeObjectsAndFinalizeCompile ctx =
    let eciPath = Stuff.eciWithBuildDir ctx.root ctx.maybeBuildDir ctx.name in
    File.readBinary I.interfaceDecoder eciPath
        |> Task.andThen (\maybeOld ->
            let changed = maybeOld /= Just ctx.iface in
            (if changed then File.writeBinary I.interfaceEncoder eciPath ctx.iface else Task.succeed ())
                |> Task.andThen (\_ -> writeUntypedObjectsIfNeeded ctx)
                |> Task.andThen (\_ -> writeTypedObjectsIfNeeded ctx)
                |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.BDone)
                |> Task.map (\_ -> if changed then buildRNew ctx else buildRSame ctx))
```
This replaces `checkInterfaceAndFinalize` and `finalizeBasedOnInterface`. It writes the same files with the same bytes.

**LSS_022 audit.** The manifest pins whole files:
- `eco-kernel-cpp/src/eco/File.cpp` → 23 `TypeFaithful` rows;
- `eco-kernel-cpp/src/eco/FileExports.cpp` → the same 23 rows.

The 23 `File.*` rows are `appDataDir`, `canonicalize`, `close`, `createDir`, `dirExists`, `fileExists`, `findExecutable`, `getCwd`, `hWriteString`, `list`, `lock`, `mime`, `modificationTime`, `name`, `open`, `readBytes`, `readString`, `removeDir`, `removeFile`, `setCwd`, `size`, `touch`, `unlock`, `writeBytes`, `writeString`. `File.hpp` and `KernelExports.h` are not pinned.

Manifest delta:
- **Rehash:** 46 lines (23 kernels × 2 files).
- **Add:** 2 lines, `File.writeBytesAtomic` × {`File.cpp`, `FileExports.cpp`}.

Procedure (`plans/kernel-parametricity-license.md` §2.1, §2.5, §2.6):
1. Re-audit each of the 23 rows as a `vacuous`-class batch (one commit for the File module). No row's transitive call list gains anything, because the new code is a new function plus a file-scope integer. Even so, every evidence string cites line numbers (e.g. `File.cpp:writeBytes:619-626`), and those shift. Update each row's entry/helper line ranges and set `audited: <date>`.
2. Add the new row in `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm`, in alphabetical order after `("File","writeBytes")` (`:1412`):
   ```elm
   , ( ( "File", "writeBytesAtomic" )
     , TypeFaithful
           { scope = Inert
           , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
           , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeBytesAtomic:<a>-<b> | helpers: File.cpp:writeBytesAtomic:<c>-<d>, File.cpp:writeBytesAtomicBody:<e>-<f> | type: Eco/File.elm:<g> (String -> Bytes -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :<h>; gAtomicWriteSeq is a plain integer | B3: binding closure only | audited: <date>"
           }
     )
   ```
3. Last step: `sh test/scripts/check-kernel-license-manifest.sh /work --update`, then reconfigure (new manifest paths feed `KERNEL_LICENSE_DEPS`, `CMakeLists.txt:1135-1150`), then `cmake --build build` (the `kernel-license-check` target in ALL).

Never run `--update` before the evidence dates are advanced.

**Gates:**
- G1.
- G2.
- G3, plus a parallel stress check: two `--builddir`-less parallel `eco make` of the same project, 20×, with no "Corrupt File" in either log.
- G4.
- G6.
- G9.
- IO_ERR_001: the new leaf returns `Task IOError`, and `binaryEncodeFile` keeps `crashOnError`.
- **Unit test:** a JS-kernel and native E2E test (`test/eco-kernel/src/WriteBytesAtomicTest.elm`) covering:
  - writing over an existing file;
  - reading it back;
  - writing into a missing directory gives `Err` with the NotFound tag, and no `*.tmp-*` is left.

**Risks:**
- A larger LSS_022 diff (46 rehashes).
- `rename` fails across filesystems. That cannot happen here, because the temp file is a sibling.
- On Windows, a reader holding the file blocks the replace (bounded retry, then a failure).

---

### 5.12d S12d — ECOT invariants

**Format** (`design_docs/invariants.csv`):
- Header line 1: `id;phase;category;status;description;source`.
- One row per line, blank line between rows, `# ===` section banners.
- `source` is `|`-separated.
- **Descriptions must not contain `;`**. Several older rows do (e.g. REP_ABI_002), and that breaks column splitting; do not copy them. Also avoid `|` in descriptions.
- There is no `Builder` phase in the file. Use `TypedOptimization` with category `ArtifactSerialization`, and place the rows in a new banner right after `TOPT_006` (line 135, before the MONOMORPHIZATION banner):

```
# =============================================================================
# TYPED ARTIFACT SERIALIZATION - .ecot / typed-artifacts.dat wire format
# =============================================================================

ECOT_001;TypedOptimization;ArtifactSerialization;enforced;On-disk .ecot and typed-artifacts.dat are a strict subset of the in-memory typed artifact. NOT serialized and rebuilt as inert defaults on decode: LocalGraph.main (Nothing) and LocalGraph.fields (Dict.empty) and GlobalGraph fields (Dict.empty) and ModuleTypeEnv.aliases (Dict.empty) and the per-Node deps sets of Define TrackedDefine Cycle Kernel PortIncoming PortOutgoing (EverySet.empty) and the Manager EffectsType (Cmd placeholder) and Kernel chunks and deps ([] and EverySet.empty) and Expr.VarDebug home and unhandledValueName (Elm Debug and Nothing). No consumer downstream of deserialization may read any of these fields. Adding such a reader requires re-adding the wire slot first and bumping typedGraphFormatVersion and V.compiler (ECOT_003 rule). Main detection on the typed path reads the in-memory TOpt main of Fresh modules and Details.Local.hasMain for cached ones, never a decoded main;Compiler/AST/TypedModuleArtifact.elm|Compiler/AST/TypedOptimized.elm|Compiler/AST/TypeEnv.elm|Terminal/Make.elm

ECOT_002;TypedOptimization;ArtifactSerialization;enforced;Every .ecot section and typed-artifacts.dat graph or type env begins with a per-call string-table preamble: u8 index width (1 if count <= 256 else 2 if count <= 65536 else 4) then u32 count then count length-prefixed UTF-8 strings sorted ascending (Set.toList order) for bootstrap byte-identity. Every string field of the body is then the big-endian index of that width. The collectStringsFrom* functions (accumulating through StringTable.add) must add exactly the strings the *EncoderS functions emit. A missing string is NOT caught: StringTable.string emits index 0 and the artifact silently mis-decodes. An extra string only grows the table but changes bytes. TOpt.computeVarSupers reuses the same traversal in CollectSupers mode so varSupers covers every emitted name including literals and fields (by design byte-identical with the pre-S2 implementation). Interning is disabled (width 0 sentinel) for .eci and other legacy formats;Compiler/AST/StringTable.elm|Compiler/AST/TypedOptimized.elm|Compiler/AST/TypeEnv.elm|Compiler/AST/Canonical.elm|Compiler/Elm/ModuleName.elm|Compiler/Elm/Package.elm

ECOT_003;TypedOptimization;ArtifactSerialization;enforced;From typedGraphFormatVersion 2 (V.compiler 0.1.2) every Can.Type in a typed artifact body is written as an id into a per-file type table that follows the string table. Dedup key = the full structural node including the TLambda solver-root (arrow) slot and the FieldType index and Holey versus Filled alias bodies and the record extension name and alias argument names and the type of every child. Two nodes share an id only if they are structurally equal under native == (Eco.Hash.deep is only a bucket hint and never decides equality alone). Ids are assigned children-first so every entry references only smaller ids and entries are emitted in first-occurrence order of a deterministic traversal identical in the JS and native encoders (bootstrap byte-identity and G7). The decoder builds an Array by id in one forward pass and resolves child ids by Array.get with no forward references. Any change to the table layout or key fields bumps typedGraphFormatVersion AND V.compiler because a failed package typed-artifacts.dat decode is silently replaced by an empty graph;Compiler/AST/TypedOptimized.elm|Compiler/AST/Canonical.elm|Compiler/Elm/Version.elm|Builder/Elm/Details.elm
```

Fix the ECOT_003 wording (table position, id width, whether the TypeEnv shares the table) once §5.3 fixes the S3 layout.

The drafted ECOT_002 text in `plans/ecot-string-interning.md:229-237` claims "mismatches crash at encode time". The code (`StringTable.elm:131-139`) emits 0 instead. The row above states the real behaviour. Optional hardening, separate item: crash in non-release builds.

**The 14 code sites citing ECOT_001/002** (keep them; add ECOT_003 citations at the S3 encoder/decoder and `typedGraphFormatVersion`):

| # | site | cites |
|---|---|---|
| 1 | `Compiler/AST/TypedModuleArtifact.elm:13` (skip-list doc, source of ECOT_001) | 001 |
| 2 | `Compiler/AST/TypedOptimized.elm:507` (globalGraphEncoder doc) | 001 |
| 3 | `TypedOptimized.elm:510` | 002 |
| 4 | `TypedOptimized.elm:557` (localGraphEncoder doc) | 001 |
| 5 | `TypedOptimized.elm:561` | 002 |
| 6 | `TypedOptimized.elm:635` (nodeEncoderS doc) | 001 |
| 7 | `TypedOptimized.elm:898` (VarDebug encode) | 001 |
| 8 | `TypedOptimized.elm:1137` (VarDebug decode) | 001 |
| 9 | `TypedOptimized.elm:1704` (collector banner) | 002 |
| 10 | `Compiler/AST/StringTable.elm:32` (module doc, source of ECOT_002) | 002 |
| 11 | `Compiler/AST/TypeEnv.elm:147` (moduleTypeEnvEncoder doc) | 001 |
| 12 | `TypeEnv.elm:152` | 002 |
| 13 | `TypeEnv.elm:236` (collector banner) | 002 |
| 14 | `Compiler/AST/Canonical.elm:1587` (collector banner) | 002 |

**Also.**
- Add ECOT_001-003 entries to `design_docs/invariant-test-logic.md`, which has none today. They point to:
  - ECOT_001: the codec round-trip tests of §5.3.8;
  - ECOT_002: the §5.2 equivalence test and G7;
  - ECOT_003: the §5.3.8 tests, G7 and G8.
- Gates: none at run time. Review only: check that no `;` appears in a description with `awk -F';' 'NR>1 && /^ECOT_/ {print $1, NF}' design_docs/invariants.csv`; every ECOT row must print 6.

### 5.12e G6 — `benchmarks/incremental-cache-check.sh`

**CLI facts:**
- Flags: `--output=<file>.mlir` (bytecode unless `--text-mlir`) and `--builddir=<name>` (one path component; `Make.parseBuildDir :786`). There is no `--build-dir`.
- Default compiler: Stage 9 `build/compiler/build-kernel/bin/eco`.
- Change detection is `localData.time /= newTime` at ms resolution (`Build.elm:669`, `File.elm:339`). The script sleeps 1 s before every mutation.

**Projects:**
- **`synth`** (default, ~seconds): a generated 9-module app with a hub, 6 mids, a leaf and Main, on `elm/core` + `elm/html`. Its phases change the interface and the output.
- **`stress`** (~1 min): a copy of `test/stress-elm/src`, entry `JsonRoundtripNestedTree.elm`, hub `StressHarness`, leaf `Xorshift32`.
- **`compiler`** (slow: 4–5 cold builds × ~130 s per mode): a copy of `compiler/src`, hub `Compiler/Data/Name.elm` (137 importers), leaf `Terminal/Bump.elm`.

All trees are copies under `OUT`, so the script is read-only on `/work`.

**Expected status:**
- Before S12b, mode `builddir` fails at A0 and every `B-*` with "CORRUPT CACHE" (`GenerateCannotLoadArtifacts`). Verified on `synth`: 0.2 s per build; mode `root` passes all 5 phases.
- The `sem`/`shape` phases change the MLIR (B≠A, so the check discriminates); `touch`/`body`/`iface` leave it equal to A.
- After S12b, everything passes.

```bash
#!/bin/bash
# incremental-cache-check.sh -- gate G6 (plans/cache-serialization-optimization.md §1, §5.12e).
#
# Proves that an incremental build over warm per-module caches (.eci/.ecot/d.dat)
# emits the same MLIR as a cold build of the same source tree, with and without
# --builddir. Per PROJECT x MODE (root | builddir):
#   A   cold build (eco-stuff wiped)
#   A0  warm no-op rebuild                  cmp A0 A   (catches the S12b path mismatch)
#   [-n] N  one-shot (--no-cache) cold build cmp N A, eco-stuff untouched, then warm == A (S4)
#   per PHASE: mutate leaf + hub, then
#     B   incremental rebuild over the warm caches
#     C   cold build of the same tree (eco-stuff moved aside, then restored, so paths are identical)
#     cmp B C   (touch phase also: cmp B A)
#   finally: cmp root/A builddir/A
# Phases: touch (mtime only -> RSame path), body (append dead defs), iface (expose the
# hub probe -> RNew cascade), and for synth also sem (change hub/leaf values) and
# shape (add a constructor to the hub's exposed type).
#
# usage: incremental-cache-check.sh [-e ECO] [-o OUT] [-m "root builddir"] [-n] [-k] [synth|stress|compiler]...
# exit:  0 all equal | 1 an MLIR/cache mismatch | 2 a build failed | 3 usage/setup error
set -u
ulimit -c 0

REPO=/work
ECO=$REPO/build/compiler/build-kernel/bin/eco
OUT=/tmp/incr-cache-check-$(date +%Y%m%d-%H%M%S)
MODES="root builddir"
ONESHOT=0
KEEP=0
while getopts "e:o:m:nk" opt; do
  case $opt in
    e) ECO=$OPTARG ;; o) OUT=$OPTARG ;; m) MODES=$OPTARG ;;
    n) ONESHOT=1 ;; k) KEEP=1 ;; *) echo "usage: $0 [-e ECO] [-o OUT] [-m MODES] [-n] [-k] [synth|stress|compiler]..." >&2; exit 3 ;;
  esac
done
shift $((OPTIND - 1))
PROJECTS=${*:-synth}
[ -x "$ECO" ] || { echo "no compiler at $ECO" >&2; exit 3; }
if [ "$ONESHOT" = 1 ] && ! "$ECO" make --help 2>&1 | grep -q -- '--no-cache'; then
  echo "-n given but $ECO has no --no-cache flag (S4 not built)" >&2; exit 3
fi
mkdir -p "$OUT" || exit 3
SUMMARY=$OUT/summary.tsv
printf 'project\tmode\tstep\tresult\tseconds\n' > "$SUMMARY"
WORST=0
fail() { [ "$1" -gt "$WORST" ] && WORST=$1; }
# Avoid the slow registry POST (memory: heap-profile-revived-gc-baseline).
for r in "$HOME"/.eco/*/packages/registry.dat; do [ -f "$r" ] && touch "$r"; done

# ---------------------------------------------------------------- projects
gen_synth() {   # $1 = tree
  local t=$1 k
  mkdir -p "$t/src" && cp "$REPO/test/elm/elm.json" "$t/elm.json" || return 1
  cat > "$t/src/Hub.elm" <<'EOF'
module Hub exposing (Shape(..), area, hubValue, scale)


type Shape
    = Circle Int
    | Square Int -- SHAPES


area : Shape -> Int
area shape =
    case shape of
        Circle r ->
            3 * r * r

        Square s ->
            s * s -- AREA


hubValue : Int
hubValue =
    1 -- HUBVAL


scale : Int -> Int
scale x =
    x * hubValue
EOF
  for k in 1 2 3 4 5 6; do
    cat > "$t/src/Mid$k.elm" <<EOF
module Mid$k exposing (mid$k)

import Hub exposing (Shape(..))


mid$k : Int -> Int
mid$k n =
    Hub.scale (Hub.area (Circle (n + $k))) + Hub.area (Square $k)
EOF
  done
  cat > "$t/src/Leaf.elm" <<'EOF'
module Leaf exposing (leafValue)

import Hub
import Mid3


leafValue : Int
leafValue =
    Mid3.mid3 7 + Hub.hubValue + 1 -- LEAFVAL
EOF
  cat > "$t/src/Main.elm" <<'EOF'
module Main exposing (main)

import Html exposing (text)
import Leaf
import Mid1
import Mid2
import Mid3
import Mid4
import Mid5
import Mid6


main =
    let
        total =
            Leaf.leafValue + Mid1.mid1 1 + Mid2.mid2 2 + Mid3.mid3 3 + Mid4.mid4 4 + Mid5.mid5 5 + Mid6.mid6 6

        _ =
            Debug.log "IncrCheck" total
    in
    text "ok"
EOF
}

setup_project() {   # $1 = project, $2 = tree; sets ENTRY HUB LEAF FLAGS PHASES
  local p=$1 t=$2
  rm -rf "$t" && mkdir -p "$t" || return 1
  case $p in
    synth)
      gen_synth "$t" || return 1
      ENTRY=src/Main.elm; HUB=src/Hub.elm; LEAF=src/Leaf.elm; FLAGS=()
      PHASES="touch body iface sem shape" ;;
    stress)
      cp -r "$REPO/test/stress-elm/src" "$t/src" && cp "$REPO/test/stress-elm/elm.json" "$t/" || return 1
      ENTRY=src/JsonRoundtripNestedTree.elm; HUB=src/StressHarness.elm; LEAF=src/Xorshift32.elm
      FLAGS=(--local-package "eco/kernel=$REPO/eco-kernel-cpp")
      PHASES="touch body iface" ;;
    compiler)
      cp -r "$REPO/compiler/src" "$t/src" && cp "$REPO/compiler/cmake/bootstrap/build-kernel/elm.json" "$t/" || return 1
      ENTRY=src/Terminal/Main.elm; HUB=src/Compiler/Data/Name.elm; LEAF=src/Terminal/Bump.elm
      FLAGS=(--optimize --kernel-package eco/compiler --local-package "eco/kernel=$REPO/eco-kernel-cpp")
      PHASES="touch body iface" ;;
    *) echo "unknown project $p" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- mutations
append_probe() { printf '\n\n%s : Int\n%s =\n    %s\n' "$2" "$2" "$3" >> "$1"; }
expose_probe() {   # insert NAME as the first item of FILE's exposing list (no-op for exposing (..))
  local f=$1 n=$2 tmp
  tmp=$(mktemp) || return 1
  awk -v n="$n" '
    !done && /exposing/ { seen = 1 }
    !done && seen && index($0, "(") > 0 {
      i = index($0, "(")
      if (substr($0, i + 1) !~ /^[ ]*\.\.[ ]*\)/) { $0 = substr($0, 1, i) " " n "," substr($0, i + 1) }
      done = 1
    }
    { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}
mutate() {   # $1 = phase (cwd = tree)
  sleep 1
  case $1 in
    touch) touch "$HUB" "$LEAF" ;;
    body)  append_probe "$HUB" incrCheckHubProbe_ 41 && append_probe "$LEAF" incrCheckLeafProbe_ 42 ;;
    iface) expose_probe "$HUB" incrCheckHubProbe_ && grep -q 'incrCheckHubProbe_,\|exposing (\.\.)' "$HUB" ;;
    sem)   sed -i 's/1 -- HUBVAL/2 -- HUBVAL/' "$HUB" && sed -i 's/+ 1 -- LEAFVAL/+ 2 -- LEAFVAL/' "$LEAF" ;;
    shape) sed -i 's/^    | Square Int -- SHAPES$/    | Square Int\n    | Tri Int -- SHAPES/' "$HUB" &&
           sed -i 's/^            s \* s -- AREA$/            s * s\n\n        Tri t ->\n            t * t -- AREA/' "$HUB" &&
           grep -q 'Tri t ->' "$HUB" ;;
  esac
}

# ---------------------------------------------------------------- builds
# build STEP [extra flags...]   (cwd = tree; uses PROJ MODE LOGD BD)
build() {
  local step=$1; shift
  local t0 t1 rc dt out=$LOGD/$step.mlir
  t0=$(date +%s.%N)
  "$ECO" make "${FLAGS[@]}" "${BD[@]}" "$@" --output="$out" "$ENTRY" > "$LOGD/$step.log" 2>&1
  rc=$?
  t1=$(date +%s.%N)
  dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [ $rc -ne 0 ] || [ ! -s "$out" ] || grep -q 'Corrupt File\|CORRUPT CACHE' "$LOGD/$step.log"; then
    printf '%s\t%s\t%s\tBUILD-FAIL(rc=%s)\t%s\n' "$PROJ" "$MODE" "$step" "$rc" "$dt" >> "$SUMMARY"
    echo "  $step: BUILD FAILED rc=$rc (log $LOGD/$step.log)"; tail -5 "$LOGD/$step.log" | sed 's/^/    /'
    fail 2; return 1
  fi
  printf '%s\t%s\t%s\tok\t%s\n' "$PROJ" "$MODE" "$step" "$dt" >> "$SUMMARY"
  echo "  $step: ok ($dt s)"
}
cold_aside() {   # cold build of the current tree without destroying the incremental state
  local step=$1; shift
  rm -rf eco-stuff.inc && { [ -d eco-stuff ] && mv eco-stuff eco-stuff.inc; }
  build "$step" "$@"; local rc=$?
  rm -rf eco-stuff && { [ -d eco-stuff.inc ] && mv eco-stuff.inc eco-stuff; }
  return $rc
}
same() {   # same A B label
  if cmp -s "$LOGD/$1.mlir" "$LOGD/$2.mlir"; then
    printf '%s\t%s\tcmp %s %s\tsame\t-\n' "$PROJ" "$MODE" "$1" "$2" >> "$SUMMARY"; echo "  cmp $1 $2: same"
  else
    printf '%s\t%s\tcmp %s %s\tDIFF\t-\n' "$PROJ" "$MODE" "$1" "$2" >> "$SUMMARY"; echo "  cmp $1 $2: DIFF"; fail 1
  fi
}

# ---------------------------------------------------------------- main loop
for PROJ in $PROJECTS; do
  for MODE in $MODES; do
    TREE=$OUT/work/$PROJ-$MODE; LOGD=$OUT/$PROJ-$MODE; mkdir -p "$LOGD"
    echo "== $PROJ / $MODE"
    setup_project "$PROJ" "$TREE" || { echo "setup failed" >&2; fail 3; continue; }
    case $MODE in root) BD=() ;; builddir) BD=(--builddir=g6check) ;; *) echo "bad mode $MODE" >&2; fail 3; continue ;; esac
    cd "$TREE" || { fail 3; continue; }
    rm -rf eco-stuff
    build A || continue
    build A0 && same A0 A
    if [ "$ONESHOT" = 1 ]; then
      find eco-stuff -type f ! -path '*/build/*' -printf '%P %s %T@\n' | sort > "$LOGD/stuff.before"
      cold_aside N --no-cache && same N A
      build N1 --no-cache && same N1 A        # one-shot over warm caches
      find eco-stuff -type f ! -path '*/build/*' -printf '%P %s %T@\n' | sort > "$LOGD/stuff.after"
      if cmp -s "$LOGD/stuff.before" "$LOGD/stuff.after"; then echo "  one-shot left eco-stuff untouched"
      else echo "  one-shot WROTE into eco-stuff (diff $LOGD/stuff.*)"; fail 1; fi
      build N2 && same N2 A                   # warm normal build after one-shot
    fi
    for ph in $PHASES; do
      mutate "$ph" || { echo "  mutate $ph failed" >&2; fail 3; break; }
      build "B-$ph" || continue
      cold_aside "C-$ph" || continue
      same "B-$ph" "C-$ph"
      [ "$ph" = touch ] && same "B-$ph" A
    done
    cd "$OUT" || exit 3
  done
  case " $MODES " in *" root "*) case " $MODES " in *" builddir "*)
    if cmp -s "$OUT/$PROJ-root/A.mlir" "$OUT/$PROJ-builddir/A.mlir"; then echo "== $PROJ: root/A == builddir/A"
    else echo "== $PROJ: root/A != builddir/A"; fail 1; fi ;; esac ;; esac
done

[ "$KEEP" = 1 ] || [ "$WORST" -ne 0 ] || rm -rf "$OUT/work"
echo "summary: $SUMMARY  (exit $WORST)"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
exit $WORST
```

**Notes:**
- `cold_aside` keeps the tree path identical, so even a path embedded in the MLIR cannot make B≠C. Spot check: E2E `.mlir` files contain no `/work` or `.elm` strings.
- On a failure the trees are kept for inspection (`$OUT/work`).
- A `B-*` that fails to build (e.g. `RBlocked`) counts as exit 2; a `DIFF` counts as exit 1.
- Run it on every item touching Build/Details/Stuff/File kernels:
  ```
  benchmarks/incremental-cache-check.sh synth stress 2>&1 | tee /tmp/g6.txt
  ```
  `compiler` is optional before format items (S3).

