# Kernel-Opt 07: KernelFacts table + Utils_equal purity fixes

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1; v3 = adversarial
verification pass — every load-bearing anchor re-opened in the tree, 22 drifts corrected, the
`Utils_equal`/`notEqual` export path re-rooted at `UtilsExports.cpp`, the `Basics_*` ledger rows
given the `evidence` strings validation rule V1 demands, the `ECO_HEAP_VALIDATE` gate corrected from
"env var" to "configure-time CMake option", and the `gcLeafEligible` arity clash with kernel-opt-08
resolved by pinning key-form `…For` wrappers.)
Derived from design_docs/kernel-boundary-reduction.md §6.B (contradiction table, :1219-1254), §6.C1
(normative schema, :1259-1315), §6.E (seed classification, :1517-1579), §6.F R1/R2/R8 (:1601-1608),
§A6 (divergence ledger, :1172-1198; the derived-facts paragraph it is usually cited for is actually
in §A7, :1209-1215), §6.D1 (proposed invariant, :1448-1452); static census
design_docs/kernel-boundary/callsite-census-self-compile.txt (17,005 sites / 130 symbols); dynamic
census design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt (3,676,097,627 calls / 98 symbols).

## Goal

Replace the compiler's three mutually contradictory kernel effect models with ONE audited table:
add `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` (keyed `(home, name)`), demote
`Borrow/KernelSigs.elm` to a thin shim so `Constrain.elm` / `LssFacts.elm` compile byte-unchanged,
seed the table with the §6.E rows + the existing 33 borrow rows + the A6 divergence ledger, and
delete the `Utils_equal` stderr trace that is today the only live counterexample to "non-Debug
kernels are call-time-effect-free". This is the enabling simplification for kernel-opt-03/08/11/12/13
— **it moves no wall on its own and does not claim to.**

## Files touched

| file | change |
|---|---|
| `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` | **NEW** (~440 lines): types, `unaudited`/`auditedPure` bases, **52-row** table (48 kernel rows + 4 `Basics_*` divergence-ledger rows), `lookup`, `lookupSymbol`, record-form derived facts, key-form `…For` wrappers, `validationErrors` |
| `compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` | **REWRITTEN** 177 → ~55 lines: shim (`ParamMode(..)`, `KernelSig`, `lookup`); table + row comments move to KernelFacts |
| `compiler/tests/Compiler/GlobalOpt/KernelFactsTest.elm` | **NEW**: 7 suites (validation, gc-leaf golden set, borrow-shim golden 33, no-extra-borrow-rows, `lookupSymbol`, key-form helpers, row-count/no-duplicates) |
| `elm-kernel-cpp/src/core/Utils.cpp` | **DELETE** lines 557-562 (the `[eq] tag mismatch` fprintf + non-atomic `static int traceCount`) |
| `design_docs/invariants.csv` | **NO EDIT here.** Final `KERNEL_FACTS_001` row text is produced in Phase 6 and lands with kernel-opt-08 (§6.F R7) |
| `compiler/src/Compiler/GlobalOpt/Borrow/Constrain.elm` | **UNCHANGED** (verified: `import … as KernelSigs` :26 — no `exposing` list — then only `KernelSigs.lookup` :884, `KernelSigs.KernelSig` :1078, `KernelSigs.ParamMode` :1101, `KernelSigs.PBorrowed`/`POwned` :1108/:1111) |
| `compiler/src/Compiler/GlobalOpt/Borrow/LssFacts.elm` | **UNCHANGED** (verified: `import … as KernelSigs` :26 — no `exposing` list — then `KernelSigs.lookup` :244, `KernelSigs.KernelSig` :307, `KernelSigs.ParamMode` :356, ctors :359/:362) |
| — | **Whole-tree check:** `grep -rln KernelSigs compiler/src compiler/tests` returns exactly `Borrow.elm` (prose mention only, :12), `Borrow/Constrain.elm`, `Borrow/LssFacts.elm`, `Borrow/KernelSigs.elm`. There is no fifth importer and no test currently imports it. |
| build system | **RECONFIGURE REQUIRED**: `ELM_SOURCES` is a configure-time `file(GLOB_RECURSE …)` over `${COMPILER_DIR}/src/*.elm` + `src-xhr/*.elm` (compiler/CMakeLists.txt:126-129), so the new `src/…/KernelFacts.elm` needs `cmake --preset build` before `cmake --build build` — see [[eco-cmake-preset-and-glob-reconfigure]]. (The glob does **not** cover `compiler/tests/`, so the new test module needs no reconfigure of its own; `build-xhr/tests` is a configure-time dir link, compiler/CMakeLists.txt:119, and elm-test-rs walks it at run time. Reconfiguring once covers both.) |

No new C++ export. Registration checklist confirmed unnecessary by reading how `elm_array_push_int`
is wired — `elm-kernel-cpp/src/KernelExports.h:281` (decl) + `JsArrayExports.cpp:745` (defn) +
`runtime/src/codegen/RuntimeSymbols.cpp:767` (`KERNEL_SYM`) + `Passes/EcoToLLVMRuntime.cpp:1015`
(`getOrCreateFunc`) — **none of these four files is touched**; the only C++ edit is a deletion inside
an existing function body.

## Flag & rollback

- **No Config.elm flag, deliberately.** The Elm side is *inert data*: nothing outside the shim reads
  `KernelFacts` until kernel-opt-08/11/12/13 wire consumers, and the shim is proven behaviour-identical
  by the Phase 4 golden test (all 33 legacy keys → identical `KernelSig`; every other key → `Nothing`,
  census counters included). A flag over inert data would be noise. **Because there is no flag, the
  gate bar is higher**: the borrow-identity census diff (G5) + the bootstrap fixed point (G4) +
  `out.mlir` byte-identity (G5's second diff) carry the weight a flag would normally carry.
- **The one behaviour change is the C++ fprintf deletion.** Named rollback = **`git revert` of the
  `elm-kernel-cpp/src/core/Utils.cpp` hunk alone** (the Elm side is independent of it and stays).
  Full rollback of the whole plan, from the merge commit `<sha>`:
  ```bash
  cd /work
  git checkout "$sha^" -- compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm \
                          elm-kernel-cpp/src/core/Utils.cpp
  git rm -f compiler/src/Compiler/GlobalOpt/KernelFacts.elm \
            compiler/tests/Compiler/GlobalOpt/KernelFactsTest.elm
  cmake --preset build          # the GLOB_RECURSE must forget the deleted .elm
  ```
  There is no runtime or compiler flag to flip because there is nothing gated: see the bullet above.
- **Rejected alternative:** keeping the trace behind `#ifndef NDEBUG` + a `std::atomic<int>`. Rejected
  because it makes `(Utils, equal)`'s `callTimeEffect` *build-configuration dependent* — the dev
  preset would carry `EffObservableIO` while release carries `EffNone`, so the compiler's table would
  describe a runtime it isn't linked against. The row must be `EffNone` in ALL builds or not at all.
- Downstream kill switches live with their consumers: kernel-opt-08's **pair** —
  `EcoConfig.kernelGcLeaf` (`eco-config.json` `"kernelGcLeaf"`, env `ECO_KERNEL_GCLEAF_EMIT=1|0`,
  artifact-affecting hash token `kgcl=1`) for emission and `ECO_KERNEL_GCLEAF=0` for the backend
  honouring of the attr; `ECO_LOWERING_VALIDATION`-gated relaxation (kernel-opt-09);
  `Compiler/Eco/Config.elm` record flags plus their `Builder/Eco/Config.elm` env parsers
  (kernel-opt-11/12/13, e.g. 12's `callPurityAttrs` / `ECO_CALL_PURITY=1`, hash token `cpur`).
  Note there is **no** `compiler/src/Compiler/Config.elm` — the two real modules are
  `compiler/src/Compiler/Eco/Config.elm` (the record + `Config.hash` tokens, `lchunks=1` at :682)
  and `compiler/src/Builder/Eco/Config.elm` (env-var reads, `ECO_BORROW` at :212).

## Evidence

Three simultaneous, contradictory models (§6.B; every row re-verified in the tree 2026-08-10):

- **(a) All kernels impure** — `MonoInlineSimplify.isPureExpr`: `MonoVarKernel -> False`
  (MonoInlineSimplify.elm:5114-5116, verified), `MonoCall -> False` (:5131-5133, verified); blocks the
  dead-binding gate at :4780 and partial-forwarding at :3477/:3499. Sound, maximally conservative.
- **(b) All non-Debug kernels pure** — `CafHoist`'s ENTIRE effect model is
  `{ leafInfo | hasDebug = home == "Debug" }` (CafHoist.elm:393, consumer at :347); `CafDedupe` merges
  structurally equal `MonoDefine` specs with NO purity check at all (CafDedupe.elm:92-119). Both
  unsound-optimistic, both default-off:
  `cafMemo = { enabled = True, census = False, dedupe = False, hoist = { enabled = False, … } }`
  at **compiler/src/Compiler/Eco/Config.elm:321** (note: the path is `Compiler/Eco/Config.elm`, not
  `Compiler/Config.elm`).
- **(c) The one audited table** — `Borrow/KernelSigs.elm`: 33 rows, aliasing axis only,
  whitelist-disciplined "unknown ⇒ owned" (KernelSigs.elm:14-16, verified). Consumed by
  Constrain.elm:883-908 and LssFacts.elm:242-249.

The optimistic side is falsified by the code TODAY. `Utils_equal`'s tag-mismatch path writes to stderr
behind a non-atomic `static int traceCount` — an observable side effect AND a UB data race inside the
function every `==` funnels through. **Verified in the current tree at Utils.cpp:557-562** (the
design doc's `:550-555` — §6.E row 4 and §6.F R2; §5 R1 says `:550-556` — has drifted +7 via the
HEAP_039 cross-form insertion at `:549-556`, i.e. the four comment lines plus the `isListNode`
arm):

Byte-exact transcription of `elm-kernel-cpp/src/core/Utils.cpp:553-564` (inside `eqHelp`,
which spans `:521-740`); lines 557-562 are the whole deletion:

```cpp
553    if (tagA != tagB) {
554        if (isListNode(a) && isListNode(b)) {
555            return eqListHybrid(a, b, depth);
556        }
557        // TRACE: log tag mismatches to stderr for debugging.
558        static int traceCount = 0;
559        if (traceCount < 10) {
560            fprintf(stderr, "[eq] tag mismatch: %d vs %d\n", (int)tagA, (int)tagB);
561            traceCount++;
562        }
563        return false;
564    }
```

**The export path matters and had drifted in every prior write-up.**
`Elm_Kernel_Utils_equal` is **not** `Utils::equal`: the extern is
`UtilsExports.cpp:107-109`, which calls `equalRespectingConstants` (`:94-105`) — an
embedded-constant word-compare guard — and only then `Utils::equal`
(`Utils.cpp:470-472`) → `eqHelp` (`:521-740`) → this trace. `Elm_Kernel_Utils_notEqual`
(`UtilsExports.cpp:111-113`) is `!equalRespectingConstants(...)` and therefore inherits the
trace the same way; the namespace function `Utils::notEqual` (`Utils.cpp:805-807`) has **no
callers at all** (`grep -rn notEqual elm-kernel-cpp/src runtime/src` finds only its
definition, its `Utils.hpp:61` declaration, and an unrelated comment), so it is *not* the
evidence anchor for the `(Utils, notEqual)` row. `lt`/`le`/`gt`/`ge` DO route through the
namespace functions (`UtilsExports.cpp:115-117/:119-121/:123-125/:127-129` →
`Utils.cpp:809-811/:813-815/:817-819/:821-823`).

If CafHoist+CafDedupe were enabled, hoisting/merging `Utils.equal` calls changes how many trace lines
a program emits (`home == "Utils" /= "Debug"`).

Scale (dynamic, Stage 7a): `Elm_Kernel_Utils_compare` 1,954,920,276 calls (53.2% of 3.676B),
`Elm_Kernel_Utils_equal` 282,801,940 (7.69%), `Elm_Kernel_Utils_notEqual` 4,155,093,
`Elm_Kernel_String_length` 75,588,290, `Elm_Kernel_Bytes_getStringWidth` 1,673,190. Static:
`Utils_equal` 1,357 sites, `Utils_compare` 296, the §6.E stampable 14 ≈ 2,866 sites (16.9% of 17,005).

`computeCost` also prices every kernel callee at flat 1 (MonoInlineSimplify.elm:1230-1231, verified) —
deliberately NOT given an axis in v1 (§6.C1: a cost model needs measurement, not audit); the module
carries a `-- TODO cost axis` note only.

## Approach

### Phase 0 — anchor refresh + the anchor linter (DONE for the seed; keep the tool)

The §6.E anchors were re-verified against C++ on 2026-08-09 and **have already drifted again**. All
drifts found on 2026-08-10 are folded into the Phase 3 table below; the ones that matter:

| symbol / fact | doc or KernelSigs said | tree says (2026-08-10) |
|---|---|---|
| `Utils_equal` stderr trace | `Utils.cpp:550-555` | **`:557-562`** |
| `Utils_equal` depth cap | `Utils.cpp:560-562` | **`:566-569`** |
| `Utils_append` body / silent fallback | `Utils.cpp:822-846` / `:844-845` | **`:829-853` / `:851-852`** |
| `Utils_notEqual` / `lt` / `le,gt,ge` | `:798-800` / `:802-804` / `:806-816` | **`:805-807` / `:809-811` / `:813-823`** |
| `dictEq` | `Utils.cpp:746-796` | **`:753-803`** |
| `List_sortBy` / `sortWith` | `ListExports.cpp:604` / `:678` | **`:677` / `:751`** |
| `List_map2` (KernelSigs comment) | `ListExports.cpp:557` → `kernelListMapN:402` | **`:592` → `:432`** (the §6.E row was right) |
| `String_uncons` impl | `StringOps.cpp:1055` | **`:1009`** |
| `String_words` impl | `String.cpp:293` | **`:286`** |
| `ListOps::append` | `ListOps.cpp:274` | **`:262`** |
| `Bytes_encode` / `decode` | `BytesExports.cpp:397` / `:420` | **`:395` / `:418`** |
| `alloc::ListCursor` | `HeapHelpers.hpp:812-821` | **`:822`** (`RootedListCursor` at `:754`) |
| `Crash_crash` symbol | `Elm_Kernel_Crash_crash` | **`Eco_Kernel_Crash_crash`** (eco-kernel-cpp/src/eco/CrashExports.cpp:9-11 → Crash.cpp:20-33, exact) |
| `eqHelp` extent | `Utils.cpp:463-733` (§6.E row 4) | **`:521-740`** (`:742` is the `dictEq` doc comment) |
| `StringOps::equal` extent | `StringOps.hpp:1486-1543` | **`:1486-1533`** (`:1535-1543` is `compare`'s doc comment; §6.E's `:1486-1533` was right) |
| `Utils::compare` vs `cmp` | one range `Utils.cpp:302-461` | **`cmp :302-445`, `compare :451-457`** (`:459-461` is `cmp3`'s comment) |
| **export entry** for `equal`/`notEqual` | (implied `Utils.cpp`) | **`UtilsExports.cpp:107-109` / `:111-113` → `equalRespectingConstants :94-105`**; `Utils::notEqual` (`Utils.cpp:805-807`) is **uncalled** |
| Order-singleton allocation | `Utils.cpp:35-39` (§6.E) / `:35-49` | **`initOrderSingletons :33-45`** (roots `:41-43`); sole caller `UtilsExports.cpp:186-188` |
| `JsArray_empty` extent | `JsArrayExports.cpp:192-202` | **`:192-195`** (`:197-202` is `singleton`) |
| `String_slice` export extent | `StringExports.cpp:56-69` | **`:56-59`** (`:61-69` is `split`/`lines`) |
| `List_sortBy` SWO comparator | `ListExports.cpp:730-736` (§6.E) | **`:722-736`** (the whole `stable_sort` lambda) |
| `JsArray_initialize{,FromList}` base body | `:948` / `:982` (the `_Int` variants) | **`:422` / `:457-461`** are the BASE exports the Mono key names; `:948`/`:982` are the ABI variants |

Anchors confirmed UNDRIFTED (each opened 2026-08-10): all of
`runtime/src/allocator/StringOps.hpp` (`length:239`, `charAt:410`, `append:477`, `contains:645`,
`startsWith:688`, `endsWith:719`, `toUpper:762`, `toLower:801`, `trim:878`, `cons:1241-1270`,
`equal:1486`, `compare:1544`), `StringOps.cpp:307-473` (`slice`; identity `:321`, views
`:337`/`:415`) and `StringOps.cpp:1009` (`uncons`), `HeapHelpers.hpp:196/630`,
`ListExports.cpp:276-283/592/651-654/677/751`, `ListOps.cpp:530`,
`SchedulerExports.cpp:16/23/30/39`, `runtime/src/platform/Scheduler.cpp:123/139/149/154`,
`BytesExports.cpp:299-301/309-366/330-338/469-471/539-547`,
`JsArrayExports.cpp:204/210-223/463/576/636-640/651/655/948/982`,
`Basics.cpp:40-42/88-90/92-103/105-107`,
`EcoToLLVMArith.cpp:57-81/83-131/324-337`, `Utils.cpp:214-217/302`,
`MVarExports.cpp:30-32/38-46`, `MVar.cpp:264/290`, `DebugExports.cpp:26/56`.
**Nothing in the Phase 3 table is doc-sourced-unverified any more** — the earlier `(d)`
markings on `foldImpl :576`, `:638`, `StringOps.cpp:307-473` and `StringOps.hpp:1241-1270`
were all opened and confirmed, so the marking is dropped.

**Adversarial note kept for D3:** `ListExports.cpp:718` still comments “`Utils::compare` may
allocate (Order Custom)”. It cannot: `compare` (`Utils.cpp:451-457`) selects one of three
**pre-allocated** singletons and `Export::decode`s it; the only `alloc::custom` calls are in
`initOrderSingletons` (`:35/:37/:39`), whose sole caller is the runtime-init hook
`Eco_Kernel_Order_register_gc_roots` (`UtilsExports.cpp:186-188`, invoked once from
`eco-kernel-cpp/src/eco/RuntimeExports.cpp:49-50` and `runtime/src/codegen/ecoc.cpp:340-341`).
That is *why* `(Utils, compare)` may carry `GcNone`; a reviewer who reads only
`ListExports.cpp:718` will reach the opposite conclusion, so the row's evidence string names
the init hook explicitly.

**Deliverable to keep — `scripts` are overkill; use this one-liner as the recurring drift check.**
Every `evidence` string is a repo-relative `path:line` (Phase 1 pins the format), so:

```bash
cd /work && grep -o '[A-Za-z0-9_/.-]*\.\(cpp\|hpp\):[0-9]\+' \
    compiler/src/Compiler/GlobalOpt/KernelFacts.elm | sort -u \
  | while IFS=: read -r f l; do
      [ -f "$f" ] || { echo "MISSING FILE  $f:$l"; continue; }
      n=$(wc -l < "$f"); [ "$l" -le "$n" ] || echo "PAST EOF      $f:$l (file has $n)";
    done | tee /tmp/kernelfacts_anchors.txt
```

**Acceptance:** `/tmp/kernelfacts_anchors.txt` is empty. (Existence + in-range only; semantic drift is
caught by the D3 row review, not by a script — the script exists so *file renames and deletions* can
never silently rot the table.)

### Phase 1 — the `KernelFacts` module (R1)

New file `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`. Full skeleton (types + machinery; rows in
Phase 3):

```elm
module Compiler.GlobalOpt.KernelFacts exposing
    ( KernelFacts, CallTimeEffect(..), GcAlloc(..), Totality(..), ParamMode(..)
    , lookup, lookupSymbol, splitSymbol, rows
    , canTriggerGC, gcLeafEligible, droppable, hoistable
    , gcLeafEligibleFor, droppableFor, hoistableFor
    , validationErrors
    )

{-| The single audited source of per-kernel semantic facts (design_docs/
kernel-boundary-reduction.md §6.C1; plans/kernel-opt-07-kernel-facts-table.md).

Keyed by plain `(home, name)` like `KernelTypeEnv` and the borrow table it
replaces — **Mono** names: the `MonoVarKernel` prefix field ("Elm"/"Eco") and
the `_Int/_Float/_Char` ABI suffixes minted by `KernelAbi.kernelInstanceSymbol`
(KernelAbi.elm:182-407 — root at :187, suffix arms :193-404, unsuffixed
fall-through :406-407) never appear here; symbol-only consumers use
`lookupSymbol`.

**Whitelist discipline (§6.F): unknown ⇒ each consumer keeps its OWN pre-table
behaviour.** A `Nothing` is not a shared default; it means "no consumer may
move". A blacklist would be unsound.

**Derived facts are computed, never stored** (`canTriggerGC` / `gcLeafEligible`
/ `droppable` / `hoistable`), each in TWO forms: the record form
(`KernelFacts -> Bool`, what kernel-opt-11/12/13 call on a row they already
looked up) and a key form suffixed `For` (`( Name, Name ) -> Bool`, which
folds the whitelist default in and is what kernel-opt-08 calls where it has
only a `KernelInstanceKey`). Elm has no overloading, so the two forms MUST
have different names — see the cross-plan note in the plan.

Each stored field has exactly one C++ question behind it. Rejected rows
(POwned, do NOT add — Console.write precedent, the result is a `Task_Binding`
capturing the arg): `File.fileExists`/`dirExists` (File.cpp:679/684),
`Env.lookup` (Env.cpp:52), `Scheduler.spawn` (Scheduler.cpp:467).

TODO cost axis: `MonoInlineSimplify.computeCost` still prices every kernel at a
flat 1 (:1230-1231). §6.C1 leaves this out of v1 — a cost model needs
measurement, not audit.

-}

import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


type CallTimeEffect
    = EffNone -- nothing observable at call time (incl. Task builders, KERNEL_TASK_IO_001)
    | EffObservableIO -- stdio / fs / net / calls the app; ALSO the "unknown" answer
    | EffRuntimeState -- mutates runtime-internal tables (regex cache, port registry)
    | EffNoreturn -- exit()/abort — never returns


type GcAlloc
    = GcNone -- provably zero Eco-heap allocation on EVERY path
    | GcFixed Int -- <= N objects of statically known shapes per call
    | GcUnbounded -- input-dependent; ALSO the "unknown" answer


type Totality
    = Total
    | Throws
    | MayDiverge


type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- may store, return, or hand to unknown code


type alias KernelFacts =
    { params : List ParamMode -- [] == borrow axis NOT audited (see the shim)
    , resultAliases : List Int -- result may alias these params (0-based)
    , callTimeEffect : CallTimeEffect
    , gcAlloc : GcAlloc
    , cppAlloc : Bool -- C++-heap use; gc-leaf-COMPATIBLE, informational
    , callsBackIntoElm : Bool -- HOF bit; audited from C++ bodies, NEVER from Elm types
    , cseSafe : Bool -- referentially transparent at the Mono level
    , totality : Totality
    , divergence : Maybe String -- A6 ledger note (C++ body vs intrinsic)
    , evidence : String -- MANDATORY repo-relative "path.cpp:line" anchor(s)
    }


{-| The conservative base: every axis at its "we do not know" end. A row built
from `unaudited` licenses NOTHING (all four derived facts are False) and fails
`validationErrors` until it carries an evidence anchor.
-}
unaudited : KernelFacts
unaudited =
    { params = []
    , resultAliases = []
    , callTimeEffect = EffObservableIO
    , gcAlloc = GcUnbounded
    , cppAlloc = True
    , callsBackIntoElm = True
    , cseSafe = False
    , totality = MayDiverge
    , divergence = Nothing
    , evidence = ""
    }


{-| Base for a row whose C++ body has been read end-to-end and found free of IO,
of Elm call-backs, and of throwing paths. Still allocates (`GcUnbounded`) until
the row says otherwise.
-}
auditedPure : KernelFacts
auditedPure =
    { unaudited
        | callTimeEffect = EffNone
        , cppAlloc = False
        , callsBackIntoElm = False
        , cseSafe = True
        , totality = Total
    }



-- DERIVED FACTS (computed, never stored — §A7 :1209-1215, the paragraph
-- "Derived facts (never stored, always computed)"; note it sits under A7,
-- not A6, in design_docs/kernel-boundary-reduction.md)


canTriggerGC : KernelFacts -> Bool
canTriggerGC f =
    f.gcAlloc /= GcNone || f.callsBackIntoElm


gcLeafEligible : KernelFacts -> Bool
gcLeafEligible f =
    not (canTriggerGC f)


droppable : KernelFacts -> Bool
droppable f =
    f.cseSafe && f.totality == Total


hoistable : KernelFacts -> Bool
hoistable f =
    f.cseSafe



-- KEY FORMS: same facts, whitelist default folded in. An unlisted key answers
-- False for all three, which is every consumer's status-quo behaviour. These
-- exist so a consumer holding a key (kernel-opt-08's `KernelInstanceKey`) does
-- not have to spell `lookup >> Maybe.map … >> Maybe.withDefault False` and
-- accidentally pick `withDefault True`.


gcLeafEligibleFor : ( Name, Name ) -> Bool
gcLeafEligibleFor key =
    lookup key |> Maybe.map gcLeafEligible |> Maybe.withDefault False


droppableFor : ( Name, Name ) -> Bool
droppableFor key =
    lookup key |> Maybe.map droppable |> Maybe.withDefault False


hoistableFor : ( Name, Name ) -> Bool
hoistableFor key =
    lookup key |> Maybe.map hoistable |> Maybe.withDefault False



-- LOOKUP


lookup : ( Name, Name ) -> Maybe KernelFacts
lookup key =
    Dict.get key table


{-| **The one sanctioned mangled-symbol → Mono-key stripper.** Any consumer that
holds only the emitted C symbol MUST go through this (or through `splitSymbol`,
which is exposed for that purpose) rather than re-implement prefix/suffix
handling: two strippers WILL drift, and the drift is silent (a missed strip is
a lookup miss, i.e. a silently-lost optimisation, not an error).

Strips the `Elm_Kernel_`/`Eco_Kernel_` prefix (both are exactly 11 chars; the
prefix comes from `KernelInstanceKey.prefix ++ "_Kernel_"`, KernelAbi.elm:187)
and any `_Int/_Float/_Char` ABI suffix, then looks up the base Mono row. Sound:
the primitive-specialised C variants are strictly WEAKER in effect than their
boxed base (unboxed operands, no resolve), so inheriting the base row
over-approximates. Precedent for the two-prefix test: Ops.elm:664.

Current consumers: kernel-opt-12's `mlirSymbolIsDroppable`/`normalizeAbiVariant`
(it must be built on `splitSymbol`, not on a private copy). kernel-opt-08 does
NOT need it — it threads `home`/`name` from `KernelInstanceKey` into
`Ctx.KernelDeclInfo` as a new `gcLeaf : Bool` field instead (Context.elm:670-674
carries `symbolName`/`abiArgTypes`/`abiResultType` only, so *some* channel was
required; 08 chose the typed one).
-}
lookupSymbol : String -> Maybe KernelFacts
lookupSymbol sym =
    splitSymbol sym |> Maybe.andThen lookup


{-| Exposed on purpose: `Elm_Kernel_Utils_compare_Float` -> `Just ("Utils", "compare")`.
Anything that is not a kernel symbol (`eco_gc_alloc_region_fast`,
`Eco_Runtime_getOrderLT`) answers `Nothing` or a key no row matches.
-}
splitSymbol : String -> Maybe ( Name, Name )
splitSymbol sym =
    let
        afterPrefix : Maybe String
        afterPrefix =
            -- String.length "Elm_Kernel_" == String.length "Eco_Kernel_" == 11.
            if String.startsWith "Elm_Kernel_" sym || String.startsWith "Eco_Kernel_" sym then
                Just (String.dropLeft 11 sym)

            else
                Nothing

        dropAbiSuffix : String -> String
        dropAbiSuffix s =
            List.foldl
                (\suf acc ->
                    if String.endsWith suf acc then
                        String.dropRight (String.length suf) acc

                    else
                        acc
                )
                s
                [ "_Int", "_Float", "_Char" ]
    in
    afterPrefix
        |> Maybe.andThen
            (\rest ->
                case String.indexes "_" rest of
                    i :: _ ->
                        Just ( String.left i rest, dropAbiSuffix (String.dropLeft (i + 1) rest) )

                    [] ->
                        Nothing
            )


table : Dict ( Name, Name ) KernelFacts
table =
    Dict.fromList rows


rows : List ( ( Name, Name ), KernelFacts )
rows =
    [ {- Phase 3 -} ]
```

Validation (`validationErrors : List String`), run as an elm-test in Phase 4 — Elm cannot fail a
*build* on data, so "build-time validation" means "a compiler unit test that runs on every
`elm-tests`/CI invocation and blocks the merge":

```elm
{-| Cross-field consistency of the whole table. An inconsistent row is a test
failure of the compiler, not a latent miscompile. Empty == healthy.
-}
validationErrors : List String
validationErrors =
    dupKeyErrors ++ List.concatMap rowErrors rows


dupKeyErrors : List String
dupKeyErrors =
    -- Dict.fromList silently keeps the LAST duplicate; catch it here.
    if List.length rows == Dict.size table then
        []

    else
        [ "duplicate key(s): " ++ String.fromInt (List.length rows - Dict.size table) ]


rowErrors : ( ( Name, Name ), KernelFacts ) -> List String
rowErrors ( ( home, name ), f ) =
    let
        tag msg =
            home ++ "." ++ name ++ ": " ++ msg

        check cond msg =
            if cond then
                []

            else
                [ tag msg ]
    in
    List.concat
        [ -- V1 evidence is mandatory and must be a C++ anchor
          check (String.contains ".cpp:" f.evidence || String.contains ".hpp:" f.evidence)
            "evidence must carry at least one <file>.cpp:<line> / .hpp:<line> anchor"
        , -- V2 cseSafe is the strongest claim: no effect, no callback, terminates
          check (not f.cseSafe || (f.callTimeEffect == EffNone && not f.callsBackIntoElm && f.totality /= MayDiverge))
            "cseSafe requires EffNone AND not callsBackIntoElm AND totality /= MayDiverge"
        , -- V3 a noreturn row cannot be Total
          check (f.callTimeEffect /= EffNoreturn || f.totality /= Total)
            "EffNoreturn requires totality /= Total"
        , -- V4 GcFixed is a positive object budget
          check (gcBudgetOk f.gcAlloc)
            "GcFixed n requires n > 0 (use GcNone for zero)"
        , -- V5 a callback into Elm can allocate arbitrarily and can diverge
          check (not f.callsBackIntoElm || (f.gcAlloc == GcUnbounded && f.totality /= Total))
            "callsBackIntoElm requires GcUnbounded AND totality /= Total"
        , -- V6 a Throws row must say what it throws
          check (f.totality /= Throws || f.divergence /= Nothing)
            "totality = Throws requires a divergence note"
        , -- V7 resultAliases must index real params (so an unaudited row, params
          -- == [], cannot smuggle in alias edges the shim would then hide)
          check (List.all (\i -> i >= 0 && i < List.length f.params) f.resultAliases)
            "resultAliases index out of range for params"
        , -- V8 keys are MONO names, not ABI symbols
          check (home /= "" && name /= "")
            "empty home/name"
        , check (not (String.startsWith "Elm_Kernel_" home || String.startsWith "Eco_Kernel_" home))
            "home must be the Mono home, not the C symbol prefix"
        , check (not (List.any (\s -> String.endsWith s name) [ "_Int", "_Float", "_Char" ]))
            "name must be the base Mono name, not an ABI-suffixed symbol"
        ]


gcBudgetOk : GcAlloc -> Bool
gcBudgetOk ga =
    case ga of
        GcFixed n ->
            n > 0

        _ ->
            True
```

(`Name` is `type alias Name = String`, Data/Name.elm:75-76, so `( Name, Name )` keys are ordinary
comparable tuples and `Dict`/`List.sort` work on them directly.)

**Import-graph invariant (load-bearing for kernel-opt-11/12/13).** `KernelFacts.elm`'s import list
is exactly `Compiler.Data.Name` + `Dict` and must stay that way: the dependency edge runs
`Borrow/KernelSigs.elm → KernelFacts` (and later `MonoInlineSimplify → KernelFacts`,
`Generate/MLIR/Ops.elm → KernelFacts`, `Generate/MLIR/Context.elm → KernelFacts`), never the other
way. Adding an import of anything under `Compiler.GlobalOpt.*`, `Compiler.Mono.*` or
`Compiler.Generate.*` to `KernelFacts` would create a cycle at the first consumer. kernel-opt-11
(:248-252) and kernel-opt-12 (:299-300) both assert this two-import shape as their no-cycle
argument, mirroring today's `Borrow/KernelSigs.elm:31-32`.

**Acceptance (Phase 1):** module compiles; `elm-format --validate` clean; `validationErrors` is
reachable from the test module; no other module imports `KernelFacts` yet except the Phase 2 shim;
`grep -n '^import' compiler/src/Compiler/GlobalOpt/KernelFacts.elm` shows exactly two lines.

### Phase 2 — `Borrow/KernelSigs.elm` becomes a shim (R1)

Full replacement content:

```elm
module Compiler.GlobalOpt.Borrow.KernelSigs exposing
    ( ParamMode(..), KernelSig, lookup )

{-| **SHIM (kernel-opt-07 R1).** The audited kernel table now lives in
`Compiler.GlobalOpt.KernelFacts`; this module survives only so
`Borrow/Constrain.elm` and `Borrow/LssFacts.elm` compile untouched.

`ParamMode` is DEFINED here rather than re-exported because Elm has no
re-export: an `exposing` list may only name declarations of the module itself
(`Canonicalize.ExportNotFound`, Reporting/Error/Canonicalize.elm:88), and a
custom type's constructors cannot be aliased into pattern position. The
`toParamMode` case below is exhaustive, so any future constructor added to
`KernelFacts.ParamMode` is a COMPILE ERROR here rather than silent drift.

`params = []` in a `KernelFacts` row means "the borrow axis of this row has not
been audited". Such a row is reported as a MISS so `Constrain`/`LssFacts` take
exactly today's poison path — *including* the census counters
(`poisonedByKernel`, `kernelDefaultedHeapCalls`, `kernelDefaultedNames`), which
would otherwise silently re-baseline design_docs/borrow-inf-census.md. A
genuinely arity-0 kernel is borrow-vacuous, so the sentinel is safe there too
(`poisonArgs [] == identity`, and both paths then `ownEverything` the result).

-}

import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.KernelFacts as KF


type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- default; may store, return, or hand to unknown code


type alias KernelSig =
    { params : List ParamMode
    , resultAliases : List Int -- result may alias these params (0-based)
    }


lookup : ( Name, Name ) -> Maybe KernelSig
lookup key =
    case KF.lookup key of
        Nothing ->
            Nothing

        Just facts ->
            case facts.params of
                [] ->
                    Nothing

                ps ->
                    Just
                        { params = List.map toParamMode ps
                        , resultAliases = facts.resultAliases
                        }


toParamMode : KF.ParamMode -> ParamMode
toParamMode pm =
    case pm of
        KF.PBorrowed ->
            PBorrowed

        KF.POwned ->
            POwned
```

Call sites that must compile with zero edits (read and confirmed 2026-08-10):

- `Constrain.elm:883-908` — `case KernelSigs.lookup ( home, name ) of Just ksig -> … applyKernelSig ksig …`;
  `applyKernelSig : KernelSigs.KernelSig -> …` (:1078) reads `ksig.params` (:1083) and `ksig.resultAliases` (:1098);
  `applyKernelParams : … -> List KernelSigs.ParamMode -> …` (:1101) pattern-matches `KernelSigs.PBorrowed` (:1108) / `KernelSigs.POwned` (:1111).
- `LssFacts.elm:242-249` — `Just (Mono.OriginKernel home name) -> case KernelSigs.lookup ( home, name ) of Just ksig -> Routed (kernelToSig ksig calleeType)`;
  `kernelToSig : KernelSigs.KernelSig -> Mono.MonoType -> BorrowSig` (:307) reads `ksig.params` (:314) / `ksig.resultAliases` (:321);
  `paramModeToMode : KernelSigs.ParamMode -> Mode` (:356) matches `KernelSigs.PBorrowed`/`POwned` (:359/:362).
- No `KernelSig` record LITERAL is constructed anywhere outside KernelSigs.elm (grepped: only the two
  annotation sites and the field reads above), so keeping the alias structurally identical is sufficient.

**Miss-path equivalence, for the record.** A `lookup` miss runs
`poisonArgs argRtys RKernel bumpKernel` (Constrain.elm:893) — `poisonArgs` is `:1723-1725`,
`poison` is `:1712-1720`, so per **heap** arg it is `bumpKernel (forceAllOf RKernel rty (escSeedAll
rty g))` and per scalar arg a no-op — then `poisoned = ownEverything resultRty` (:865-866).
`applyKernelSig` with `params = []` falls into the "missing tail: default POwned (defensive)" arm
(:1117-1119) and does `ownEverything argRty (escSeedAll argRty g)` per arg, where
`ownEverything = forceAllOf RConstruct` (:1661-1663) and `forceAllOf` is a no-op on `RScalar`
(:1671-1675), as is `escSeedAll` (`resInto RScalar = acc`, :304-308) — and `isHeapRty` is exactly
`rty /= RScalar` (:1647-1654), so "skip non-heap args" and "run two no-ops on non-heap args"
coincide. So the two paths emit the **same constraint set**, and differ in exactly two ways:
the `Reason` label attached to each `forcedOwned` entry (`RKernel` vs `RConstruct`) and the census
counters (`poisonedByKernel` :1733-1735 + `kernelDefaultedHeapCalls`/`kernelDefaultedNames`
:895-906 vs `kernelSigHits` :887). Both differences are *observable in the borrow census*, which is
why unaudited rows report `Nothing` instead of a synthesised empty sig — and why Gate G5 diffs the
census rather than the MLIR.

**Acceptance (Phase 2):** `cmake --build build --target elm-tests` compiles; `git diff --stat` shows
Constrain.elm and LssFacts.elm untouched.

### Phase 3 — seed rows (R1 + R8)

**52 rows total: 48 kernel rows + 4 `Basics_*` ledger-only rows** (the ledger block at the end of
this phase). The 48 = all 33 legacy `KernelSigs` keys (so borrow behaviour is bit-identical) plus 15
new effect-audited keys from §6.E. Two row classes:

- **A (effect-audited)** — verdict from the §6.E audit, re-anchored today.
- **B (borrow-legacy)** — a legacy `KernelSigs` row whose C++ body has NOT been re-read for effects:
  built from `unaudited`, so all four derived facts are False and every consumer keeps its default.
  Promoting a class-B row to class A is a separate, D3-reviewed change.

§6.E census symbols that fold into a base Mono key (ABI suffixes are minted by
`KernelAbi.kernelInstanceSymbol`, KernelAbi.elm:182-407, not present in Mono names): rows 19
`List_cons_Int` + 27 `List_cons_Char` → `(List, cons)`; row 15 `JsArray_initializeFromList_Int` →
`(JsArray, initializeFromList)`; row 18 `JsArray_initialize_Int` → `(JsArray, initialize)`.

Path shorthands used in the table only — the Elm `evidence` string spells the full repo-relative path:
`EKC` = `elm-kernel-cpp/src/core/`, `EKB` = `elm-kernel-cpp/src/bytes/`, `CK` = `eco-kernel-cpp/src/eco/`,
`RA` = `runtime/src/allocator/`, `RP` = `runtime/src/platform/`, `EKU` = `elm-kernel-cpp/src/core/`
(same as EKC; used only to keep the `UtilsExports.cpp` column readable). **Every anchor below —
export entry AND interior — was opened and verified in the tree on 2026-08-10**, including the four
that an earlier draft marked as doc-sourced (`foldImpl :576`, the accumulator return `:636-640`,
`StringOps.cpp:307-473`, `StringOps.hpp:1241-1270`); the `(d)` marking is gone.

**A1 — gc-leaf eligible AND cseSafe (the stampable 14; `{ auditedPure | gcAlloc = GcNone, … }`)**

| key | eff | cpp | borrow params/aliases | evidence |
|---|---|---|---|---|
| `(Utils, equal)` | ObservableIO → **None after Phase 5** | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:107-109` → `equalRespectingConstants :94-105` → `EKC Utils.cpp:470-472` → `eqHelp :521-740`; trace `:557-562`; `dictEq :753-803`; depth cap `:566-569`; `RA StringOps.hpp:1486-1533` alloc-free; `RA HeapHelpers.hpp:822` ListCursor non-allocating |
| `(Utils, notEqual)` | inherits `equal` | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:111-113` = `!equalRespectingConstants(…)`, i.e. **the same body as `equal`** — NOT `Utils::notEqual` (`EKC Utils.cpp:805-807`), which has no callers |
| `(Utils, compare)` | None | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:13-16` → `EKC Utils.cpp:451-457` (`cmp :302-445`); Order singletons pre-allocated in `initOrderSingletons :33-45` (roots `:41-43`), whose sole caller is the init hook `EKU UtilsExports.cpp:186-188` — **this is what makes the row `GcNone`**; NDEBUG-UB note `:214-217`; `RA StringOps.hpp:1544-1608` |
| `(Utils, lt)` | None | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:115-117` → `EKC Utils.cpp:809-811` → `cmp :302` |
| `(Utils, le)` | None | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:119-121` → `EKC Utils.cpp:813-815` |
| `(Utils, gt)` | None | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:123-125` → `EKC Utils.cpp:817-819` |
| `(Utils, ge)` | None | ✓ | `[B,B]` / `[]` | export `EKU UtilsExports.cpp:127-129` → `EKC Utils.cpp:821-823` |
| `(String, length)` | None | – | `[B]` / `[]` | `EKC StringExports.cpp:18-27` → `RA StringOps.hpp:239-243` (one u32 load, all six tags) |
| `(String, startsWith)` | None | – | `[B,B]` / `[]` | `EKC StringExports.cpp:106-108` → `RA StringOps.hpp:688-714` (memcmp tiers) |
| `(String, endsWith)` | None | – | `[B,B]` / `[]` | `EKC StringExports.cpp:110-112` → `RA StringOps.hpp:719-748` |
| `(String, contains)` | None | – | `[B,B]` / `[]` | `EKC StringExports.cpp:114-116` → `RA StringOps.hpp:645-683`; `charAt :410-463` alloc-free |
| `(Bytes, getStringWidth)` | None | ✓ | `[B]` / `[]` | `EKB BytesExports.cpp:309-366`; `u16string` snapshot `:330-338` |
| `(Bytes, width)` | None | – | `[B]` / `[]` | `EKB BytesExports.cpp:299-301` (raw scalar via `elm_bytebuffer_len`) |
| `(Bytes, decodeFailure)` | None | – | `[]` / `[]` | `EKB BytesExports.cpp:469-471` → `RA HeapHelpers.hpp:196` (`alloc::nothing()` = embedded constant) |

**A2 — audited pure, allocating (cseSafe, NOT leaf)**

| key | gcAlloc | cpp | borrow | evidence / divergence |
|---|---|---|---|---|
| `(List, cons)` | `GcFixed 1` | – | `[]`/`[]` | `EKC ListExports.cpp:276-283` → `List::cons` → `RA HeapHelpers.hpp:630` |
| `(Utils, append)` | Unbounded | ✓ | `[]`/`[]` | `EKC Utils.cpp:829-853`; string path `RA StringOps.hpp:477-537`; list path `RA ListOps.cpp:262`. **divergence:** "unsupported tag pair silently returns the first argument (Utils.cpp:851-852) instead of failing" |
| `(List, reverse)` | Unbounded | – | `[]`/`[]` | `EKC ListExports.cpp:651-654` → `RA ListOps.cpp:530` |
| `(Bytes, read_u32)` | `GcFixed 1` (Tuple2) | – | `[]`/`[]` | `EKB BytesExports.cpp:539-547` |
| `(String, slice)` | Unbounded | – | `[B,B,B]`/`[2]` | `EKC StringExports.cpp:56-59` → `RA StringOps.cpp:307-473` (interior views `:337`/`:415`, whole-string identity `:321`) |
| `(String, cons)` | Unbounded | – | `[]`/`[]` | `EKC StringExports.cpp:40-44` → `RA StringOps.hpp:1241-1270` |
| `(JsArray, empty)` | `GcFixed 1` | – | `[]`/`[]` | `EKC JsArrayExports.cpp:192-195` |
| `(JsArray, initializeFromList)` | Unbounded | – | `[]`/`[]` | base export `EKC JsArrayExports.cpp:457-461` (the ABI variant `Elm_Kernel_JsArray_initializeFromList_Int` is `:982`, same Mono key) |

**A3 — Task constructors (EffNone per KERNEL_TASK_IO_001, invariants.csv:590)**

| key | gcAlloc | HOF | evidence |
|---|---|---|---|
| `(Scheduler, succeed)` | `GcFixed 1` | no | `EKC SchedulerExports.cpp:16-21` → `RP Scheduler.cpp:123-126` |
| `(Scheduler, fail)` | `GcFixed 1` | no | `EKC SchedulerExports.cpp:23-28` → `RP Scheduler.cpp:139-142` |
| `(Scheduler, andThen)` | `GcFixed 1` | **no — stores the closure, never applies it** | `EKC SchedulerExports.cpp:30-37` → `RP Scheduler.cpp:149-152` |
| `(Scheduler, onError)` | `GcFixed 1` | no | `EKC SchedulerExports.cpp:39-46` → `RP Scheduler.cpp:154-157` |
| `(MVar, put)` | `GcFixed 1` (binding) | no | `CK MVarExports.cpp:38-46` → `CK MVar.cpp:290` |
| `(MVar, read)` | `GcFixed 1` (binding) | no | `CK MVarExports.cpp:30-32` → `CK MVar.cpp:264` |

**A4 — HOFs (`{ unaudited | callsBackIntoElm = True, … }`; eff/alloc/totality all join over the closure)**

| key | totality | borrow | evidence |
|---|---|---|---|
| `(JsArray, foldl)` | MayDiverge | `[B,B,B]`/`[1,2]` | `EKC JsArrayExports.cpp:651-653` → `foldImpl :576` (final accumulator returned by identity when it stayed boxed, `:636-640`) |
| `(JsArray, foldr)` | MayDiverge | `[B,B,B]`/`[1,2]` | `EKC JsArrayExports.cpp:655-657` → `foldImpl :576` |
| `(JsArray, map)` | MayDiverge | `[B,B]`/`[1]` | `EKC JsArrayExports.cpp:463` |
| `(JsArray, initialize)` | MayDiverge | `[]`/`[]` | base export `EKC JsArrayExports.cpp:422` (ABI variant `_Int` at `:948`, same Mono key) |
| `(List, map2)` | MayDiverge | `[B,B,B]`/`[1,2]` | `EKC ListExports.cpp:592-600` → `kernelListMapN :432` |
| `(List, sortBy)` | **Throws** | `[B,B]`/`[1]` | `EKC ListExports.cpp:677`; SWO comparator = the whole `stable_sort` lambda `:722-736` + `EKC Utils.cpp:305-306`. **divergence:** "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and leans on Utils::cmp's early returns" |
| `(List, sortWith)` | **Throws** | `[B,B]`/`[1]` | `EKC ListExports.cpp:751`; same shape. **divergence:** as sortBy |
| `(String, all)` | MayDiverge | `[B,B]`/`[]` | `EKC StringExports.cpp:305` (snapshotChars copies; fn args are unboxed Chars) |

**B — borrow-legacy rows (`{ unaudited | params = …, resultAliases = …, evidence = … }`)**

`(JsArray, length)` `[B]`/`[]` `EKC JsArrayExports.cpp:204-208` · `(JsArray, unsafeGet)` `[B,B]`/`[1]`
`EKC JsArrayExports.cpp:210-223` (aliases an element only in the boxed-array branch `:221`) ·
`(Debug, toString)` `[B]`/`[]` `EKC DebugExports.cpp:56` · `(Bytes, encode)` `[B]`/`[]`
`EKB BytesExports.cpp:395` (`writeEncoder :144`) · `(Bytes, decode)` `[B,B]`/`[0,1]`
`EKB BytesExports.cpp:418` · `(String, uncons)` `[B]`/`[0]` `EKC StringExports.cpp:46` →
`RA StringOps.cpp:1009` · `(String, words)` `[B]`/`[0]` `EKC StringExports.cpp:71` →
`EKC String.cpp:286` · `(String, trim)` `[B]`/`[0]` `EKC StringExports.cpp:91` →
`RA StringOps.hpp:878` · `(String, toLower)` `[B]`/`[]` `EKC StringExports.cpp:86` →
`RA StringOps.hpp:801` · `(String, toUpper)` `[B]`/`[]` `EKC StringExports.cpp:81` →
`RA StringOps.hpp:762`

Two class-B rows carry ONE audited axis each (the rest stays `unaudited`):

| key | audited axis | evidence |
|---|---|---|
| `(Debug, log)` | `callTimeEffect = EffObservableIO` (it prints) — the one row CafHoist gets right today | `EKC DebugExports.cpp:26`; borrow `[B,B]`/`[1]` |
| `(Crash, crash)` | `callTimeEffect = EffNoreturn`, `totality = MayDiverge`, **divergence** "prints to stderr + backtrace then ::exit(1) — never returns" | `CK CrashExports.cpp:9-11` → `CK Crash.cpp:20-33` (`toString` `:21`, `fprintf` `:22`/`:26`, `::exit(1)` `:30`); borrow `[B]`/`[]` |

> `Crash_crash` deliberately keeps `gcAlloc = GcUnbounded` (not §6.E's `GcNone`): `Crash::crash` calls
> `toString(message)` (Crash.cpp:21), which is unread. §6.E itself marks its leaf column "moot" — a
> noreturn call is never a useful gc-leaf — so the conservative value costs nothing and keeps the
> stampable set exactly the A1 14.

Representative Elm literals (the rest are mechanical from the tables above):

```elm
rows : List ( ( Name, Name ), KernelFacts )
rows =
    -- ── A1: gc-leaf eligible + cseSafe (the kernel-opt-08 stampable set) ──
    [ ( ( "Utils", "equal" )
        -- Phase 5 flips callTimeEffect to EffNone and cseSafe to True; until the
        -- fprintf is deleted the row must stay honest about the code as-is.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True -- dictEq uses std::vector working stacks
            , callTimeEffect = EffObservableIO
            , cseSafe = False
            , divergence = Just "depth > 100 returns true (elm-kernel-cpp/src/core/Utils.cpp:566-569): deep unequal values compare equal; cmp has no such cap"
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:107-109 (equalRespectingConstants :94-105); elm-kernel-cpp/src/core/Utils.cpp:470-472 (eqHelp :521-740, trace :557-562, dictEq :753-803); runtime/src/allocator/StringOps.hpp:1486-1533"
        }
      )
    , ( ( "Utils", "notEqual" )
        -- Same body as `equal`: the extern is `!equalRespectingConstants(…)`.
        -- Every field must MATCH the `equal` row (including the Phase-5 flip),
        -- which is why the two rows are edited together, never separately.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , callTimeEffect = EffObservableIO
            , cseSafe = False
            , divergence = Just "inherits equal's depth > 100 cap (elm-kernel-cpp/src/core/Utils.cpp:566-569)"
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:111-113 (= !equalRespectingConstants :94-105; NOT Utils::notEqual at Utils.cpp:805-807, which has no callers)"
        }
      )
    , ( ( "String", "length" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:18-27; runtime/src/allocator/StringOps.hpp:239-243"
        }
      )

    -- ── A2: audited pure, allocating ──
    , ( ( "List", "cons" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:276-283; runtime/src/allocator/HeapHelpers.hpp:630"
        }
      )

    -- ── A4: HOFs — eff/alloc/totality join over the user closure ──
    , ( ( "List", "sortBy" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , callsBackIntoElm = True
            , totality = Throws
            , divergence = Just "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and relies on Utils::cmp's early returns"
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:677 (comparator :722-736); elm-kernel-cpp/src/core/Utils.cpp:305-306"
        }
      )

    -- ── B: borrow-legacy (all four derived facts False; consumers unchanged) ──
    , ( ( "String", "uncons" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:46-49; runtime/src/allocator/StringOps.cpp:1009"
        }
      )

    -- ── A6 ledger-only rows: NO borrow entry (params = [] ⇒ the shim reports a
    -- miss ⇒ Constrain/LssFacts keep today's poison path), NO audited axis
    -- beyond what the ledger states. They exist so the divergence is recorded
    -- before Part-2 migration touches these symbols. `evidence` is still
    -- MANDATORY (rule V1) — it names the C++ body, and `divergence` names the
    -- intrinsic it disagrees with.
    , ( ( "Basics", "modBy" )
      , { unaudited
            | totality = Throws
            , divergence = Just "C++ THROWS std::runtime_error on modulus 0 (elm-kernel-cpp/src/core/Basics.cpp:92-103, throw at :96); the intrinsic returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131). A PAP-captured `modBy 0` terminates through statepointed frames; an inlined one returns 0."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:92-103; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131"
        }
      )
    ]
```

**A6 divergence ledger (R8) — the exact `divergence` AND `evidence` strings.** Four of the six
ledger rows sit on symbols already in the tables above; the four `Basics_*` rows are added as
ledger-only class-B rows (`{ unaudited | totality = …, divergence = …, evidence = … }`, no borrow
entry so `params = []` and the shim reports a miss) because the ledger must exist *before* Part-2
migration touches these symbols. **`evidence` is not optional on a ledger row** — validation rule
V1 fails any row without a `.cpp:`/`.hpp:` anchor, so each of the four carries one explicitly:

| key | extra axes | `divergence` string | `evidence` string |
|---|---|---|---|
| `(Basics, modBy)` | `totality = Throws` | `"C++ THROWS std::runtime_error on modulus 0 (elm-kernel-cpp/src/core/Basics.cpp:92-103, throw at :96); the intrinsic returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131). A PAP-captured modBy 0 terminates through statepointed frames; an inlined one returns 0."` | `"elm-kernel-cpp/src/core/Basics.cpp:92-103; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131"` |
| `(Basics, idiv)` | — (stays `MayDiverge`) | `"C++ is bare a / b: UB / SIGFPE on 0 (Basics.cpp:88-90); the intrinsic is guarded and returns 0 (EcoToLLVMArith.cpp:57-81)."` | `"elm-kernel-cpp/src/core/Basics.cpp:88-90; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:57-81"` |
| `(Basics, remainderBy)` | — | `"C++ UB on divisor 0 (Basics.cpp:105-107); the intrinsic is guarded and returns 0 (EcoToLLVMArith.cpp:133-157)."` | `"elm-kernel-cpp/src/core/Basics.cpp:105-107; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:133-157"` |
| `(Basics, tan)` | — | `"C++ is std::tan (Basics.cpp:40-42); the intrinsic composes sin(x)/cos(x) (EcoToLLVMArith.cpp:324-337) — differs in the last ulp and at poles."` | `"elm-kernel-cpp/src/core/Basics.cpp:40-42; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:324-337"` |
| `(List, sortBy)` / `(List, sortWith)` | already in A4 | see A4 above | see A4 above |
| `(Utils, equal)` | already in A1 | see A1 above | see A1 above |

Why the ledger rows still satisfy validation: they are built from `unaudited`, so
`cseSafe = False` (V2 vacuous), `callsBackIntoElm = True` **with** `gcAlloc = GcUnbounded` and
`totality /= Total` (V5 holds), `params = []` and `resultAliases = []` (V7 holds), and
`(Basics, modBy)`'s `Throws` is paired with a `divergence` (V6 holds). Nothing about them is
gc-leaf or droppable, so they change no consumer.

**Acceptance (Phase 3):** the Phase 0 anchor linter is empty; `validationErrors == []`;
`List.length rows == 48 + 4` (the four `Basics_*` ledger rows) `== 52` and
`Dict.size table == 52` (no duplicate keys); the gc-leaf golden set is exactly the A1 14 keys.

### Phase 4 — validation test module

New file `compiler/tests/Compiler/GlobalOpt/KernelFactsTest.elm` (module
`Compiler.GlobalOpt.KernelFactsTest`), mirroring the layout of the existing
`compiler/tests/Compiler/GlobalOpt/Borrow/DsuTest.elm` (module = path, exposes `suite : Test`).
elm-test-rs discovers every `tests/**/*.elm` exposing a `Test`; `build-xhr/tests` is a configure-time
dir link to `compiler/tests` (`eco_create_dir_link`, compiler/CMakeLists.txt:119) and
`elm-explorations/test 2.2.0` is already a direct test-dependency
(compiler/cmake/bootstrap/build-xhr/elm.json:43-46) — **no registration step**. The `elm-tests`
target is `add_custom_target(elm-tests …)` at compiler/CMakeLists.txt:178-186 and runs
`elm-test-rs --project ${BUILD_XHR_DIR} --fuzz 1`; the `src` directory is on `source-directories`
(elm.json:3-6) so the test module can import `Compiler.GlobalOpt.KernelFacts` directly. Note the
directory `compiler/tests/Compiler/GlobalOpt/` exists today but contains only `Borrow/`.

**Transcribe `legacyBorrowGolden` BEFORE Phase 2 rewrites the file** (that is the whole point of an
independent copy). Concretely, either do Phase 4 first, or recover the pre-change table with:

```bash
cd /work && git show HEAD:compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm | sed -n '51,167p'
```

(lines 51-167 are the 33-row `table` literal in the current file; `bb1 = { params = [ PBorrowed ],
resultAliases = [] }` at :170-172 and `bb2 = { params = [ PBorrowed, PBorrowed ], resultAliases = [] }`
at :175-177 must be expanded by hand into the golden — the golden must not share helpers with the
thing it is checking.)

```elm
module Compiler.GlobalOpt.KernelFactsTest exposing (suite)

{-| kernel-opt-07: the KernelFacts table is data, so its consistency is a unit
test rather than a type. Suites 3 and 4 are the load-bearing pair — together
they pin the borrow axis to EXACTLY the 33 legacy KernelSigs rows, which is what
makes this change inert.
-}

import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.KernelFacts as KF
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "GlobalOpt.KernelFacts"
        [ Test.test "1. every row satisfies the cross-field implications" <|
            \_ -> Expect.equal [] KF.validationErrors
        , Test.test "2. gcLeafEligible is exactly the audited stampable set" <|
            \_ ->
                KF.rows
                    |> List.filter (\( _, f ) -> KF.gcLeafEligible f)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort stampable)
        , Test.test "3. the borrow shim reproduces the legacy 33 rows exactly" <|
            \_ ->
                legacyBorrowGolden
                    |> List.map (\( k, sig ) -> ( k, Just sig ))
                    |> Expect.equal (List.map (\( k, _ ) -> ( k, KernelSigs.lookup k )) legacyBorrowGolden)
        , Test.test "4. NO key outside the legacy 33 answers the borrow shim" <|
            \_ ->
                KF.rows
                    |> List.filter (\( k, _ ) -> KernelSigs.lookup k /= Nothing)
                    |> List.map Tuple.first
                    |> List.sort
                    |> Expect.equal (List.sort (List.map Tuple.first legacyBorrowGolden))
        , Test.test "5. lookupSymbol strips the ABI prefix and _Int/_Float/_Char" <|
            \_ ->
                Expect.equal
                    [ KF.lookup ( "Utils", "compare" ), KF.lookup ( "Utils", "compare" ), KF.lookup ( "MVar", "put" ), KF.lookup ( "Bytes", "read_u32" ), Nothing ]
                    [ KF.lookupSymbol "Elm_Kernel_Utils_compare"
                    , KF.lookupSymbol "Elm_Kernel_Utils_compare_Float"
                    , KF.lookupSymbol "Eco_Kernel_MVar_put_Int"
                    , KF.lookupSymbol "Elm_Kernel_Bytes_read_u32"
                    , KF.lookupSymbol "eco_gc_alloc_region_fast"
                    ]
        , Test.test "6. the key-form derived helpers agree with the record form and default False" <|
            \_ ->
                Expect.equal
                    [ True, False, False, False ]
                    [ KF.gcLeafEligibleFor ( "String", "length" )
                    , KF.gcLeafEligibleFor ( "List", "cons" ) -- listed but allocating
                    , KF.gcLeafEligibleFor ( "Platform", "sendToApp" ) -- unlisted
                    , KF.droppableFor ( "Debug", "log" )
                    ]
        , Test.test "7. the table has the expected size and no duplicate keys" <|
            \_ -> Expect.equal ( 52, 52 ) ( List.length KF.rows, List.length (uniqueKeys KF.rows) )
        ]


uniqueKeys : List ( ( String, String ), a ) -> List ( String, String )
uniqueKeys =
    List.map Tuple.first >> List.sort >> dedupeSorted


dedupeSorted : List a -> List a
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs


stampable : List ( String, String )
stampable =
    [ ( "Utils", "equal" ), ( "Utils", "notEqual" ), ( "Utils", "compare" )
    , ( "Utils", "lt" ), ( "Utils", "le" ), ( "Utils", "gt" ), ( "Utils", "ge" )
    , ( "String", "length" ), ( "String", "startsWith" ), ( "String", "endsWith" ), ( "String", "contains" )
    , ( "Bytes", "getStringWidth" ), ( "Bytes", "width" ), ( "Bytes", "decodeFailure" )
    ]


{-| Transcribed by hand from the PRE-CHANGE Borrow/KernelSigs.elm:51-167 — recover
it with `git show HEAD:compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm`
before Phase 2 rewrites the file. All 33 rows, with `bb1`/`bb2` expanded inline.
Do NOT regenerate from KernelFacts and do NOT import the shim's helpers — the
whole point is that this is an independent copy.
-}
legacyBorrowGolden : List ( ( String, String ), KernelSigs.KernelSig )
legacyBorrowGolden =
    [ ( ( "Utils", "compare" ), { params = [ KernelSigs.PBorrowed, KernelSigs.PBorrowed ], resultAliases = [] } )
    -- … 32 more, exactly as in the pre-change file. For reference, the 33 keys
    -- in file order are: Utils.{compare,equal,notEqual,lt,le,gt,ge};
    -- String.{length,startsWith,endsWith,contains}; JsArray.{length,unsafeGet};
    -- Debug.{log,toString}; Bytes.{getStringWidth,width,encode,decode};
    -- Crash.crash; JsArray.{foldl,foldr,map}; List.{map2,sortBy,sortWith};
    -- String.{slice,uncons,words,trim,toLower,toUpper,all}.
    -- The non-`bb1`/`bb2` rows are exactly: JsArray.unsafeGet [B,B]/[1],
    -- Debug.log [B,B]/[1], Bytes.decode [B,B]/[0,1], JsArray.foldl/foldr
    -- [B,B,B]/[1,2], JsArray.map [B,B]/[1], List.map2 [B,B,B]/[1,2],
    -- List.sortBy/sortWith [B,B]/[1], String.slice [B,B,B]/[2],
    -- String.uncons/words/trim [B]/[0], String.all [B,B]/[].
    ]
```

**Gate command:**

```bash
cd /work && cmake --preset build \
  && cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt
grep -nE "KernelFacts|failed|passed|TEST RUN" /tmp/test_output.txt
```

**Acceptance (Phase 4):** all seven suites pass; the pre-existing suite count is unchanged (compare
the `passed` total against a pre-change `elm-tests` run of the same command — do NOT re-run to
re-read, keep both logs).

### Phase 5 — delete the trace (R2)

1. **Baseline first (one run, teed):** if a `--target full` log from Phase 4's tree is not already on
   disk, produce it now and keep it:
   ```bash
   cd /work && cmake --build build --target full 2>&1 | tee /tmp/test_output_pre.txt
   grep -c '\[eq\] tag mismatch' /tmp/test_output_pre.txt   # expect 0
   ```
   A count of 0 proves no passing E2E case reaches the trace (it fires only on a tag mismatch that is
   not a list/list pair), so the deletion is unobservable to the suite. A nonzero count means an E2E
   case DOES mismatch tags — investigate that case before deleting anything.
2. Delete `elm-kernel-cpp/src/core/Utils.cpp:557-562` — the comment, the `static int traceCount`, the
   `if`, the `fprintf`, the increment, the closing brace — leaving `:553-556` (the `eqListHybrid`
   cross-form check) and `return false;` adjacent, i.e. the block becomes:
   ```cpp
       if (tagA != tagB) {
           if (isListNode(a) && isListNode(b)) {
               return eqListHybrid(a, b, depth);
           }
           return false;
       }
   ```
   **No include edit:** `grep -n 'fprintf\|cstdio\|stdio\.h' elm-kernel-cpp/src/core/Utils.cpp`
   shows this is the file's only `fprintf` and that neither `<cstdio>` nor `<stdio.h>` is directly
   included (the declaration arrives transitively through `Utils.hpp`/`ExportHelpers.hpp`), so
   nothing becomes an unused include. The file's own include block is `:8-15`.
3. Flip **both** `Utils` equality rows in lock-step — they share a body, so they must never diverge:
   `(Utils, equal)` and `(Utils, notEqual)` each drop the two overrides `callTimeEffect =
   EffObservableIO` and `cseSafe = False`, inheriting `auditedPure`'s `EffNone`/`cseSafe = True`, so
   each reads plain `{ auditedPure | params = [ PBorrowed, PBorrowed ], gcAlloc = GcNone, cppAlloc =
   True, divergence = …, evidence = … }`. Delete the `trace :557-562` clause from `equal`'s evidence
   string (`notEqual`'s evidence never named the trace). Both rows keep `gcLeafEligible = True`
   before and after, so the Phase-4 golden set is unchanged by this step — only `droppable`/
   `hoistable` flip, and no consumer reads them yet.

**Acceptance (Phase 5):** `grep -n 'traceCount\|\[eq\] tag mismatch' elm-kernel-cpp/src/core/Utils.cpp`
is empty; Gate G2 (below) green; `grep -c '\[eq\] tag mismatch' /tmp/test_output.txt` is 0.

### Phase 6 — the `KERNEL_FACTS_001` draft (R7 lands it, not this plan)

CSV shape confirmed by reading the file: header `id;phase;category;status;description;source` at
line 1; one row per line; **semicolons inside the description are normal** (CGEN_073/074 contain
several — the file is grep-oriented, not field-parsed); `source` is a `|`-separated list; rows are
appended at the end of the file (current last row `CGEN_075` at line 639).

**Insertion point:** a new line **640**, immediately after `CGEN_075`, with no blank line.
**Status field:** `proposed` while this plan is the only thing that has landed; kernel-opt-08 flips
field 4 to `enforced` in the same change that lands the `eco.gc_leaf` stamp + the D2 GCStats harness.

Final row text (edited from design doc :1451 to match the pinned cross-plan contract — **one**
declaration attribute `eco.gc_leaf`, no `eco.kernel_cannot_gc`; and the Mono-keying rule made explicit):

```
KERNEL_FACTS_001;CrossPhase;KernelFacts;proposed;Compiler.GlobalOpt.KernelFacts (the (home,name)-keyed table that Borrow/KernelSigs.elm now shims) is the ONLY source of per-kernel semantic facts (call-time effect, GC-allocation class, HOF bit, borrow modes, CSE safety, totality) - no pass may hard-code a kernel effect judgement by name or module string (the CafHoist home=="Debug" test and isPureExpr's blanket False become reads of this table). Keys are MONO names: the MonoVarKernel prefix (Elm/Eco) and the _Int/_Float/_Char ABI suffixes minted by KernelAbi.kernelInstanceSymbol never appear in a key, and a consumer holding only the emitted C symbol MUST go through KernelFacts.lookupSymbol/splitSymbol rather than re-implement the stripping. Consumers MUST read the derived helpers - record forms canTriggerGC/gcLeafEligible/droppable/hoistable, key forms gcLeafEligibleFor/droppableFor/hoistableFor which fold in the whitelist default False - and MUST NOT re-derive a derived fact from raw fields, because the raw defaults are the conservative end (EffObservableIO / GcUnbounded / cppAlloc / callsBackIntoElm / not cseSafe / MayDiverge) and a careless read must fail closed. A consumer may add further COMPUTED projections to the module (kernel-opt-11's costClass, kernel-opt-12's mlirSymbolIsDroppable/droppableSymbols) but may not add a stored record field. Every row carries a mandatory C++ evidence anchor (repo-relative export-body file:line) and may only STRENGTHEN a fact (EffNone / GcNone / not-HOF / PBorrowed / cseSafe / Total) after an audit establishing no transitive reach to alloc::* / eco_alloc_* / eco_apply_closure* / IO from the export body; a row whose params list is empty declares its BORROW axis unaudited and the KernelSigs shim reports it as a lookup miss. Unknown or unlisted kernels keep each consumer's pre-table behaviour (isPureExpr False, borrow all-owned poison with its census counters, no gc-leaf attr, EcoGCPrepare safepoint+barrier, CafHoist home-string test). Backend reflection: rows with gcAlloc==GcNone && !callsBackIntoElm MAY carry gc-leaf-function on the kernel declaration, emitted as the SINGLE func.func attr eco.gc_leaf on the is_kernel stub (Generate/MLIR/Functions.elm:1995-2008) and consumed by KernelFuncOpLowering and by the module-level marker that stamps eco.callee_gc_leaf on eco.call for EcoGCPrepare - there is no second cannot-gc attribute; motion-enabling LLVM attrs (memory(*)/speculatable/willreturn/nounwind) on declarations whose signature carries !eco.value are FORBIDDEN until RS4GC has statepointed the containing module (REP_LLVM_002 miscompile class) and any post-RS4GC stamping lives inside runRS4GCAndMaybeFramePointers so all four RS4GC flavours (serial / deferred-after-opt / split workers / single-partition inline) preserve the ordering. Table changes require the KernelFacts elm-test suite (row validation + gc-leaf golden set + borrow-shim golden 33) and, for any gcAlloc claim, the dev-build GCStats allocation-delta harness green over the E2E corpus;KernelFacts.elm|Borrow/KernelSigs.elm|Generate/MLIR/Functions.elm|Passes/EcoToLLVMFunc.cpp|EcoBackend.cpp|CGEN_072|REP_LLVM_002|KERNEL_TASK_IO_001
```

Also flagged for kernel-opt-08 (NOT edited here): CGEN_072's "ALL kernel externs" wording
(invariants.csv:636) forbids exactly this stamping and must be amended in the same change (§6.F
shared precondition, §8 H1).

**Acceptance (Phase 6):** the row text is reviewed and pasted into kernel-opt-08's plan as its
Phase-N deliverable; `design_docs/invariants.csv` is byte-unchanged by kernel-opt-07.

### Phase 7 — scope guard (what this plan does NOT do)

- **No consumer wiring.** `isPureExpr` / `computeCost` / `CafHoist` / `CafDedupe` / CSE stay exactly as
  they are (R4 = kernel-opt-11/12/13). In particular **CafHoist keeps `hasDebug = home == "Debug"`
  (CafHoist.elm:393) and CafDedupe keeps its no-purity-check merge** — narrowing a default-off pass is
  itself a regression (§6.F). The contradiction is *recorded* by this plan, and *resolved* by them.
- **No MLIR/LLVM reflection.** `eco.gc_leaf` on the `is_kernel` stub (Functions.elm attrs dict at
  :1995-2008, `is_kernel` at :1999) is kernel-opt-08's. The channel problem, found here:
  `Ctx.KernelDeclInfo` carries **only** `symbolName`/`abiArgTypes`/`abiResultType`
  (Context.elm:670-674) — no home/name — so 08 either calls `KernelFacts.lookupSymbol` on
  `symbolName` or threads the `KernelAbi.KernelInstanceKey` (KernelAbi.elm:113-119) fields through.
  **08 chose the second**: it adds `gcLeaf : Bool` to `KernelDeclInfo` and fills it in
  `registerKernelInstance` from `key.home`/`key.name`. That is why this plan exposes the *key-form*
  helper `gcLeafEligibleFor : ( Name, Name ) -> Bool` in addition to the record form — see the
  cross-plan note under Dependencies. `lookupSymbol`/`splitSymbol` stay exposed because
  kernel-opt-12's `mlirSymbolIsDroppable`/`normalizeAbiVariant` need exactly that stripping and must
  not grow a second private copy of it.
- **No cost axis** (§6.C1) and **no borrow-axis extension**: the 15 new keys carry `params = []`
  deliberately. Adding borrow modes to them is a separate D3-reviewed change with its own census A/B.

## Traps & risks

- **Elm has no re-export.** An `exposing` list may only name the module's own declarations
  (`ExportNotFound`, Reporting/Error/Canonicalize.elm:88), and a custom type's constructors cannot be
  aliased into pattern position — so `KernelSigs.PBorrowed` in `Constrain.elm:1108` forces `ParamMode`
  to be *defined* in the shim and mapped. Do not "simplify" this into
  `type alias ParamMode = KF.ParamMode`; it does not compile at the pattern sites.
- **`params = []` is a sentinel.** It means "borrow axis unaudited" and makes the shim report a miss.
  It is safe for genuinely arity-0 kernels (borrow-vacuous), but a future editor adding real borrow
  modes to a row MUST understand that the row's counters move from `kernelDefaultedHeapCalls` to
  `kernelSigHits`. Gate G5 exists to catch that.
- **Default-policy regression (binding, §6.F).** An UNLISTED kernel behaves exactly as today PER
  CONSUMER: `isPureExpr` stays False; borrow stays all-owned poison (26,988 poisoned heap args,
  borrow-inf-census.md:503); no gc-leaf attr; EcoGCPrepare keeps safepoint+barrier; CafHoist keeps its
  `home == "Debug"` test. The table only ever moves a LISTED row away from a consumer's default, in
  the audited direction.
- **HOF-bit provenance.** `callsBackIntoElm` must come from auditing C++ bodies for
  `eco_apply_closure` reach — an Elm-type-derived bit would misclassify kernels that *stash* a closure
  without calling it (`Scheduler_andThen`: `no`, SchedulerExports.cpp:30 → Scheduler.cpp:149-152).
- **The `cppAlloc` temptation.** `Utils_equal` (dictEq's `std::vector` stacks, Utils.cpp:753-803) and
  `Bytes_getStringWidth` (`std::u16string` snapshot, BytesExports.cpp:330-338) are `GcNone` AND
  `cppAlloc`. Collapsing the axes forces either lying (claim GcNone, hide the malloc) or
  over-conservatism (lose the leaf).
- **Divergence rows are warnings, not licenses.** A `divergence` note means the C++ symbol and the
  intrinsic are NOT interchangeable — no consumer may use the table to substitute one for the other
  (that is Part-2 migration work with its own gates).
- **ABI-suffix confusion.** §6.E's census counts *C symbols*; the table is keyed on Mono names. V8 in
  `validationErrors` fails any row that smuggles `_Int`/`Elm_Kernel_` into a key.
- **Anchor drift is chronic** — twenty-two drifts recorded in one day (Phase 0 table). Keep the
  linter; keep the evidence strings repo-relative so it works.
- **The export is not always the namespace function of the same name.** `Elm_Kernel_Utils_equal`
  and `_notEqual` both route through `equalRespectingConstants` (UtilsExports.cpp:94-105); the
  namespace `Utils::notEqual` (Utils.cpp:805-807) is dead. Audits that start at
  `<Module>.cpp::<name>` instead of at the `extern "C"` entry will read the wrong body — always
  start at `*Exports.cpp` and follow the calls.
- **Derived-helper name collision (cross-plan).** The record form `gcLeafEligible : KernelFacts ->
  Bool` and the key form `gcLeafEligibleFor : ( Name, Name ) -> Bool` are different functions, and
  Elm cannot overload. kernel-opt-08's draft calls the record-form NAME with a key argument; that is
  a compile error and is listed as a defect for 08 to fix under Dependencies §2b. Do not "resolve"
  it by renaming the record form — kernel-opt-11 and -12 both call `droppable f` on a record.
- **fprintf deletion is observable.** Adversarial E2E cases exercising cross-tag `==` would lose
  stderr lines; the Phase-5 baseline grep exists so that fact is *measured*, not assumed. Any
  golden-stderr expectation must be updated deliberately, not silenced.
- **New `.elm` file ⇒ CMake reconfigure.** `file(GLOB_RECURSE ELM_SOURCES …)` runs at configure time
  (compiler/CMakeLists.txt:126-129); without `cmake --preset build`, the new module is invisible to
  dependency tracking and stale builds look mysteriously green.

## Dependencies

- **Unblocks (spine 07 → {03, 08, 11, 12, 13}):** kernel-opt-03-value-eq-fastpath.md,
  kernel-opt-08-kernel-gcleaf-stamp.md (which in turn gates
  kernel-opt-09-gcprepare-barrier-relaxation.md), kernel-opt-11-mono-dce-cost-model.md,
  kernel-opt-12-eco-call-purity-attr.md, kernel-opt-13-mono-cse.md.
- **Depends on:** nothing in the series. Independent of kernel-opt-01/02/04/05/06/14.
- **External:** none. CafHoist/CafDedupe remain default-off (Compiler/Eco/Config.elm:321) and
  behaviourally unchanged.
- **Cross-plan contract this plan PINS for the other five:**
  1. Module path `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, keys `(home, name)` = Mono names.
  2. Field list and constructor names exactly as in Phase 1; derived facts computed via
     `canTriggerGC` / `gcLeafEligible` / `droppable` / `hoistable` — **consumers must call the derived
     helpers, never re-derive from raw fields** (the raw `callTimeEffect` default is `EffObservableIO`,
     not `EffNone`, precisely so a careless read is conservative).
  2b. **Two forms per derived fact, and the names are NOT interchangeable.** Elm has no overloading,
     so the record form is `gcLeafEligible : KernelFacts -> Bool` (called on a row you already
     looked up — kernel-opt-11 `KernelFacts.droppable facts`, kernel-opt-12 `droppable f`) and the
     key form is `gcLeafEligibleFor : ( Name, Name ) -> Bool` (whitelist default `False` folded in),
     with `droppableFor` / `hoistableFor` alongside. **Defect to fix in kernel-opt-08:** its
     Files-touched row and its Phase-1 sketch call `KernelFacts.gcLeafEligible ( key.home, key.name )`
     and its Dependencies section asks 07 to expose `gcLeafEligible : ( Name, Name ) -> Bool`. That
     name is taken by the record form that 11/12 rely on; 08's call site must read
     `KernelFacts.gcLeafEligibleFor ( key.home, key.name )`. 07 cannot rename the record form without
     breaking 11/12, so the key form carries the suffix.
  2c. Consumers MAY add further **computed** projections to `KernelFacts.elm` (kernel-opt-11's
     `CostClass(..)`/`costClass`, kernel-opt-12's `mlirSymbolIsDroppable`/`droppableSymbols`/
     `normalizeAbiVariant`, each with its own exposing-list entry). They MAY NOT add a stored field
     to the record, and `normalizeAbiVariant` must be implemented on top of `splitSymbol` rather
     than as a private second stripper.
  3. `KernelFacts.lookupSymbol` (and the exposed `splitSymbol` under it) is the ONE
     mangled-symbol → Mono-key path; kernel-opt-12 is its consumer. kernel-opt-08 does not use it —
     it threads `home`/`name` into `Ctx.KernelDeclInfo` as a new `gcLeaf : Bool` instead.
  4. The MLIR declaration attribute is the single `eco.gc_leaf`; kernel-opt-09's per-call marker is
     `eco.callee_gc_leaf`; kernel-opt-12's Elm-level channel is `eco.cse_safe` on `eco.call`. There is
     no `eco.kernel_cannot_gc`.
  5. `Borrow/KernelSigs.elm` remains the borrow-side name — consumers must not import `KernelFacts`
     for borrow modes.

## Expected impact

**Wall: FLAT, and this plan says so.** It is a table plus one fprintf deletion — squarely in the
metadata-only class that has measured wall-flat five consecutive times (preserve-cc, the gc-leaf pilot
at 64.1% *dynamic* coverage, capacity-check hoisting, the compare phases). What it buys instead:

- One audited effect model replacing three contradictory ones — `forall k. impure` and
  `forall k not-in Debug. pure` can no longer both be held by passes in the same pipeline.
- Deletion of a real UB data race + observable side effect on the equality path that takes
  **282,801,940 calls (7.69% of 3.676B) per Stage-7a self-compile** and holds 1,357 static sites
  (+63 via `Utils_notEqual`, which inherits it).
- The audited substrate for five sibling plans; the A1 stampable set alone (14 declarations ≈ 2,866
  static sites, 16.9%) becomes actionable for kernel-opt-08.
- Inconsistency becomes a compiler test failure rather than a latent miscompile; anchor rot becomes a
  linter hit rather than an archaeology exercise.

## Gates

Run each ONCE, tee to the named file, then grep the file (never re-run to re-read).

- **G1 — front-end unit tests:**
  `cd /work && cmake --preset build && cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`,
  then `grep -nE "KernelFacts|failed|passed" /tmp/test_output.txt`. Expect the 7 new suites green and
  the pre-existing suite count unchanged. (`cmake --preset build` is mandatory, not optional — new
  `.elm` file under `compiler/src`, configure-time `GLOB_RECURSE`.)
- **G2 — full E2E (never `check`, codegen-adjacent C++ changed):**
  `cd /work && cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, then
  `grep -nE "FAILED|PASSED|\[eq\] tag mismatch" /tmp/test_output.txt`. Expect all green and **zero**
  `[eq] tag mismatch` lines (compare with `/tmp/test_output_pre.txt` from Phase 5 step 1).
- **G3 — heap-validate suite.** `ECO_HEAP_VALIDATE` is a **configure-time CMake option**
  (`option(ECO_HEAP_VALIDATE …)` default OFF, CMakeLists.txt:84-89, which sets the
  `ECO_HEAP_VALIDATE=1` compile definition) — it is **not** a runtime env var, so exporting it
  before the test binary does nothing. The `dev` preset's `binaryDir` is `${sourceDir}/debug`
  (CMakePresets.json:6-19), so:
  ```bash
  cd /work && cmake --preset dev -DECO_HEAP_VALIDATE=ON
  cmake --build debug --target test 2>&1 | tee /tmp/heapvalidate_output.txt
  ./debug/test 2>&1 | tee -a /tmp/heapvalidate_output.txt
  grep -nE "failed|FAILED|passed" /tmp/heapvalidate_output.txt
  ```
  Expect the same pass/fail counts as a pre-change run of the identical command — **record the
  baseline number, do not assume it** (the historical figure has been quoted as both 1623/1623 and
  1632/1632 in different memories). The C++ edit removes only stderr writes, so any delta here is a
  build-hygiene problem, not a semantic one.
- **G4 — bootstrap fixed point:**
  `cd /work && cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap_output.txt`, then
  `grep -nE "identical|differ|FAILED|Stage (4b|8c|9b)" /tmp/bootstrap_output.txt`. Expect the Stage-4b
  JS fixed point and the Stage-8c native byte-identity to hold. **This is a same-fixed-point gate, not
  a new one:** the compiler's emitted output is unchanged (the table is inert), even though the
  compiler *binary* shrinks by the deleted trace because it links elm-kernel-cpp. If `out.mlir` ever
  differs, the "inert data" claim is false — stop and find the consumer that read the table.
- **G5 — borrow identity (the flag-substitute).** `ECO_BORROW=off|1|rc` and `ECO_BORROW_REPORT=1`
  are real env vars read in `Builder/Eco/Config.elm:212`/`:217` (`ECO_BORROW_REPORT` is output-only
  and excluded from `Config.hash`, :456-458 — which is exactly why the *artifact* cache is blind to
  it and the run must be forced). Run the SAME command twice, once on the pre-change tree and once
  on the post-change tree, each into its own throwaway builddir so no cached `.mlir` short-circuits
  the compile:
  ```bash
  # 1) BEFORE the change (clean tree, or `git stash`):
  cd /work/test/elm && rm -rf /tmp/kf-bd-before && ECO_BORROW=1 ECO_BORROW_REPORT=1 \
      node /work/compiler/bin/index.js make src/DictDiffFoldlStringKeysTest.elm \
      --output=/tmp/kf-borrow-before.mlir --builddir=/tmp/kf-bd-before 2>/tmp/borrow_before.txt
  # 2) AFTER (rebuild stage 1 first: cmake --preset build && cmake --build build):
  cd /work/test/elm && rm -rf /tmp/kf-bd-after && ECO_BORROW=1 ECO_BORROW_REPORT=1 \
      node /work/compiler/bin/index.js make src/DictDiffFoldlStringKeysTest.elm \
      --output=/tmp/kf-borrow-after.mlir --builddir=/tmp/kf-bd-after 2>/tmp/borrow_after.txt
  diff /tmp/borrow_before.txt /tmp/borrow_after.txt
  diff /tmp/kf-borrow-before.mlir /tmp/kf-borrow-after.mlir
  ```
  Expect BOTH diffs EMPTY — every counter (`kernelSigHits`, `kernelDefaultedHeapCalls`,
  `kernelDefaultedNames`, `poisonedByKernel`) identical, and the emitted MLIR byte-identical. A
  nonzero census diff means the shim's `params = []` sentinel discipline was broken somewhere in
  the seed table (a class-B row grew borrow modes, or a class-A row lost them); a nonzero MLIR diff
  means the "inert data" claim is false. `test/elm/src/DictDiffFoldlStringKeysTest.elm` exists and
  is Dict/compare-heavy, so it exercises the `Utils`/`String` rows that matter here.
- **G6 — anchor linter:** the Phase 0 one-liner; `/tmp/kernelfacts_anchors.txt` empty.
- **G7 — D3 row review:** every row reviewed in the borrow-census evidence-anchor style — claim, C++
  anchor, adversarial case considered, and rejected-row rationale kept in the module comment (the
  existing rejected list — `File.fileExists`/`dirExists` File.cpp:679/684, `Env.lookup` Env.cpp:52,
  `Scheduler.spawn` Scheduler.cpp:467 — moves verbatim from KernelSigs.elm:24-27 into KernelFacts).
