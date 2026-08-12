module Compiler.GlobalOpt.KernelFacts exposing
    ( KernelFacts, CallTimeEffect(..), GcAlloc(..), Totality(..), ParamMode(..)
    , lookup, lookupSymbol, splitSymbol, rows
    , canTriggerGC, gcLeafEligible, droppable, hoistable
    , gcLeafEligibleFor, droppableFor, hoistableFor
    , CostClass(..), costClass
    , validationErrors
    )

{-| The single audited source of per-kernel semantic facts
(design\_docs/kernel-boundary-reduction.md §6.C1;
plans/kernel-opt-07-kernel-facts-table.md).

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
have different names.

Each stored field has exactly one C++ question behind it. Rejected rows
(POwned, do NOT add — Console.write precedent, the result is a `Task_Binding`
capturing the arg): `File.fileExists`/`dirExists`
(eco-kernel-cpp/src/eco/File.cpp:679/684), `Env.lookup`
(eco-kernel-cpp/src/eco/Env.cpp:52), `Scheduler.spawn`
(runtime/src/platform/Scheduler.cpp:467).

TODO cost axis: `MonoInlineSimplify.computeCost` still prices every kernel at a
flat 1 (:1230-1231). §6.C1 leaves this out of v1 — a cost model needs
measurement, not audit.

@docs KernelFacts, CallTimeEffect, GcAlloc, Totality, ParamMode
@docs lookup, lookupSymbol, splitSymbol, rows
@docs canTriggerGC, gcLeafEligible, droppable, hoistable
@docs gcLeafEligibleFor, droppableFor, hoistableFor
@docs CostClass, costClass
@docs validationErrors

-}

import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


{-| What the kernel does, observably, at the moment it is called.
-}
type CallTimeEffect
    = EffNone -- nothing observable at call time (incl. Task builders, KERNEL_TASK_IO_001)
    | EffObservableIO -- stdio / fs / net / calls the app; ALSO the "unknown" answer
    | EffRuntimeState -- mutates runtime-internal tables (regex cache, port registry)
    | EffNoreturn -- exit()/abort — never returns


{-| Eco-heap allocation performed by the call.
-}
type GcAlloc
    = GcNone -- provably zero Eco-heap allocation on EVERY path
    | GcFixed Int -- <= N objects of statically known shapes per call
    | GcUnbounded -- input-dependent; ALSO the "unknown" answer


{-| Whether the call always returns normally.
-}
type Totality
    = Total
    | Throws
    | MayDiverge


{-| Borrow mode of one parameter.
-}
type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- may store, return, or hand to unknown code


{-| One audited row.
-}
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


{-| A call can trigger a GC if it allocates or if it can run Elm code.
-}
canTriggerGC : KernelFacts -> Bool
canTriggerGC f =
    f.gcAlloc /= GcNone || f.callsBackIntoElm


{-| Exactly what the `eco.gc_leaf` declaration attribute means (kernel-opt-08).
-}
gcLeafEligible : KernelFacts -> Bool
gcLeafEligible f =
    not (canTriggerGC f)


{-| An unused result may be deleted (kernel-opt-11/12).
-}
droppable : KernelFacts -> Bool
droppable f =
    f.cseSafe && f.totality == Total


{-| Two identical calls may be merged (kernel-opt-10/13).
-}
hoistable : KernelFacts -> Bool
hoistable f =
    f.cseSafe


{-| Inliner cost class (kernel-opt-11 (b)), DERIVED — never stored.

There is deliberately no `CInline` case: whether a symbol lowers to an inline op
rather than a call is a property of `Generate.MLIR.Intrinsics`, not of this
audit, and is queried there. This type says only what the AUDIT knows — whether
the callee can allocate, and whether it can re-enter Elm.

-}
type CostClass
    = CGcLeaf -- plain leaf call: no Elm GC, no C++ heap traffic, no callback
    | CAlloc -- allocates on the Elm heap or the C++ heap
    | CHof -- re-enters Elm through a user closure


{-| Classify for the cost model. Ordered most-expensive-first: re-entering Elm
dominates allocating, which dominates a plain leaf call.
-}
costClass : KernelFacts -> CostClass
costClass f =
    if f.callsBackIntoElm then
        CHof

    else if f.gcAlloc /= GcNone || f.cppAlloc then
        CAlloc

    else
        CGcLeaf



-- KEY FORMS: same facts, whitelist default folded in. An unlisted key answers
-- False for all three, which is every consumer's status-quo behaviour. These
-- exist so a consumer holding a key (kernel-opt-08's `KernelInstanceKey`) does
-- not have to spell `lookup >> Maybe.map … >> Maybe.withDefault False` and
-- accidentally pick `withDefault True`.


{-| Key form of `gcLeafEligible`; unlisted ⇒ False.
-}
gcLeafEligibleFor : ( Name, Name ) -> Bool
gcLeafEligibleFor key =
    lookup key |> Maybe.map gcLeafEligible |> Maybe.withDefault False


{-| Key form of `droppable`; unlisted ⇒ False.
-}
droppableFor : ( Name, Name ) -> Bool
droppableFor key =
    lookup key |> Maybe.map droppable |> Maybe.withDefault False


{-| Key form of `hoistable`; unlisted ⇒ False.
-}
hoistableFor : ( Name, Name ) -> Bool
hoistableFor key =
    lookup key |> Maybe.map hoistable |> Maybe.withDefault False



-- LOOKUP


{-| The whole table, keyed by Mono `(home, name)`.
-}
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



-- THE TABLE
--
-- 52 rows = 48 kernel rows + 4 Basics_* A6-ledger rows. The 48 are the 33
-- legacy Borrow/KernelSigs keys (so borrow behaviour is bit-identical through
-- the shim) plus 15 new effect-audited keys from §6.E. Class A rows carry an
-- effect verdict; class B rows are legacy borrow rows whose C++ body has NOT
-- been re-read for effects, so they are built from `unaudited` and license
-- nothing. Promoting a class-B row to class A is a separate, reviewed change.
--
-- Every anchor was opened and verified in the tree on 2026-08-10.


{-| The audited rows, in table order. Exposed so tests (and censuses) can walk
the whole table without a second copy of the keys.
-}
rows : List ( ( Name, Name ), KernelFacts )
rows =
    -- ── A1: gc-leaf eligible AND cseSafe (the kernel-opt-08 stampable 14) ──
    [ ( ( "Utils", "equal" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True -- dictEq uses std::vector working stacks
            , divergence = Just "depth > 100 returns true (elm-kernel-cpp/src/core/Utils.cpp:560-563): deep unequal values compare equal; cmp has no such cap"
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:107-109 (equalRespectingConstants :94-105); elm-kernel-cpp/src/core/Utils.cpp:470-472 (eqHelp :521-734, dictEq :747-797); runtime/src/allocator/StringOps.hpp:1486-1533; runtime/src/allocator/HeapHelpers.hpp:822"
        }
      )
    , ( ( "Utils", "notEqual" )
        -- Same body as `equal`: the extern is `!equalRespectingConstants(…)`.
        -- Every field must MATCH the `equal` row, which is why the two rows are
        -- edited together, never separately.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , divergence = Just "inherits equal's depth > 100 cap (elm-kernel-cpp/src/core/Utils.cpp:560-563)"
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:111-113 (= !equalRespectingConstants :94-105; NOT Utils::notEqual at elm-kernel-cpp/src/core/Utils.cpp:799-801, which has no callers)"
        }
      )
    , ( ( "Utils", "compare" )
        -- GcNone because the three Order results are PRE-allocated singletons;
        -- the only alloc::custom calls are in initOrderSingletons, whose sole
        -- caller is the one-time runtime-init hook. A reviewer who reads only
        -- elm-kernel-cpp/src/core/ListExports.cpp:718 ("Utils::compare may
        -- allocate") concludes the opposite, so the hook is named below.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:13-16; elm-kernel-cpp/src/core/Utils.cpp:451-457 (cmp :302-445, NDEBUG-UB note :214-217); Order singletons initOrderSingletons :33-45 (roots :41-43) called only from elm-kernel-cpp/src/core/UtilsExports.cpp:186-188; runtime/src/allocator/StringOps.hpp:1544-1608"
        }
      )
    , ( ( "Utils", "lt" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:115-117; elm-kernel-cpp/src/core/Utils.cpp:803-805 (cmp :302)"
        }
      )
    , ( ( "Utils", "le" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:119-121; elm-kernel-cpp/src/core/Utils.cpp:807-809"
        }
      )
    , ( ( "Utils", "gt" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:123-125; elm-kernel-cpp/src/core/Utils.cpp:811-813"
        }
      )
    , ( ( "Utils", "ge" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:127-129; elm-kernel-cpp/src/core/Utils.cpp:815-817"
        }
      )
    , ( ( "String", "length" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:18-27; runtime/src/allocator/StringOps.hpp:239-243"
        }
      )
    , ( ( "String", "startsWith" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:106-108; runtime/src/allocator/StringOps.hpp:688-714 (memcmp tiers)"
        }
      )
    , ( ( "String", "endsWith" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:110-112; runtime/src/allocator/StringOps.hpp:719-748"
        }
      )
    , ( ( "String", "contains" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:114-116; runtime/src/allocator/StringOps.hpp:645-683 (charAt :410-463 alloc-free)"
        }
      )
    , ( ( "Bytes", "getStringWidth" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True -- u16string snapshot
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:309-366 (u16string snapshot :330-338)"
        }
      )
    , ( ( "Bytes", "width" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:299-301 (raw scalar via elm_bytebuffer_len)"
        }
      )
    , ( ( "Bytes", "decodeFailure" )
      , { auditedPure
            | gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:469-471; runtime/src/allocator/HeapHelpers.hpp:196 (alloc::nothing() = embedded constant)"
        }
      )

    -- ── A2: audited pure, allocating (cseSafe, NOT gc-leaf) ──
    , ( ( "List", "cons" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:276-283; runtime/src/allocator/HeapHelpers.hpp:630"
        }
      )
    , ( ( "Utils", "append" )
        -- kernel-opt-05 filled the borrow axes: OWNER over BOTH string and list.
        -- makeRope stores both operands as GC roots and ListOps::append aliases
        -- the rhs into the result tail, and copy-vs-rope is a RUNTIME decision on
        -- byte length that a static (home, name) sig cannot discriminate -- so
        -- the poisoned heap args are not recoverable (borrow-inf-census.md:883-897
        -- CORRECTION 2026-07-27).
      , { auditedPure
            | params = [ POwned, POwned ]
            , resultAliases = [ 0, 1 ]
            , gcAlloc = GcUnbounded
            , cppAlloc = True
            , divergence = Just "unsupported tag pair silently returns the first argument (elm-kernel-cpp/src/core/Utils.cpp:845-846) instead of failing"
            , evidence = "elm-kernel-cpp/src/core/Utils.cpp:823-847; runtime/src/allocator/StringOps.hpp:477-537; runtime/src/allocator/ListOps.cpp:262"
        }
      )
    , ( ( "List", "reverse" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:651-654; runtime/src/allocator/ListOps.cpp:530"
        }
      )
    , ( ( "Bytes", "read_u32" )
      , { auditedPure
            | gcAlloc = GcFixed 1 -- Tuple2
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:539-547"
        }
      )
    , ( ( "String", "slice" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 2 ]
            , gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:56-59; runtime/src/allocator/StringOps.cpp:307-473 (interior views :337/:415, whole-string identity :321)"
        }
      )
    , ( ( "String", "cons" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:40-44; runtime/src/allocator/StringOps.hpp:1241-1270"
        }
      )
    , ( ( "JsArray", "empty" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:192-195"
        }
      )
    , ( ( "JsArray", "initializeFromList" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:457-461 (base export; the ABI variant _Int is :982, same Mono key)"
        }
      )

    -- ── A3: Task constructors (EffNone per KERNEL_TASK_IO_001,
    -- design_docs/invariants.csv:590 — the IO fires when the scheduler steps
    -- the binding, not at kernel-call time) ──
    , ( ( "Scheduler", "succeed" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:16-21; runtime/src/platform/Scheduler.cpp:123-126"
        }
      )
    , ( ( "Scheduler", "fail" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:23-28; runtime/src/platform/Scheduler.cpp:139-142"
        }
      )
    , ( ( "Scheduler", "andThen" )
        -- NOT a HOF: it stores the closure in the Task, never applies it.
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:30-37; runtime/src/platform/Scheduler.cpp:149-152"
        }
      )
    , ( ( "Scheduler", "onError" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:39-46; runtime/src/platform/Scheduler.cpp:154-157"
        }
      )
    , ( ( "MVar", "put" )
      , { auditedPure
            | gcAlloc = GcFixed 1 -- the binding
            , evidence = "eco-kernel-cpp/src/eco/MVarExports.cpp:38-46; eco-kernel-cpp/src/eco/MVar.cpp:290"
        }
      )
    , ( ( "MVar", "read" )
      , { auditedPure
            | gcAlloc = GcFixed 1 -- the binding
            , evidence = "eco-kernel-cpp/src/eco/MVarExports.cpp:30-32; eco-kernel-cpp/src/eco/MVar.cpp:264"
        }
      )

    -- ── A4: HOFs — effect/alloc/totality all join over the user closure, so
    -- these keep every conservative default from `unaudited` ──
    , ( ( "JsArray", "foldl" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:651-653; foldImpl :576 (final accumulator returned by identity when it stayed boxed, :636-640)"
        }
      )
    , ( ( "JsArray", "foldr" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:655-657; foldImpl :576"
        }
      )
    , ( ( "JsArray", "map" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:463"
        }
      )
    , ( ( "JsArray", "initialize" )
      , { unaudited
            | evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:422 (base export; the ABI variant _Int is :948, same Mono key)"
        }
      )
    , ( ( "List", "map2" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:592-600; kernelListMapN :432"
        }
      )
    , ( ( "List", "sortBy" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , totality = Throws
            , divergence = Just "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and relies on Utils::cmp's early returns"
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:677 (comparator :722-736); elm-kernel-cpp/src/core/Utils.cpp:305-306"
        }
      )
    , ( ( "List", "sortWith" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , totality = Throws
            , divergence = Just "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and relies on Utils::cmp's early returns"
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:751 (comparator :722-736); elm-kernel-cpp/src/core/Utils.cpp:305-306"
        }
      )
    , ( ( "String", "all" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:305 (snapshotChars copies; fn args are unboxed Chars)"
        }
      )

    -- ── B: borrow-legacy rows. The C++ body has NOT been re-read for effects,
    -- so all four derived facts are False and every consumer keeps its default.
    -- Only the borrow axis is carried over from Borrow/KernelSigs.elm. ──
    , ( ( "JsArray", "length" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:204-208"
        }
      )
    , ( ( "JsArray", "unsafeGet" )
        -- C signature is `unsafeGet index array`: array is param 1; aliases an
        -- element only in the boxed branch (:221).
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:210-223"
        }
      )
    , ( ( "Debug", "toString" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/DebugExports.cpp:56"
        }
      )
    , ( ( "Bytes", "encode" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:395 (writeEncoder :144)"
        }
      )
    , ( ( "Bytes", "decode" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 0, 1 ]
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:418"
        }
      )
    , ( ( "String", "uncons" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:46-49; runtime/src/allocator/StringOps.cpp:1009"
        }
      )
    , ( ( "String", "words" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:71; elm-kernel-cpp/src/core/String.cpp:286"
        }
      )
    , ( ( "String", "trim" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:91; runtime/src/allocator/StringOps.hpp:878"
        }
      )
    , ( ( "String", "toLower" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:86; runtime/src/allocator/StringOps.hpp:801"
        }
      )
    , ( ( "String", "toUpper" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:81; runtime/src/allocator/StringOps.hpp:762"
        }
      )
    , ( ( "Debug", "log" )
        -- The one row CafHoist gets right today: it prints.
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , callTimeEffect = EffObservableIO
            , evidence = "elm-kernel-cpp/src/core/DebugExports.cpp:26"
        }
      )
    , ( ( "Crash", "crash" )
        -- gcAlloc stays GcUnbounded (not §6.E's GcNone): Crash::crash calls
        -- toString(message) at eco-kernel-cpp/src/eco/Crash.cpp:21, which is
        -- unread. A noreturn call is never a useful gc-leaf, so the
        -- conservative value costs nothing.
      , { unaudited
            | params = [ PBorrowed ]
            , callTimeEffect = EffNoreturn
            , totality = MayDiverge
            , divergence = Just "prints to stderr + backtrace then ::exit(1) - never returns"
            , evidence = "eco-kernel-cpp/src/eco/CrashExports.cpp:9-11; eco-kernel-cpp/src/eco/Crash.cpp:20-33 (toString :21, fprintf :22/:26, ::exit(1) :30)"
        }
      )

    -- ── A6 divergence ledger (R8): ledger-only rows. NO borrow entry (params =
    -- [] ⇒ the shim reports a miss ⇒ Constrain/LssFacts keep today's poison
    -- path) and no audited axis beyond what the ledger states. They exist so the
    -- divergence is recorded before any Part-2 migration touches these symbols.
    -- `evidence` is still MANDATORY (rule V1). ──
    , ( ( "Basics", "modBy" )
      , { unaudited
            | totality = Throws
            , divergence = Just "C++ THROWS std::runtime_error on modulus 0 (elm-kernel-cpp/src/core/Basics.cpp:92-103, throw at :96); the intrinsic returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131). A PAP-captured modBy 0 terminates through statepointed frames; an inlined one returns 0."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:92-103; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131"
        }
      )
    , ( ( "Basics", "idiv" )
      , { unaudited
            | divergence = Just "C++ is bare a / b: UB / SIGFPE on 0 (elm-kernel-cpp/src/core/Basics.cpp:88-90); the intrinsic is guarded and returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:57-81)."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:88-90; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:57-81"
        }
      )
    , ( ( "Basics", "remainderBy" )
      , { unaudited
            | divergence = Just "C++ UB on divisor 0 (elm-kernel-cpp/src/core/Basics.cpp:105-107); the intrinsic is guarded and returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:133-157)."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:105-107; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:133-157"
        }
      )
    , ( ( "Basics", "tan" )
      , { unaudited
            | divergence = Just "C++ is std::tan (elm-kernel-cpp/src/core/Basics.cpp:40-42); the intrinsic composes sin(x)/cos(x) (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:324-337) - differs in the last ulp and at poles."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:40-42; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:324-337"
        }
      )
    ]



-- VALIDATION
--
-- Elm cannot fail a BUILD on data, so "build-time validation" means a compiler
-- unit test that runs on every elm-tests invocation and blocks the merge
-- (compiler/tests/Compiler/GlobalOpt/KernelFactsTest.elm, suite 1).


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
