# Kernel-Opt 14: Elm-source migration: List.reverse, mapN, sortBy (then JsArray/String HOFs)

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1; v3 = adversarial
verification pass — every load-bearing anchor re-checked against the tree, the chunk-counter and
objdump baselines re-measured live and reproduced exactly, and five substantive corrections applied:
the Appendix-B6 "UB" claim is **false** and no longer a payment; the Phase-4 split no longer uses
kernel `take`/`drop`; the deletion policy no longer returns silent zeros on the bytecode E2E corpus;
`map4`/`map5` are **not** free-deletable; the 2B plumbing inventory is 19 signatures + 7 call sites,
not "8 sites".) Derived from design_docs/kernel-boundary-reduction.md §5b (recommendation R-ES1),
audits audit-02/audit-03, the executed Stage-7a dynamic census
(design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt) and the static census
(design_docs/kernel-boundary/callsite-census-self-compile.txt).

## Goal

Migrate the List HOF kernels (reverse, map2..map5, sortBy/sortWith) from hand-written C++ to Elm
source. A HOF kernel is the worst case of the opaque boundary: the kernel calls back into Elm via
the closure-apply helpers, so neither side sees the other — no inlining either direction, no LSS
devirtualization of the callback, full statepoint + root traffic per element. Elm source DISSOLVES
the boundary (loop body + callback co-optimize in MLIR; every other kernel-opt compounds through it)
and deletes a GC-rooting hazard class from hand-written C++ per migration.

## Files touched

| File | Change | Phase |
|---|---|---|
| `compiler/src/Compiler/Eco/Config.elm` | `ListConfig` gains `shuntReverse : Bool` (:61-64), default at :324, decoder :367-370, hash token near :681 | 1 |
| `compiler/src/Builder/Eco/Config.elm` | `ECO_LIST_SHUNT_REVERSE` env override (chain :220-229, applier next to :490-511) | 1 |
| `compiler/src/Compiler/Generate/MLIR/Functions.elm` | `listShuntKernels` (:298-306) stays whole; the lookup inside `listChunksShunt` (:318-338, lookup at :327-333) consults `shuntReverse` | 1 |
| `~/.eco/0.1.0/packages/elm/core/1.0.5/src/List.elm` (overlay) | `map2..map5` (:437-457), `sortBy` (:484-486), `sortWith` (:502-504) get Elm bodies + private helpers; `sort` (:468-470) re-pointed at `sortWith compare` | 2A/3/4 |
| `vendor/elm-core/` (**new**, in-repo seed) | vendored elm/core 1.0.5 with the patched `List.elm` | 2B |
| `compiler/src/Builder/Stuff.elm` | `PackageCache` local slot `Maybe (Pkg.Name, FilePath)` → `Dict Pkg.Name FilePath` (:271-272, accessors :304-330, `resolveBundledKernel` :346-371, codec :429-443) | 2B |
| `compiler/src/Terminal/Make.elm` | `localPackage` flag becomes a comma-list (:97, :177, :194, :201, :212, :224, parser :828-835, `parseLocalPackage` :840-849; threading at :343,:356,:418,:432) | 2B |
| `compiler/src/Builder/Generate.elm` | same type in 4 signatures (:501, :683, :1142, :1172) — **missing from v1's table** | 2B |
| `compiler/src/Builder/Deps/Solver.elm` | `initEnv`/`forkHttpManagerAndInitCache` thread the slot (:798, :804, :806) | 2B |
| `compiler/src/Terminal/Main.elm` | flag chomp at :336 (stays `chompNormalFlag`; the *value* becomes a list) | 2B |
| `compiler/src/Builder/Elm/Details.elm` | `seedLocalPackage` (:968-985) unchanged in shape, now Dict-driven; same type in :299, :462, :468, :474, :530, :577 | 2B |
| `compiler/CMakeLists.txt` + `compiler/scripts/build-verify.sh` | add `--local-package elm/core=…` behind `ECO_CORE_OVERLAY` (7 stage sites: :299,:328,:359,:425,:484,:527,:984; script :21,:37) | 2B |
| `elm-kernel-cpp/src/core/ListExports.cpp` | delete `kernelListMapN` (:432-590), `map2..map5` (:592-637), `sortBy` (:677-749), `sortWith` (:751-808), `Elm_Kernel_List_reverse` (:651-654) — per the deletion policy; `callUnaryClosure` (:32-35) / `callBinaryClosure` (:37-...) go dead after Phase 4 | 1/3/4 |
| `elm-kernel-cpp/src/KernelExports.h` | drop the matching decls (:163 reverse, :169-174 map2..sortWith) | 1/3/4 |
| `runtime/src/codegen/RuntimeSymbols.cpp` | drop `KERNEL_SYM(Elm_Kernel_List_{map2..map5,sortBy,sortWith})` (:696-701) | 3/4 |
| `compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` (pre-kernel-opt-07) **or** `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` (post-07) | delete `("List","map2")` (:116-121), `("List","sortBy")` (:122-126), `("List","sortWith")` (:127-131) rows. **After kernel-opt-07 lands, `KernelSigs.elm` is a thin re-export shim with no rows — the `(home, name)`-keyed rows live in `KernelFacts.elm`; delete them there instead.** | 3/4 |
| `benchmarks/kernel-opt.md` | one labelled run entry per phase | all |

Untouched on purpose: `runtime/src/allocator/ListOps.{hpp,cpp}` (`ListOps::reverse` has a live
in-runtime caller, `ElmBytesRuntime.cpp:331` — only the *export* wrapper is deletable);
`GlobalOpt/ListCombinators.elm` (census-only recognition, keeps `Reverse`/`SortBy`/`SortWith` rows);
`MonoSolver/Translate.elm:1860-1892` (kernel-devirt whitelist — `List.cons` only, and Phase 1
*depends* on it).

## Flag & rollback

- **Phase 1 flag:** `config.list.shuntReverse : Bool` in `Compiler/Eco/Config.elm` (`ListConfig`,
  :61-64), **default `True` = today's behavior**; JSON `"list": { "shuntReverse": false }`; env kill
  switch `ECO_LIST_SHUNT_REVERSE=0|1` (Builder/Eco/Config.elm, alongside `applyListChunksOverride`
  :490-511). `clamp` (:512-533) touches only `logicalTypes.customMaxFields` — a new `Bool` needs no
  clamp arm; the only two `ListConfig` *record literals* in the tree are `default` (:324) and
  `listDecoder` (:369), so those are the only two sites that break on a new field
  (`grep -rn 'ListConfig\|list = {\|{ chunks' compiler/src compiler/tests --include=*.elm`).
  Artifact-affecting → hash token emitted **only when False** (`"lrevsh=0"`), so
  pre-flag artifacts keep their existing keys before the flip and get fresh keys after it.
  Rollback = set the field back to `True` (or `ECO_LIST_SHUNT_REVERSE=1`); zero code deletion needed
  because the shunt entry survives in `listShuntKernels`.
- **Phases 3/4 flag:** there is no compiler flag — the switch is *which elm/core source the build
  sees*. Measurement vehicle (2A) rollback = restore stock `List.elm` from
  `vendor/elm-core.stock/List.elm` + re-run the cache-invalidation list. Ship vehicle (2B) rollback =
  CMake option `ECO_CORE_OVERLAY` (**default OFF**) that appends the extra `--local-package`; OFF
  reproduces today's builds exactly (the flag literally removes an argv entry).
- **Kernel-symbol deletions** are the only irreversible step and are gated behind the deletion policy
  below; they land in a **separate commit after** the migration commit has passed all gates, so a
  revert of the migration never leaves dangling symbols.

## Evidence

- Dynamic (Stage-7a, 3,676,097,627 total kernel calls; `kernel-census-dynamic-stage7a.txt`, one
  symbol per line, ranked): `List_reverse` 42,762,774 (**rank #10**, file line 11 — v1 said #8);
  `List_map2` 5,219,066; `JsArray_foldl` 1,621,361; `List_sortBy` 780,182; `String_map` 832
  (String HOFs are compile-workload-COLD — heat does not justify that phase, hazard deletion does).
  `List_sortWith` does not appear in the top rows at all.
- Static, **re-measured 2026-08-10** on the textual self-compile module (`direct = "callee = @Sym"`,
  `pap = "function = @Sym"`; `direct + pap + 1 is_kernel stub = total occurrences`):

  | symbol | direct | pap | total |
  |---|---:|---:|---:|
  | `Elm_Kernel_List_cons` | 4155 | 0 | 4156 |
  | `Elm_Kernel_List_reverse` | 468 | 0 | 469 |
  | `Elm_Kernel_List_map2` | 251 | 0 | 252 |
  | `Elm_Kernel_List_sortBy` | 88 | 0 | 89 |
  | `Elm_Kernel_List_sortWith` | 22 | 0 | 23 |
  | `Elm_Kernel_List_map3` | 2 | 0 | 3 |
  | `Elm_Kernel_List_map4/map5/drop` | 0 | 0 | **0 (not even a stub)** |

  **This table is the self-compile module ONLY, not the corpus.** `map4`/`map5` *are* referenced by
  the E2E half (`test/elm/src/ListMap{4,5}FloatAggregateTest.elm:16`, visible in
  `build/test/elm/eco-stuff/mlir/ListMap4FloatAggregateTest.mlir`) — see the deletion policy.
  Cross-check on an Aug-3 text module in `build/compiler/build-kernel/bin/` (chunks OFF, so the
  shunt symbols read 0 there): map2 235, map3 2, sortBy 78, sortWith 22, cons 4085,
  `@List_reverse_*` 1661 — same order of magnitude, so the numbers above are drift, not error.

  Also measured: `callee = @List_reverse_*` = 1700 — i.e. 468 reverse *specs*, each a one-kernel-call
  body, called from 1700 sites. Post-un-shunt those 468 bodies become cons-accumulator loops.
- `reverse = foldl cons []` (elm/core `List.elm:259-261`) is exactly the cons-accumulator shape
  `EcoListTemplate` chunk-rewrites (`runtime/src/codegen/Passes/EcoListTemplate.cpp`: chain walk
  `walkChain` :129-214, loop rewrite `tryRewrite` :370, unwind-recursion rewrite `tryRewriteUnwind`
  :729; kernel cons recognized by `kernelConsKind` :98-112); today it takes the Tier-B chunk shunt
  (`config.list.chunks`, `Functions.elm:298-306`/`:318-338`).
- mapN: a ~160-line GC-safe cursor driver `kernelListMapN`
  (`elm-kernel-cpp/src/core/ListExports.cpp:432-590`, callers :592-637) exists ONLY to re-root
  cursors across callback GCs — the source of the historical stale-cursor use-after-GC bug (memory:
  eco-listmapn-stale-cursor-gc-bug, found via ECO_HEAP_VALIDATE).
- sortBy/sortWith: the comparator ALREADY calls back into Elm per comparison — zero boundary benefit
  from C++ (`std::stable_sort` at `ListExports.cpp:722-737` sortBy, `:779-796` sortWith; the
  once-per-element key pass at `:700-716`).
- **CORRECTION to the design doc's Appendix B6 (`kernel-boundary-reduction.md:2271`, anchor
  `Utils.cpp:305`): there is NO strict-weak-ordering UB, and this phase must not claim to retire
  one.** `Utils::cmp` reads (`elm-kernel-cpp/src/core/Utils.cpp:302-306`):
  `if (!a && !b) return 0; if (!a) return -1; if (!b) return 1;`. The `!a && !b` arm comes **first**,
  so two embedded-constant keys (the `nullptr` case the sortBy lambda constructs at
  `ListExports.cpp:730-733`) compare **EQ**, not "less in both directions"; const-vs-heap is a
  consistent total preorder (constant side always first), which is a legal SWO. B6's parenthetical
  reads line :305 in isolation and ignores :304.
  Nor is there an expected *Elm-vs-C++* ordering divergence: `Elm_Kernel_Utils_compare`
  (`elm-kernel-cpp/src/core/UtilsExports.cpp:13-16`) is `Utils::compare(Export::toPtr(a), …)`, and
  `Export::toPtr` (`elm-kernel-cpp/src/ExportHelpers.hpp:47-56`) maps embedded constants to
  `nullptr` — **the identical input** the C++ sortBy lambda builds. So an Elm merge sort calling
  `compare` lands in the very same `cmp` and gets the very same answers. The residual (pre-existing,
  shared by both implementations) semantic wart is const-`""` vs a *heap-resident* empty string: the
  nested path canonicalises it (`Utils.cpp:186-196`, `size == 0 ⇒ 0`) but top-level `cmp` does not.
  That wart is unchanged by this migration in either direction.
- Prior calibration: HOF-elimination H0–H6 removed −99.2% of dispatch events, so the heat is real;
  but 4 consecutive metadata-only removals measured wall-FLAT. Wall tracks retention and deleted
  per-op work, not site counts.

## Approach

Order = dynamic heat × risk × *mechanical cost*. Phase 1 is a compiler-only change and ships alone.
Phases 3–4 require a delivery vehicle for patched elm/core source (Phase 2) because **elm/core is not
in this repo**: it is fetched from package.elm-lang.org into `~/.eco/0.1.0/packages/elm/core/1.0.5/`
and only `eco/kernel` is repo-local (`--local-package eco/kernel=…`, `Stuff.elm:302-330`).

### Phase 0 — baseline + attribution (no code change)

0.1 **Static corpus.** Produce the textual module once and keep it for every later delta. The
command is the CMake Stage-7a invocation verbatim (`compiler/CMakeLists.txt:478-491`) plus
`--text-mlir`; `ELM_ENTRY` is `compiler/src/Terminal/Main.elm` (:122) and the local-package path is
`${COMPILER_DIR}/../eco-kernel-cpp` = `/work/eco-kernel-cpp` (:484):

```bash
BK=/work/build/compiler/build-kernel
rm -rf "$BK/eco-stuff"
( cd "$BK" && ./bin/eco-compiler make --optimize --text-mlir \
    --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=/tmp/eco-compiler.txt.mlir /work/compiler/src/Terminal/Main.elm )
for s in reverse map2 map3 map4 map5 sortBy sortWith cons; do
  printf '%-9s direct=%s pap=%s\n' "$s" \
    "$(grep -c "callee = @Elm_Kernel_List_$s\\b"   /tmp/eco-compiler.txt.mlir)" \
    "$(grep -c "function = @Elm_Kernel_List_$s\\b" /tmp/eco-compiler.txt.mlir)"
done
grep -c '"eco.papCreate"'  /tmp/eco-compiler.txt.mlir   # 29382 on 2026-08-10
grep -c '"eco.papExtend"'  /tmp/eco-compiler.txt.mlir   # 43755 on 2026-08-10
grep -c '"eco.call"'       /tmp/eco-compiler.txt.mlir   # 100079 on 2026-08-10
```

These three are **config- and date-sensitive** (an Aug-3 `-out.mlir` in the same directory gives
29567 / 43413 / 140657 under a different flag set) — re-measure them, do not trust the numbers.
The `+2%` acceptance bands below are relative to **your own** Phase-0 run, not to these values.

0.2 **Chunk counters (the parity baseline).** `EcoListTemplate`'s statistics print to stderr under
`ECO_LIST_TEMPLATE_DEBUG` (`EcoListTemplate.cpp:326`, dump at :346-364, `BailStats::dump` :75-87).
The pass is a **no-op unless some `func.func` carries `eco.list_chunks`** (:314-322), which the
front end stamps on `@main` under `config.list.chunks` (default `True`, `Config.elm:324`;
`Functions.elm:99-104`) — so Phase 1 must leave `chunks = True` while flipping `shuntReverse`:

```bash
ECO_LIST_TEMPLATE_DEBUG=1 /work/build/runtime/src/codegen/eco-boot-native \
    /work/build/compiler/build-kernel/bin/eco-compiler.mlir -o /tmp/ec-chunkcount \
    2> /tmp/listtemplate.log
grep '^\[eco-list-template\]' /tmp/listtemplate.log | head -3
```

**Measured baseline (2026-08-10, current tree; reproduced verbatim during this plan's
verification pass):**
`whiles=4792 valueArgs=15457 bail{beforeFwd=0 beforeUses=0 chainFail=11214 chainEmpty=549
baseUses=3251 kinds=0} rewritten=443` and `unwind rewritten=38`, plus
`walkChain{blockArg=85 consUses=32 consRoots=0 headTy=0 regionShape=0 multiUse=3 otherOp=11094}`
and the two histograms (`breaker eco.call 856` is the row Phase 3 reads).
**Record `rewritten`, `unwind rewritten`, `consRoots`, `headTy`** — the same four kernel-opt-01
§0.2 records (`plans/kernel-opt-01-list-cons-construct-list.md:100-114`), so the two plans compare
like for like. The dump appears within the first minute; the rest of the lowering can be killed.

Secondary (binary-level) chunk census, ~2 min. Note it **must** be taken from the LINKED binary:
the front-end text module contains **zero** `eco_scratch_*` because the pass runs in the backend
(the same trap kernel-opt-01:106-107 flags):

```bash
objdump -d --no-show-raw-insn /work/build/compiler/build-kernel/bin/eco-compiler \
  | grep -oE 'eco_scratch_(mark|push_boxed|push_scalar|finish|finish_fwd)' | sort | uniq -c
```

**Measured baseline (reproduced 2026-08-10):**
`finish=70 finish_fwd=90 mark=53 push_boxed=71 push_scalar=16`.
*Reconciliation note.* The "582 `eco_scratch_push_boxed` + 491 `eco_scratch_mark` sites today"
figure in circulation comes from **`design_docs/kernel-boundary/audit-03-list-jsarray.md:79`**, not
from kernel-opt-01 (which never quotes it). It is an order of magnitude away from the objdump
census above and must not be used as a parity baseline — its extraction method is unrecorded.
Both plans quote **`rewritten=` + `unwind rewritten=` from `ECO_LIST_TEMPLATE_DEBUG`** as the
primary parity counter and the objdump census above as the secondary, with the commands verbatim.

0.3 **Wall/major-GC baseline.** Exactly `benchmarks/kernel-opt.md` §Methodology (2 rounds, cold
`eco-stuff`, `ECO_MONO_ENGINE=subst` workload, `/usr/bin/time -v`), recording `Objects allocated`,
`Bytes allocated`, `Minor GC cycles`, `Objects promoted`, **`Major GC cycles`**, `Total GC/Alloc
time` and the output `.mlir` byte size. Append the entry to `benchmarks/kernel-opt.md`.

0.4 **Dynamic-heat re-confirmation.** The dynamic census predates the Aug-10 compare-series ships;
the `Utils_compare` rows are stale but the List rows should not be. Re-run C1 of
`plans/kernel-call-census.md` (§C1.4 commands: instrumented backend build with
`ECO_KERNEL_CALL_CENSUS=1`, then the Stage-7a workload with stderr to a log) and diff the
`List_{reverse,map2,sortBy,sortWith}` rows only. **Criterion:** if `List_reverse` has fallen below
~5M calls, Phase 1's wall claim is void — re-rank the whole plan before spending.

**Acceptance:** all five baselines recorded in `benchmarks/kernel-opt.md` under one run label; no
tree change.

### Phase 1 — `List_reverse`: stop shunting, let the Elm body compile

**Mechanic (definitive).** `reverse` is *already Elm source upstream* (`List.elm:259-261`,
`reverse list = foldl cons [] list`). The kernel call exists only because
`Functions.elm:318-338` rewrites the body of every recognized elm/core `List.reverse`
specialization into one saturated `CallDirectFlat` kernel call (`listShuntNode` :341-357,
`listShuntCall` :366-385) under `config.list.chunks`. **Phase 1 is therefore a deletion, not new Elm
code**: remove `reverse` from the shunt table and the existing Elm body compiles.

The chunk win is expected to survive through this chain (all three links verified):
1. LSS mints a kernel member for the `cons` argument (`Translate.elm:3090-3102` calling
   `LssInfer.kernelAliasOf`, defined `LssInfer.elm:893-903`), and the E9.2 whitelist devirtualizes
   it — `kernelDevirtArity` allows exactly `("List","cons")` arity 2 (`Translate.elm:1860-1866`)
   with the shape guard `kernelDevirtShapeOk` at :1881-1892. So `foldl`'s specialized loop body
   contains a direct `Elm_Kernel_List_cons` call, not an indirect apply.
   **Precondition:** this link exists only under LSS — `defaultLss.enabled = True` and
   `devirtFnGlobals = True` (`Config.elm:170-174`) with `mono.engine = EngineSolver` (:322), so it
   holds for default builds and for the benchmark *binary* (built solver+LSS). A build with
   `ECO_MONO_LSS=0` will lose the chunk win by design — do not run the Phase-1 hard gate on one.
2. `foldl` is self-tail-recursive → TailRec → `scf.while` (no musttail self-calls exist in this
   compiler; memory: accumulator-templates AT1).
3. `EcoListTemplate::kernelConsKind` (:98-112) recognizes `Elm_Kernel_List_cons{,_Int,_Float,_Char}`
   as chain links, so `tryRewrite` converts the loop to `eco_scratch_mark/push/finish`.

**Steps.**

1. `Compiler/Eco/Config.elm` — extend `ListConfig` (:61-64) and its doc comment (:51-59):

```elm
type alias ListConfig =
    { chunks : Bool
    , shuntReverse : Bool  -- K14 P1: keep rewriting elm/core List.reverse specs into
                           -- Elm_Kernel_List_reverse. True = today. False = compile the
                           -- Elm body (`foldl cons []`) and let EcoListTemplate chunk it.
                           -- env ECO_LIST_SHUNT_REVERSE=0|1; hash token "lrevsh=0" when False.
    , report : Bool
    }
```

   default (:324) `, list = { chunks = True, shuntReverse = True, report = False }`;
   decoder (:367-370):

```elm
listDecoder : D.Decoder x ListConfig
listDecoder =
    D.pure (\chunks shuntReverse -> { chunks = chunks, shuntReverse = shuntReverse, report = default.list.report })
        |> D.apply (D.optionalField "chunks" D.bool default.list.chunks)
        |> D.apply (D.optionalField "shuntReverse" D.bool default.list.shuntReverse)
```

   hash token, immediately after the `lchunks` block (:677-686), following the `lssS` "non-default
   only" idiom (:665-669):

```elm
            ++ (if cfg.list.shuntReverse then
                    []

                else
                    [ "lrevsh=0" ]
               )
```

2. `Builder/Eco/Config.elm` — three edits.

   (a) **Chain link.** `applyEnvOverrides`' `Task.andThen` chain runs :141-264 with hand-numbered
   lambda binders (`cfg1 … cfg29`; note `cfg26` already appears twice, so the numbering is
   cosmetic). Do **not** insert mid-chain — **append** after the last link, the `ECO_BORROW_OPT`
   one at :260-264:

```elm
        |> Task.andThen
            (\cfg30 ->
                (Utils.envLookupEnv "ECO_LIST_SHUNT_REVERSE" |> Task.mapError never)
                    |> Task.map (\lsrVal -> applyListShuntReverseOverride lsrVal cfg30)
            )
```

   (b) **Doc bullet.** Add one line to `applyEnvOverrides`' doc comment bullet list (:76-111; the
   list currently ends with the `ECO_CAF_DEDUPE` bullet at ~:103-104) — that comment is the only
   in-tree index of the env knobs.

   (c) **Applier**, next to `applyListChunksOverride` (:490-511), which is the literal template:

```elm
{-| `ECO_LIST_SHUNT_REVERSE=1|0`: keep / drop the Tier-B kernel shunt for
`List.reverse` (K14 P1; artifact-affecting, hash token `lrevsh=0`).
-}
applyListShuntReverseOverride : Maybe String -> EcoConfig -> EcoConfig
applyListShuntReverseOverride maybeVal cfg =
    case maybeVal of
        Nothing -> cfg
        Just raw ->
            let t = String.toLower (String.trim raw)
                listCfg = cfg.list
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | list = { listCfg | shuntReverse = True } }
            else if t == "0" || t == "off" then
                { cfg | list = { listCfg | shuntReverse = False } }
            else
                cfg
```

3. `Generate/MLIR/Functions.elm` — make the table config-dependent. Keep `listShuntKernels` as the
   full table (:298-306) and filter at the lookup in `listChunksShunt` (:327-333):

```elm
                    case Dict.get name listShuntKernels of
                        Just arity ->
                            if name == "reverse" && not ctx.ecoConfig.list.shuntReverse then
                                node

                            else
                                listShuntNode name arity node

                        Nothing ->
                            node
```

   (One-symbol guard on purpose: `append`/`concat`/`take`/`drop` keep today's behavior —
   whitelist discipline, and audit-03 says `concat`/`take` genuinely lose the chunk representation
   in their natural Elm form.)

4. Build, then measure with the flag OFF (`ECO_LIST_SHUNT_REVERSE=0`) and ON.

**Per-phase acceptance.**
- Flag ON (default): `/tmp/eco-compiler.txt.mlir` regenerated is **byte-identical** to Phase 0's
  (the flag is the identity when on).
- Flag OFF: `callee = @Elm_Kernel_List_reverse` count → **0**; `@List_reverse_*` call count
  unchanged (1700 ± specialization noise).
- **HARD GATE — chunk parity:** `rewritten=` ≥ 443 **and** `unwind rewritten=` ≥ 38 from
  `ECO_LIST_TEMPLATE_DEBUG` on the flag-OFF module; expected direction is `rewritten` **up** by
  roughly the number of distinct reverse-carrying `foldl` specs. If `rewritten` does not rise while
  the reverse kernel calls vanish, the chunk win was lost → **stop and revert** (this is the exact
  failure kernel-opt-01 §Traps warns about; no test catches it).
- E2E: `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` green (see Gates).
- Wall A/B (flag ON vs OFF binaries) with `Major GC cycles` recorded.

### Phase 2 — the delivery vehicle for patched elm/core (prerequisite for Phases 3–4)

**Facts established by reading the tree** (do not re-litigate):
- `map2..map5`, `sortBy`, `sortWith` have *no Elm body*: `List.elm:437-457`, `:484-486`, `:502-504`
  are `f = Elm.Kernel.List.f`, canonicalized to `Can.VarKernel` (`Canonicalize/Expression.elm:1432-1437`).
- elm/core lives **only** in `~/.eco/0.1.0/packages/elm/core/1.0.5/` (downloaded; there is no in-repo
  copy — `find /work -name List.elm` finds only `compiler/tests/Compiler/Elm/Interface/List.elm`, a
  test fixture). `eco/kernel` ships no `List.elm` override either (`ls /work/eco-kernel-cpp/src`
  = `eco/`, `Eco/` only). The build-kernel `elm.json`
  (`compiler/cmake/bootstrap/build-kernel/elm.json`) pins `"elm/core": "1.0.5"`, so that directory
  is the exact one the self-compile reads.
- An app-level `List.elm` cannot shadow it: `Build.elm:600-604` reports `Import.Ambiguous` when a
  local path collides with a foreign module.
- A mono-level redirect into an eco-owned module is unsound: `eco/kernel` is an ordinary dependency
  (`eco-kernel-cpp/elm.json`), absent from programs that don't declare it.
- Package artifact caches are fingerprinted by **dependency versions only**, never by source content:
  `type alias Fingerprint = Dict Pkg.Name V.Version` (`Details.elm:1078-1079`), consulted at
  `:1004-1015` (`artifacts.dat`) and `:1022-1033` (`typed-artifacts.dat`) — so editing a cached
  package source is invisible to the build until its `.dat` files are deleted.
- The seed copy only runs when the cache dir's `src/` is **absent** (`Details.elm:945-946` →
  `handleDepExistence` :949-958 → `seedLocalPackage` :968-985), so once `~/.eco/…/elm/core/1.0.5`
  exists, whatever source sits there is what gets compiled — which is exactly what makes 2A work.

**2A — measurement overlay (non-shippable, use for Phases 3–4 measurement).** Ordered command list,
run from `/work`:

The patched source lives at `/work/vendor/elm-core-patch/List.elm` — a **single file**, created in
2A (2B later folds it into `vendor/elm-core/src/List.elm`; 2A must not depend on 2B existing):

```bash
CORE=~/.eco/0.1.0/packages/elm/core/1.0.5
mkdir -p /work/vendor/elm-core.stock /work/vendor/elm-core-patch
cp -p $CORE/src/List.elm /work/vendor/elm-core.stock/List.elm    # once, BEFORE the first patch
# ... edit /work/vendor/elm-core-patch/List.elm (seeded from the stock copy) ...
cp -p /work/vendor/elm-core-patch/List.elm $CORE/src/List.elm    # install the patch
rm -f  $CORE/artifacts.dat $CORE/typed-artifacts.dat             # MANDATORY: fingerprints ignore source
rm -f  /work/eco-kernel-cpp/artifacts.dat /work/eco-kernel-cpp/typed-artifacts.dat  # local-package caches (compiler/CMakeLists.txt:268-270)
rm -rf /work/build/compiler/build-kernel/eco-stuff                # app-level cache
# The next two lines are belt-and-braces for NON-`full` runs. `--target full` runs `--target clean`
# first (CMakeLists.txt:1113-1120), and clean already wipes both shadow trees' eco-stuff
# (test/CMakeLists.txt:34-40 JIT shadow, :56-59 AOT shadow).
rm -rf /work/build/test/*/eco-stuff /work/build/test/aot-e2e/*/eco-stuff
find /work/test/*/src -name '*.elm' -exec touch {} +              # harness needsRecompile() is mtime-blind to package edits
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Rollback: `cp -p /work/vendor/elm-core.stock/List.elm $CORE/src/List.elm` + the same four `rm`s.
**Verify the patch actually took effect before trusting any measurement** — the acceptance test at
the end of this phase (a no-op reformat must change `/tmp/eco-compiler.txt.mlir`) is not optional;
the fingerprint design makes a silently-ignored edit the default failure mode.
Note for benchmarking: `benchmarks/kernel-opt.md` says *never delete `~/.eco`* — this procedure
deletes **two `.dat` files of one package**, not the cache; re-warm once (one throwaway build)
before any timed run so package rebuild cost never lands in a measured wall.

**2B — ship vehicle (only if 2A's gates pass and the phase is kept).** Vendor elm/core in-repo and
seed it through the existing local-package machinery, which already copies a read-only seed into the
cache on first build (`Details.elm:949-985`). Two edits:

1. `vendor/elm-core/` = a verbatim copy of elm/core 1.0.5 (BSD-3; keep `LICENSE`, `README.md`,
   `elm.json`, `docs.json`, whole `src/` — that is the full contents of
   `~/.eco/0.1.0/packages/elm/core/1.0.5/` minus the two `.dat` caches) with
   `src/List.elm` replaced by `vendor/elm-core-patch/List.elm`, plus a `VENDOR.md` recording the
   upstream version and the eco delta. Note `docs.json` documents `sortBy`/`sortWith`/`map2..map5`
   as exposed values — the patch changes only their *bodies*, so `docs.json` needs no edit.
2. Widen the single local-package slot to a map (it is one constructor field today):

```elm
-- Builder/Stuff.elm:271-272
type PackageCache
    = PackageCache String (Dict Pkg.Name FilePath)

getPackageCache : Dict Pkg.Name FilePath -> Task Never PackageCache
getPackageCache locals =
    Task.map (\dir -> PackageCache dir locals) (getCacheDir "packages")

isLocalPackage (PackageCache _ locals) name = Dict.member name locals
localPackageSource (PackageCache _ locals) name = Dict.get name locals

-- codec (:429-443): today's encoder uses BE.maybe, the decoder `Bytes.Decode.map2 PackageCache`
-- + BD.maybe. Swap both to the BE.list/BD.list helpers already used at Details.elm:2167/:2196
-- (Stuff.elm already imports `Utils.Bytes.Encode as BE` :66 / `Utils.Bytes.Decode as BD` :65).
packageCacheEncoder (PackageCache dir locals) =
    Bytes.Encode.sequence
        [ BE.string dir
        , BE.list (\( n, p ) -> Bytes.Encode.sequence [ Pkg.nameEncoder n, BE.string p ]) (Dict.toList locals)
        ]

packageCacheDecoder =
    Bytes.Decode.map2 (\dir pairs -> PackageCache dir (Dict.fromList pairs))
        BD.string
        (BD.list (Bytes.Decode.map2 (\a b -> ( a, b )) Pkg.nameDecoder BD.string))
```

`Pkg.Name` is `( String, String )` and is already used as a plain `Dict` key in this tree
(`type alias Fingerprint = Dict Pkg.Name V.Version`, `Details.elm:1078-1079`), so `Dict.fromList`
takes the pair list directly — **no** comparator argument (that is `EveryDict.fromList`, e.g.
`Details.elm:877`).

   **Full call-site inventory** (`grep -rn 'getPackageCache' compiler/src --include=*.elm`):
   `Stuff.getPackageCache` is *defined* at `Stuff.elm:277` and has **7** call sites — five pass
   `Nothing` and become `Dict.empty` (`Bump.elm:98`, `Outline.elm:496`, `Diff.elm:125`,
   `Terminal/Terminal/Helpers.elm:219` and `:237` — note the doubled `Terminal/` path segment),
   two thread the slot through and become Dict-threading (`Deps/Solver.elm:806`,
   `Elm/Details.elm:302`).

   **Type-plumbing inventory** — the widening is not confined to `getPackageCache`. Run
   `grep -rn 'Maybe ( Pkg.Name, FilePath )' compiler/src --include=*.elm`: **19** signature
   occurrences across four files — `Terminal/Make.elm` (:97, :177, :201, :212, :224, :840),
   `Builder/Stuff.elm` (:272, :277, :346), `Builder/Elm/Details.elm` (:299, :462, :468, :474, :530,
   :577) and **`Builder/Generate.elm` (:501, :683, :1142, :1172)** — plus `Deps/Solver.elm:798/:804`
   whose binders are inferred. Budget the change as "19 signatures + 7 call sites", not "8 sites".

   `Make.parseLocalPackage` (:840-849) gains comma splitting (today it is a single
   `String.split "="`); `Make.Flags.localPackage` (:97, :177) and `Stuff.resolveBundledKernel`
   (:346-371, which *defaults* the eco/kernel entry when the slot is empty — with a Dict this
   becomes "insert `eco/kernel` if absent") move to the Dict. `Terminal/Main.elm:336` keeps
   `chompNormalFlag` (single flag, list value).
3. CMake: a top-level `option(ECO_CORE_OVERLAY "…" OFF)`; when ON, append
   `--local-package elm/core=${CMAKE_SOURCE_DIR}/vendor/elm-core` to the seven stage command lines
   (`compiler/CMakeLists.txt:299,328,359,425,484,527,984`) and to `scripts/build-verify.sh:21,37`,
   and add `~/.eco/0.1.0/packages/elm/core/1.0.5/{artifacts,typed-artifacts}.dat` handling to the
   overlay's first-build step (the seed only copies when the cache dir is **absent**,
   `Details.elm:949-958` — so the ON-switch requires `rm -rf $CORE` once, documented in the option's
   help text).

**Decision criterion (which vehicle, and whether 2B is ever paid for):** run Phases 3–4 under 2A.
Pay for 2B **only if** at least one of the two phases keeps its migration after gates (wall not
worse than FLAT per Gate 4's <3% band, chunk parity held per Gate 5, C++ hazard deleted). If both
phases are reverted, 2B is never written and Phase 2 costs nothing but the overlay script. Given
2B's real size (19 signatures + 7 call sites + 7 CMake lines), treat "one phase kept" as the
*minimum* bar, not the expected outcome.

**Acceptance:** 2A — a patched `List.elm` (even a no-op reformat) demonstrably changes the emitted
module (`/tmp/eco-compiler.txt.mlir` differs) after the command list, proving cache invalidation is
complete. 2B — `ECO_CORE_OVERLAY=OFF` build is byte-identical to the pre-patch build.

### Phase 3 — `List.map2..map5` in Elm

Replace `List.elm:437-457`. Tail-recursive with an accumulator + `reverse` (chunk-friendly on both
ends) rather than the natural non-tail form: `EcoListTemplate` has an unwind-cons rewriter
(driven at :335-348, `tryRewriteUnwind` :729) that would handle `f x y :: map2 f xs ys`, but
native stack depth on multi-million-element
lists is not worth the risk.

```elm
map2 : (a -> b -> result) -> List a -> List b -> List result
map2 f xs ys =
  map2Help f xs ys []


map2Help : (a -> b -> result) -> List a -> List b -> List result -> List result
map2Help f xs ys acc =
  case xs of
    [] ->
      reverse acc

    x :: xrest ->
      case ys of
        [] ->
          reverse acc

        y :: yrest ->
          map2Help f xrest yrest (f x y :: acc)


map3 : (a -> b -> c -> result) -> List a -> List b -> List c -> List result
map3 f xs ys zs =
  map3Help f xs ys zs []


map3Help : (a -> b -> c -> result) -> List a -> List b -> List c -> List result -> List result
map3Help f xs ys zs acc =
  case xs of
    [] -> reverse acc
    x :: xrest ->
      case ys of
        [] -> reverse acc
        y :: yrest ->
          case zs of
            [] -> reverse acc
            z :: zrest -> map3Help f xrest yrest zrest (f x y z :: acc)
```

`map4`/`map5` follow the same shape with one more nested `case` each. Nested `case`s (not
`case ( xs, ys ) of`) so no tuple is constructed for control flow. `reverse` and `cons` are in scope
(same module); `import Elm.Kernel.List` (`List.elm:35`) stays (still used by `cons`,
`List.elm:106-108`). `module List exposing ( … )` (:1-8) is an **explicit** export list, so
`map2Help`/`map3Help`/… are private by construction and no export edit is needed.

**Steps.** (1) Apply the patch through Phase 2A. (2) Gate. (3) In a follow-up commit, run the
deletion policy for `Elm_Kernel_List_map{2,3,4,5}`: `ListExports.cpp:432-590` (`kernelListMapN`) and
:592-637 (the four wrappers), `KernelExports.h:169-172`, `RuntimeSymbols.cpp:696-699`,
`KernelSigs.elm:116-121` (the `("List","map2")` row — after kernel-opt-07 that row lives in
`KernelFacts.elm` keyed `("List","map2")` and `KernelSigs.elm` is a re-export shim; delete it
wherever it currently lives and coordinate with 07 so the facts census stays truthful).
`callUnaryClosure`/`callBinaryClosure`/`listToVectorU64` (`ListExports.cpp:32,:37,:55`) **stay
through Phase 3** — `List_toArray` (:377-380) and the still-live sort exports use them. After
Phase 4 lands, only `listToVectorU64` has a caller left (`:380`); `callUnaryClosure` (:32-35, sole
use `:705`) and `callBinaryClosure` (:37-…, sole use `:790`) go dead and are deleted with the sorts
(`grep -rn 'callUnaryClosure\|callBinaryClosure\|listToVectorU64' elm-kernel-cpp/src/` re-confirms).

**Per-phase acceptance.**
- `callee = @Elm_Kernel_List_map{2,3}` → 0 in the regenerated text module; no *new*
  `"eco.papCreate"`/`"eco.papExtend"` beyond +2% of **your own** Phase-0.1 counts — the mapper
  must be devirtualized into the loop, not turned into a PAP.
- Chunk counters: `rewritten=` ≥ Phase-1 value (mapN's `f x y :: acc` accumulator plus its `reverse`
  are both chunk-eligible; a *drop* means the callback broke the chain — investigate the
  `breaker eco.call` histogram line before shipping).
- E2E: `TEST_FILTER=elm cmake --build build --target full` with `ListMap2FloatTest`,
  `ListMap2FloatSumTest`, `ListMap3FloatTripleSumTest`, `ListMap4FloatAggregateTest`,
  `ListMap5FloatAggregateTest`, `LetNumberMap2Test` green (the Float/`number`-taint cases are the
  risky ones: memory eco-cnumber-constraint-by-name-fragility).
- Heap-validate leg green (this is the bug class the C++ driver existed to prevent).
- Bootstrap: **expect a NEW fixed point** — the JS stages compile Elm-source mapN, so `eco-boot.js`
  changes. Re-establish Stage 4b and Stage 8c fixed points and record that they converge (identical
  at N vs N+1), not that they match the old bytes.

### Phase 4 — `List.sortBy` / `List.sortWith` in Elm (stable merge sort)

Replace `List.elm:484-486` and `:502-504`. Top-down stable merge sort; the merge is tail-recursive
with a `foldl cons` tail-splice — the same accumulator shape the chunk rewriter eats.

`sort xs = sortBy identity xs` (:468-470) is already Elm. **Re-point it at
`sort xs = sortWith compare xs`** in the same patch: semantically identical (`sortWith compare` is
upstream's own stated definition, `List.elm:499-500`), but it skips the decorate/undecorate pass
below and so avoids paying one `Tup2` per element on every `List.sort` call.

**The split does NOT use `take`/`drop`.** v1 claimed it "reuses the kernel `take`/`drop` (still
shunted, still chunk-producing)"; all three clauses are false, and the third is a live correctness
hazard:
- `drop` is **never shunted** — elm/core `drop` compiles to a `MonoTailFunc` TCO form, which
  `listShuntNode` (`Functions.elm:341-357`) declines by shape; the shunt's own doc comment names it
  (`Functions.elm:313-315`) and audit-03:89 restates it. The static census agrees:
  `Elm_Kernel_List_drop` has **zero** occurrences, not even an `is_kernel` stub.
- `ListOps::take` has **no chunk path at all** — it always goes through `listFromUnboxables`
  (audit-03:27, `ListOps.cpp:373-386`). It produces no chunk win.
- Worse, that same always-`listFromUnboxables` path **kind-collapses Float/Char heads to Int**
  (audit-03:85), and the concrete latent defect audit-03 names is literally
  `List.sortBy f (List.take n floatList)`. Routing the new sort's split through kernel `take` would
  bake that hazard into every sort.

So the split is an in-module tail-recursive Elm helper — one traversal, no kernel dependency, and
its `acc` is itself chunk-rewritable:

```elm
{-| `splitHalf n xs []` = (first n of xs, rest). The `reverse acc` keeps the
left run in INPUT order, which is what makes the merge below stable.
-}
splitHalf : Int -> List a -> List a -> ( List a, List a )
splitHalf n list acc =
  if n <= 0 then
    ( reverse acc, list )

  else
    case list of
      [] ->
        ( reverse acc, [] )

      x :: rest ->
        splitHalf (n - 1) rest (x :: acc)


sortWith : (a -> a -> Order) -> List a -> List a
sortWith compareFn list =
  case list of
    [] ->
      list

    [ _ ] ->
      list

    _ ->
      let
        ( left, right ) =
          splitHalf (length list // 2) list []
      in
      mergeSorted compareFn
        (sortWith compareFn left)
        (sortWith compareFn right)


mergeSorted : (a -> a -> Order) -> List a -> List a -> List a
mergeSorted compareFn xs ys =
  mergeHelp compareFn xs ys []


{-| `acc` holds the emitted prefix REVERSED; `foldl cons rest acc` splices it
back in order onto the untouched remainder (reverse acc ++ rest) and is itself
a chunk-rewritable cons accumulation.
-}
mergeHelp : (a -> a -> Order) -> List a -> List a -> List a -> List a
mergeHelp compareFn xs ys acc =
  case xs of
    [] ->
      foldl cons ys acc

    x :: xrest ->
      case ys of
        [] ->
          foldl cons xs acc

        y :: yrest ->
          case compareFn x y of
            GT ->
              mergeHelp compareFn xs yrest (y :: acc)

            _ ->
              -- LT and EQ both take from the LEFT run: this is what makes the
              -- sort stable.
              mergeHelp compareFn xrest ys (x :: acc)


sortBy : (a -> comparable) -> List a -> List a
sortBy toKey list =
  case list of
    [] ->
      list

    [ _ ] ->
      list

    _ ->
      -- Decorate/sort/undecorate: the key function is evaluated exactly ONCE
      -- per element, matching today's C++ key-extraction pass (ListExports.cpp:703-716).
      -- (Upstream elm/core's JS kernel re-evaluates it per comparison; both are
      -- legal for a pure `toKey`, and once-per-element is the cheaper contract.)
      undecorate (sortWith compareKeyed (decorate toKey list [])) []


decorate : (a -> comparable) -> List a -> List ( comparable, a ) -> List ( comparable, a )
decorate toKey list acc =
  case list of
    [] ->
      reverse acc

    x :: rest ->
      decorate toKey rest (( toKey x, x ) :: acc)


compareKeyed : ( comparable, a ) -> ( comparable, a ) -> Order
compareKeyed ( ka, _ ) ( kb, _ ) =
  compare ka kb


undecorate : List ( comparable, a ) -> List a -> List a
undecorate pairs acc =
  case pairs of
    [] ->
      reverse acc

    ( _, x ) :: rest ->
      undecorate rest (x :: acc)
```

**Steps.** (1) Patch `List.elm` through 2A: replace :484-486 (`sortBy`) and :502-504 (`sortWith`),
add the six private helpers (`splitHalf`, `mergeSorted`, `mergeHelp`, `decorate`, `compareKeyed`,
`undecorate`), and change :469-470 to `sort xs =\n  sortWith compare xs`. All six helpers are
private automatically (the `module List exposing ( … )` list at :1-8 is explicit). `length`
(:250-252), `foldl` (:150-157), `reverse` (:259-261) and `cons` (:106-108) are all in scope in the
same module; `compare` and `Order(..)`/`GT` come from `import Basics exposing (..)` (:34).
(2) Gate — the sort suite is unusually good here: `SortCharTest`,
`SortFloatTest`, `ListSortByFloatIdentityTest`, `ListSortWithFloatCompareTest`,
`SortByAlwaysEmptyListKeyTest`, `SortByAlwaysEmptyStringKeyTest`, `SortByDerivedEmptyListTest`,
`SortByDerivedEmptyStringTest`, `SortByEmptyListKeyMixedTest`, `SortByEmptyStringKeyMixedTest`,
`SortByIdentityEmptyListTest`, `SortByIdentityEmptyStringTest`, `SortByTupleWithEmptyListTest`,
`SortByTupleWithEmptyStringTest`, `SortByTupleWithMixedConstantsTest`, `SortEmptyListInListTest`,
`SortEmptyStringInListTest`, `SortWithCompareEmptyListTest`, `SortWithCompareEmptyStringTest`
(all `/work/test/elm/src/`, all 19 verified present 2026-08-10) — precisely the embedded-constant
key cases. Add `SortFloatTest` / `ListSortByFloatIdentityTest` to the *must-read* list: they are the
kind-collapse canaries for the `take`-free split above. (3) Deletion commit:
`ListExports.cpp:677-808` (plus the now-dead `callUnaryClosure` :32-35 / `callBinaryClosure` :37-…),
`KernelExports.h:173-174`, `RuntimeSymbols.cpp:700-701`, `KernelSigs.elm:122-131` (or the
`KernelFacts.elm` rows post-kernel-opt-07).

**Ordering-divergence decision (state it before running, not after).** **Expected divergence: none.**
Today's `sortBy` reaches `Utils::cmp` with `nullptr` for embedded constants
(`ListExports.cpp:730-733`), and `cmp` (`Utils.cpp:302-306`) answers `0` for `!a && !b` *before* the
`!a`/`!b` arms — so two constant keys already compare EQ and `std::stable_sort`'s strict-weak-order
precondition holds. The Elm merge sort's `compare` reaches the *same* `cmp` with the *same*
`nullptr`s, because `Elm_Kernel_Utils_compare` (`UtilsExports.cpp:13-16`) resolves through
`Export::toPtr` (`ExportHelpers.hpp:47-56`), which maps embedded constants to `nullptr`. Both sorts
are stable. So the constant-key suite above is a **regression gate, not a change gate** — it should
stay green unchanged, and any movement in it is a bug in the new Elm code, not an expected
"fix-forward".
**If a divergence nonetheless appears, the policy is still fix-forward:** the Elm answer is the
reference; update the affected `-- CHECK:` line with the diff quoted in the commit message and
re-establish a **new** bootstrap fixed point. Do not "match observed" C++ output. (The JS stages use
stock `_Utils_cmp` + a stable JS sort, so a Stage-8c-only divergence would point at the JS/native
constant representation gap, not at the sort algorithm.)

**Per-phase acceptance.**
- `callee = @Elm_Kernel_List_sort{By,With}` → 0.
- The 19 `Sort*` E2E tests green **without expectation edits** (see the decision above).
- Comparator visible to LSS: `benchmarks/dispatch-census.sh` (see `ECO_DISPATCH_STATS=1` usage at
  its header) shows the comparator rows moving from `sat`/`gen` into `fast` (statically-stamped
  `$cap` calls) — this is the *reach* claim; if it does not materialize, the phase has bought only
  hazard/C++ deletion and the stop rule counts it.
- Wall: honestly expected FLAT; the accepted payment is hazard deletion + ~130 lines of hand-rolled
  GC-discipline C++ retired + comparator visibility. **Not** UB retirement — there is no UB (above).
- Code size: record `size build/compiler/build-kernel/bin/eco-compiler` — sortWith specializes per
  comparator lambda set; a >2% `.text` growth is a reportable regression (mono code-size trap).

### Phase 5 (LATER — outline only, separately gated) — JsArray folds/init

~676 static sites; `JsArray_foldl` 1.62M dynamic. Primitives are the already-inline
`eco.array.get/set/length`. `initialize*` additionally needs a mutable-fresh-array idiom
(clone-based `ArraySetOpLowering` already optimizes refcount-1 fresh arrays — verify at design time).
Gets its own plan and its own gates once Phases 1–4 have reported. **Do not** start it before the
stop rule has been evaluated.

### Phase 6 (LATER — outline only, BLOCKED) — String HOFs

`String_{map,filter,any,all,foldl,foldr}`, ~40 static sites, `String_map` 832 dynamic (cold —
justified by hazard deletion, not heat). Today each char crosses the closure boundary *and* the
kernel snapshots the whole string first (`StringExports.cpp:220-233` — doc comment :220-224, body
`snapshotChars` :225-233 — used by `map` :251-252, `filter` :269-270, `any` :287-288, `all`
:305-306, `foldl` :324-325, `foldr` :340-341) — even `any`, which may exit at index 0.

**Hard preconditions (checklist, anchors re-verified 2026-08-10 — the design doc's B7 anchors have
drifted):**
1. kernel-opt-04 lands `eco.string.code_unit_at`.
2. `toInt "+5"` → `Nothing` (should be `Just 5`): `runtime/src/allocator/StringOps.hpp:1132-1149`
   (`std::from_chars` rejects a leading `+`) — doc said `:1145`.
3. `toFloat` accepts leading whitespace and `0x…`: `StringOps.hpp:1155-1179` (`std::strtod`) — doc
   said `:1174`.
4. `indexes "" s` → `[0..n]`: `StringOps.cpp:778`.
5. `reverse` corrupts surrogate pairs: `StringOps.hpp:838-880` — doc said `StringOps.cpp:780-804`.

Fixing these AFTER an Elm rewrite means writing the reference semantics twice; the ordering is a
hard precondition, not a preference.

### Kernel-symbol deletion policy (applies to every phase)

A kernel symbol may be deleted **only when direct and papCreate counts are BOTH zero across the full
built corpus**, and no in-runtime C++ caller remains:

**Step 0 — make the corpus greppable, or the check silently lies.** The E2E harness emits
**bytecode** `.mlir` by default: `getTextMlirFlag()` (`test/TestSuite.hpp:20-26`) returns
`" --text-mlir"` only when `ECO_TEXT_MLIR` is set and non-`0`, and `ElmE2ETestBase.hpp:465` appends
it to the compile command. Running the `callee = @…` greps below over the default (bytecode) corpus
returns **0 for every symbol**, i.e. a false "deletable" verdict. Regenerate the corpus as text
first — 861 modules under `/work/build/test/*/eco-stuff/mlir/` on a warm tree:

```bash
ECO_TEXT_MLIR=1 cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

```bash
# 1. corpus: every text-MLIR module the tree can produce (regenerate per Phase 0.1 after the change,
#    and per Step 0 for the E2E half). Substitute the symbol under test for map2.
for f in /tmp/eco-compiler.txt.mlir /work/build/test/*/eco-stuff/mlir/*.mlir; do
  grep -H -c "callee = @Elm_Kernel_List_map2\b"   "$f"
  grep -H -c "function = @Elm_Kernel_List_map2\b" "$f"
done | awk -F: '{s+=$NF} END {print "total refs:", s}'

# 1b. bytecode fallback if Step 0 was skipped — presence-only, NEVER a count:
#     any hit here means "not deletable"; zero hits are NOT proof of deletability.
strings -a /work/build/test/*/eco-stuff/mlir/*.mlir | grep -o 'Elm_Kernel_List_[A-Za-z0-9_]*' \
  | sort | uniq -c

# 2. no in-runtime caller of the underlying implementation
grep -rn 'ListOps::reverse\|kernelListMapN' /work/runtime/src /work/elm-kernel-cpp/src /work/eco-kernel-cpp/src
```

Registration points to remove, in this order (verified 2026-08-10 against how `elm_array_push_int`
is wired end-to-end: definition `elm-kernel-cpp/src/core/JsArrayExports.cpp:745`, decl
`elm-kernel-cpp/src/KernelExports.h:281`, emitter factory
`runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:1015` — note the `Passes/` segment, absent in v1 —
JIT map `runtime/src/codegen/RuntimeSymbols.cpp:767`, macro `KERNEL_SYM` :583-587):
1. `elm-kernel-cpp/src/core/ListExports.cpp` — the `extern "C"` definition (and any helper that
   becomes unreferenced; after Phase 4 that is `callUnaryClosure` :32-35 and `callBinaryClosure`
   :37-…, but **not** `listToVectorU64` :55, still used by `List_toArray` :380).
2. `elm-kernel-cpp/src/KernelExports.h` — the declaration.
3. `runtime/src/codegen/RuntimeSymbols.cpp` — the `KERNEL_SYM(...)` entry, **if present**: the HOF
   kernels are there (:696-701) but the Tier-B shunt symbols (`reverse`/`append`/`concat`/`take`/
   `drop`) are **not** — confirmed by
   `grep -rn 'Elm_Kernel_List_reverse\|Elm_Kernel_List_take' runtime/ elm-kernel-cpp/`, which hits
   only `KernelExports.h` + `ListExports.cpp`. That map is JIT-only.
4. `compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` — the `(home, name)` row **pre**
   kernel-opt-07; **post**-07 the row lives in `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`
   under the same `(home, name)` key and `KernelSigs.elm` is a thin re-export shim with no rows.
   Delete wherever it lives; unlisted kernels keep today's behavior per consumer (whitelist
   discipline), so removal is safe by construction.
5. No `EcoToLLVMRuntime.cpp` `getOrCreateFunc` entry exists for these — they are emitted as
   `eco.call`s from `listShuntCall`/normal kernel calls, so there is nothing to remove there
   (`grep -rn 'Elm_Kernel_List' runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` → no hits).

**Do NOT shortcut the corpus check on `map4`/`map5`.** v1 said they "have zero occurrences … and are
deletable on the corpus check alone". They have zero occurrences *in the self-compile module* — but
the self-compile module is not the corpus, and the E2E half **does** reference them:

```
$ strings -a build/test/elm/eco-stuff/mlir/ListMap4FloatAggregateTest.mlir \
    | grep -o 'Elm_Kernel_List_map[0-9]'
Elm_Kernel_List_map4
```

`test/elm/src/ListMap4FloatAggregateTest.elm:16` and `ListMap5FloatAggregateTest.elm:16` call
`List.map4`/`List.map5` directly. So `map4`/`map5` become deletable only *after* Phase 3's Elm
bodies land and the corpus is re-measured; deleting them on the self-compile count alone breaks the
E2E build. `drop` is the only symbol genuinely at zero everywhere (it is never shunted — see
§Traps), and even it must pass step 1 over the regenerated text corpus before deletion.

### Stop rule

If two consecutive migrations measure flat wall AND buy no downstream reach (no movement in chunk
counters, no comparator/mapper rows moving into `fast` in the dispatch census, no borrow/CSE counter
change), stop the track and leave the remaining phases unstarted.

## Traps & risks

- **Chunk-representation loss** — `concat` STAYS C++: non-tail-recursive in its natural Elm form
  (`concat = foldr append []`) and genuinely loses the chunk representation (audit-03:91; §5b
  precondition 3). Every phase re-checks the chunk counters, not just Phase 1.
- **`take` kind-collapse (live latent defect, do NOT build on it)** — `ListOps::take` has no chunk
  path and always routes through `listFromUnboxables`, whose `bool is_boxed` maps head kinds to
  {0,1} only, so Float/Char heads are re-tagged **Int** (audit-03:27 and :85,
  `ListOps.cpp:373-386`, `HeapHelpers.hpp:650`). audit-03's named victim is
  `List.sortBy f (List.take n floatList)`. Never place kernel `take` inside a migrated combinator
  (this is why Phase 4 uses an in-module `splitHalf`), and treat `SortFloatTest` /
  `ListSortByFloatIdentityTest` as the canaries.
- **`drop` is not shunted** — elm/core `drop` compiles to `MonoTailFunc`, which `listShuntNode`
  declines (`Functions.elm:313-315` doc, :341-357 guard; audit-03:89). Zero
  `Elm_Kernel_List_drop` occurrences in the corpus. Any plan step that assumes a "kernel drop"
  is wrong.
- **Stale package caches** — package artifacts are fingerprinted by dependency *versions*, not source
  (`Fingerprint = Dict Pkg.Name V.Version`, `Details.elm:1078-1079`; consulted :1004-1015 /
  :1022-1033), so a source edit is invisible until `artifacts.dat` +
  `typed-artifacts.dat` are deleted (elm/core in `~/.eco`, eco/kernel in-tree at
  `/work/eco-kernel-cpp/*.dat`, `compiler/CMakeLists.txt:259-271`). Kernel `.elm` signature edits
  additionally need `rm -rf ~/.eco/0.1.0/packages/eco/kernel` (signatures live in 3 synced places;
  memory: eco-local-package-stale-stage-cache), and kernel `.js` edits need the seed-cache nuke.
- **E2E harness mtime cache** — `ElmE2ETestBase.hpp:432` (`needsRecompile`, consulted at :457 and
  :520) skips recompiles by `.elm` mtime; a
  package-source change is invisible to it. `--target full` cleans `build/test/*/eco-stuff`, but any
  non-`full` run must `touch` the test sources (memory: eco-lss-design "harness cache env-blind").
- **Stale .mlir** — E2E must use `--target full`, never `check`.
- **GC-trigger lottery** — every wall A/B records major-GC counts (standing gate).
- **Sort-order identity** — design-doc Appendix B6 (`kernel-boundary-reduction.md:2271`) claims a
  strict-weak-ordering UB here; **it is wrong** (`Utils.cpp:304`'s `!a && !b ⇒ 0` arm precedes the
  `!a` arm, and Elm-level `compare` reaches the same `cmp` with the same `nullptr`s via
  `Export::toPtr`). No divergence is expected, the 19 `Sort*` tests are a *regression* gate, and
  "UB retirement" must not be booked as a payment. Fix-forward remains the policy if a divergence
  nonetheless appears. B6 itself should be corrected in the design doc under kernel-opt-07's
  evidence-anchor pass.
- **Mono code-size / spec growth** — Elm-source HOFs specialize per instantiation where the C++
  kernel was one symbol; `sortWith` is recursive *and* closure-taking. Watch `.text` size and mono
  time; the poly-rec watchdog concerns of memory:alm-optimization-survey apply to the *recursive*
  sort, and `ECO_MONO_VALIDATE=1` is a cheap extra check on the migration build.
- **Interim hybrids** — any partial mapN migration must not reintroduce the stale-cursor hazard the
  C++ driver exists to prevent; migrate a symbol whole or not at all.
- **Vendored-core drift** (2B) — an in-repo elm/core fork must record its upstream base and delta,
  or the next `elm/core` bump silently loses the migration.
- **elm-tests do NOT cover this** — `cmake --build build --target elm-tests`
  (`compiler/CMakeLists.txt:178-186`) runs elm-test-rs `--project ${BUILD_XHR_DIR}` and `DEPENDS
  guida`, i.e. the Stage-1 artifact built with **stock elm** against the `~/.elm` cache (:154-162),
  so it is blind to a patched `~/.eco` elm/core. The JIT E2E suite is the gate that sees it: it
  compiles each test through Stage 1's `compiler/bin/index.js`, which runs eco's Builder and
  therefore reads `~/.eco` for the *test programs'* packages (`CMakeLists.txt:1105-1120`). Corollary
  for Phases 3/4: Stage 1 itself keeps compiling against unpatched core, so the bootstrap delta
  starts at Stage 2 — which is exactly why the gate is convergence to a NEW fixed point.
- **B7 bake-in** (Phase 6) — the divergence fixes must precede the rewrite.

## Dependencies

- **kernel-opt-01** (list-cons/construct-list): shares the EcoListTemplate chunk-counter parity gate;
  the two plans quote the *same* counters (`ECO_LIST_TEMPLATE_DEBUG` `rewritten=`,
  `unwind rewritten=`, `consRoots`, `headTy` — kernel-opt-01:100-114) — see the reconciliation note
  in Phase 0.2. Note kernel-opt-01's contingency B relaxes `getLiveRoots().empty()` in
  `EcoListTemplate.cpp`; if that lands first, re-baseline `rewritten=` before Phase 1's hard gate.
- **kernel-opt-04** → HARD blocker for Phase 6 (String HOFs need `eco.string.code_unit_at`).
- **kernel-opt-05** (typed append): enables the trivial `String_cons` = `String.fromChar c ++ str`
  migration (68 sites, audit-02) as a Phase-6 rider — not attempted before it.
- **kernel-opt-07** (KernelFacts): migrated symbols leave the facts table — coordinate row deletion.
  Pre-07 the rows are `KernelSigs.elm:116-131`; post-07 the canonical table is
  `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` keyed `(home, name)` and `KernelSigs.elm` is a
  thin re-export shim (so `Constrain.elm` / `LssFacts.elm` stay untouched) — delete the rows from
  `KernelFacts.elm`, not from the shim. `mapN`/`sortBy`/`sortWith` are `callsBackIntoElm = True`
  today, so they are not `gcLeafEligible` and carry no `eco.gc_leaf` decl attr; deleting them
  therefore has **no** interaction with kernel-opt-08's LLVM stamp or kernel-opt-09's
  `eco.callee_gc_leaf` call-local marking. `Elm_Kernel_List_reverse` likewise stays absent from any
  gc-leaf whitelist while Phase 1 is flag-off.
- **kernel-opt-10/13** (CSE/folders): not blockers, but the compounding this plan promises is
  realized through them; cite their counters in per-phase reports.
- External: B7 string-divergence fixes (Phase 6 precondition); Phases 1, 3 and 4 are unblocked today
  (Phase 3/4 need only the Phase-2A overlay, which is a shell procedure, not code).

## Expected impact

Honest: per-element work here is closure-apply-bound, and the 4×-measured lesson says boundary
metadata removal alone is wall-FLAT. **Phase 1 (reverse) is the best direct-wall candidate** — it is
not a HOF, it deletes 42.8M kernel calls/run and 468 opaque one-call bodies, and if chunk parity
holds it regains inliner/LSS/borrow visibility into 1700 call sites at no representation cost;
it is also the cheapest phase (a config-gated one-line lookup guard). **Phase 3** deletes real
per-element re-rooting work AND a use-after-GC hazard class (~160 lines of the most dangerous C++ in
the kernel). **Phase 4** is honestly expected wall-FLAT and is bought for hazard deletion (~130
lines of hand-rolled index-sort + range-rooting C++), removal of the `take` kind-collapse exposure
from the sort path, and comparator visibility to LSS — **not** for UB retirement, which the tree
shows does not exist (see the corrected B6 note in §Evidence). It may also cost allocation (the
`sortBy` decorate pass builds n Tup2s where C++ used a `std::vector`; re-pointing `sort` at
`sortWith compare` keeps identity-key sorts out of that cost — budget it and measure, since wall
tracks retention).
The durable payoff claimed is COMPOUNDING: every kernel-opt improvement (cons chunks, CSE, purity,
borrow) now reaches through loops it previously could not see — measure that reach in counters, per
symbol, and let the stop rule bite if it never materializes.

## Gates

Per symbol, all of:

1. **Full E2E** — `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, then
   `grep -E "FAILED|failed|Assertion" /tmp/test_output.txt` and the pass-count tail
   (`tail -20 /tmp/test_output.txt`). Run ONCE; re-read the file, never re-run.
   Phase-scoped subset while iterating: `TEST_FILTER=elm cmake --build build --target full`.
2. **Heap-validate suite** — `cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON` then
   `cmake --build /work/build-val --target full 2>&1 | tee /tmp/validate_output.txt`
   (the mapN driver's bug class was found exactly this way).
3. **Self-host bootstrap** — `cmake --build build --target bootstrap`. Phase 1 (flag ON) must be
   byte-identical at the fixed point; Phases 3/4 legitimately change compiler output, so the gate is
   **convergence to a NEW fixed point** (Stage 4b JS and Stage 8c native both stable at N vs N+1),
   with the delta reviewed and quoted in the commit message.
4. **Wall A/B with major-GC counts** — `benchmarks/kernel-opt.md` protocol verbatim (2 rounds,
   reversed arm order in round 2, cold `eco-stuff`, `ECO_MONO_ENGINE=subst` workload); record
   `Objects/Bytes allocated`, `Minor GC cycles`, `Objects promoted`, `Major GC cycles`,
   `Total GC/Alloc time`, output `.mlir` size. Deltas <3% are FLAT — write "no regression detected".
5. **EcoListTemplate chunk parity** (list ops) — `ECO_LIST_TEMPLATE_DEBUG=1` per Phase 0.2:
   `rewritten=` ≥ 443 and `unwind rewritten=` ≥ 38 **and `consRoots` unchanged (0)** (2026-08-10
   baselines, reproduced during this plan's verification pass), plus the objdump scratch census on
   the LINKED binary as a cross-check
   (`mark=53 push_boxed=71 push_scalar=16 finish=70 finish_fwd=90`).
6. **Per-symbol census delta** — the migrated symbol's `callee = @…`/`function = @…` counts at 0 in
   the regenerated text module; no compensating growth beyond +2% in `"eco.papCreate"`,
   `"eco.papExtend"` or `"eco.call"` **relative to your own Phase-0 numbers** (the 2026-08-10 values
   29382 / 43755 / 100079 are config-sensitive and are a sanity check, not the band); and, where the
   phase claims LSS reach, the
   dispatch census (`ECO_DISPATCH_STATS=1` + `benchmarks/dispatch-census.sh`) showing the callback
   moving from `sat`/`gen` into `fast`.
