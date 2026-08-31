module Compiler.MonoSolver.Monomorphize exposing (monomorphize, monomorphizeWithReport)

{-| The solver-based monomorphizer (Architecture C) — a drop-in replacement for
`Compiler.Monomorphize.Monomorphize`, using the type checker's real HM
unification engine (`Compiler.Type.Unify` / `UnionFind`) instead of the
Dict-substitution engine.

**No fallback.** This engine never consults the original one. A construct it
cannot yet handle returns `Err "MonoSolver.unsupported: <what>"` through the
normal `Result String MonoGraph` channel, which the pipeline surfaces as a loud
build failure. It must NOT import `Compiler.Monomorphize.TypeSubst` or
`.Specialize`, and works only from the total `meta.tipe` (never `meta.tvar`).

The driver mirrors the original phase-for-phase: shared input prep (flags
decoder, MVarId assignment), seed main + flags decoder, LIFO worklist drain, then
assemble and hand off to the shared `Prune.pruneUnreachableSpecs` (which closes
residual number vars and recomputes ctor shapes). Only the per-node
specialization is the new solver engine.

@docs monomorphize

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Prune as Prune
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), S, WorkItem(..))
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.Store as Store
import Compiler.MonoSolver.LssInfer as LssInfer
import Compiler.MonoSolver.Translate as Translate
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import System.TypeCheck.IO as IO


{-| Transform a typed optimized graph into a monomorphized graph, entering from
the named entry point. Same as the original engine plus the LSS knobs (the
original engine never computes sets; `lss.enabled = False` here is
byte-identical to it).
-}
monomorphize : Config.LssConfig -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphize lssConfig entryPointName globalTypeEnv globalGraph =
    Result.map Tuple.first (monomorphizeWithReport lssConfig Config.defaultLimits entryPointName globalTypeEnv globalGraph)


{-| `monomorphize` additionally returning the rendered LSS census
(`Just` iff `lss.report`). The report rides the result because this function
is pure and `compiler/src` cannot use `Debug.toString` — the census is plain
string concatenation, printed to stderr by the Builder.

Also the MONO_030 limits entry point: the Builder passes
`ecoConfig.mono.limits` (env-overridable); the plain `monomorphize` wrapper
defaults them, so test call sites are unchanged.
-}
monomorphizeWithReport : Config.LssConfig -> Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String ( Mono.MonoGraph, Maybe String )
monomorphizeWithReport lssConfig limits entryPointName globalTypeEnv globalGraph =
    let
        ( graphWithFlags, maybeFlagsGlobal ) =
            EntryPrep.insertFlagsDecoderNode entryPointName globalGraph

        ( TOpt.GlobalGraph nodesWithIds _ annotationsWithIds _ _, mvarState ) =
            AssignMVarIds.assignIds lssConfig.arrowSolverRoots lssConfig.arrowCensus graphWithFlags
    in
    case EntryPrep.findEntryPointId entryPointName nodesWithIds of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            let
                mainHome : IO.Canonical
                mainHome =
                    case mainGlobal of
                        TOpt.Global home _ ->
                            home

                s0 : S
                s0 =
                    initState lssConfig limits mainHome nodesWithIds annotationsWithIds globalTypeEnv mvarState

                -- Entry seeding uses an EMPTY super table (matching the original
                -- engine's `entryPointMonoType Dict.empty`).
                mainMonoType : Mono.MonoType
                mainMonoType =
                    Zonk.canTypeToMono Dict.empty mainType

                -- Registration self-identity (AR-7): the seeds bypass
                -- `enqueueSpec`, so they stamp here or not at all. Main and
                -- the flags decoder are non-arrow types today, making this a
                -- structural no-op — but AR-11 says an unstamped demand
                -- ⊤-collapses a stored type, so the route exists for the day
                -- an entry global IS an arrow. The Err fallback keeps the
                -- seed unstamped; sound (entry globals have no other
                -- callers to join with), and unreachable while the types
                -- are non-arrows.
                ( mainSpecId, s1 ) =
                    case Translate.stampSelfSpine mainGlobal mainMonoType s0 of
                        Ok ( stampedMain, s0b ) ->
                            seedSpec (toptToMonoGlobal mainGlobal) stampedMain s0b

                        Err _ ->
                            seedSpec (toptToMonoGlobal mainGlobal) mainMonoType s0

                ( maybeFlagsSpecId, s2 ) =
                    seedFlagsDecoder maybeFlagsGlobal nodesWithIds s1
            in
            case drain s2 of
                Err failure ->
                    Err (renderFailure failure)

                Ok sDrained ->
                    let
                        -- lss.destrAnno FIX B (plans/lss-ctor-arrow-identity.md
                        -- §9.8): ctor registry rows recover their ⊤ field
                        -- annotations from the COMPLETE union of the ctor's
                        -- specs' demands. Post-drain is load-bearing for
                        -- soundness: a translation-time read sees a PARTIAL
                        -- union, and a set stamped from it excludes
                        -- constructions that have not happened yet — the
                        -- false-singleton miscompile class. Here every
                        -- construction has contributed, so union-widening
                        -- (AR-D2) holds and the pass is a single order-free
                        -- sweep.
                        sFinal =
                            settleCtorRows sDrained

                        graph =
                            pruneGraph sFinal (assembleRawGraph sFinal mainSpecId maybeFlagsSpecId)

                        report =
                            if lssConfig.report then
                                Just (renderLssReport sFinal graph)

                            else
                                Nothing
                    in
                    Ok ( graph, report )


{-| lss.destrAnno FIX B — the post-drain ctor-row settle (§9.8). For every
registry entry whose node is a `TOpt.Ctor`/`Box` and whose stored type still
carries ⊤: enrich its annotations from the set-biased union of ALL entries of
the same ctor global (`Mono.enrichAnnotations`-folded — a ⊤ contributes
nothing, sets union). Precision-monotone, structure untouched (MONO_029),
complete-union sound (AR-D2). One sweep; no fixpoint needed — the unions are
final. No-op flag-off and for globals with a single all-⊤ entry.
-}
settleCtorRows : S -> S
settleCtorRows s =
    if not (s.env.lss.enabled && s.env.lss.destrAnno) then
        s

    else
        let
            isCtorGlobal key =
                case key of
                    Mono.Global scHome scName ->
                        case HashMap.get TOpt.globalHash (==) (TOpt.Global scHome scName) s.env.toptNodes of
                            Just (TOpt.Ctor _ _ _) ->
                                True

                            Just (TOpt.Box _) ->
                                True

                            _ ->
                                False

                    _ ->
                        False

            gkeyOf key =
                case key of
                    Mono.Global scHome scName ->
                        Mono.toComparableGlobal (Mono.Global scHome scName)

                    _ ->
                        "?"

            -- pass 1: set-biased unions per ctor global
            unions =
                Array.foldl
                    (\entry acc ->
                        case entry of
                            Just ( key, monoType ) ->
                                if isCtorGlobal key then
                                    Dict.update (gkeyOf key)
                                        (\v ->
                                            Just
                                                (case v of
                                                    Just u ->
                                                        Mono.enrichAnnotations u monoType

                                                    Nothing ->
                                                        monoType
                                                )
                                        )
                                        acc

                                else
                                    acc

                            Nothing ->
                                acc
                    )
                    Dict.empty
                    s.registry.reverseMapping

            -- pass 2: enrich ⊤-carrying ctor rows from their union
            registry1 =
                Tuple.second
                    (Array.foldl
                        (\entry ( idx, reg ) ->
                            case entry of
                                Just ( key, monoType ) ->
                                    if isCtorGlobal key && Mono.hasTopAnno monoType then
                                        case Dict.get (gkeyOf key) unions of
                                            Just u ->
                                                let
                                                    enriched =
                                                        Mono.enrichAnnotations monoType u
                                                in
                                                if enriched == monoType then
                                                    ( idx + 1, reg )

                                                else
                                                    ( idx + 1, Registry.updateRegistryType idx enriched reg )

                                            Nothing ->
                                                ( idx + 1, reg )

                                    else
                                        ( idx + 1, reg )

                                Nothing ->
                                    ( idx + 1, reg )
                        )
                        ( 0, s.registry )
                        s.registry.reverseMapping
                    )
        in
        { s | registry = registry1 }


{-| The LSS census (design §8.6): member counts, set-size histogram, widening
events by cause, signature memo stats, and the top per-global spec counts.
Rendered post-prune; plain string concatenation only.
-}
renderLssReport : S -> Mono.MonoGraph -> String
renderLssReport sFinal (Mono.MonoGraph g) =
    let
        stats =
            sFinal.lssStats

        lambdaCount =
            Dict.size sFinal.env.lamLabels

        internedCount =
            Dict.size sFinal.lssMemberTable.byKey

        sigCount =
            Dict.size sFinal.lssSignatures

        trivialCount =
            Dict.foldl
                (\_ sig n ->
                    if sig.trivial then
                        n + 1

                    else
                        n
                )
                0
                sFinal.lssSignatures

        histLine =
            if Dict.isEmpty stats.sizeHist then
                "(none)"

            else
                String.join " "
                    (Dict.foldr (\size count acc -> (String.fromInt size ++ "->" ++ String.fromInt count) :: acc) [] stats.sizeHist)

        specCounts =
            Array.foldl
                (\maybeEntry acc ->
                    case maybeEntry of
                        Just ( global, _ ) ->
                            let
                                k =
                                    Mono.toComparableGlobal global
                            in
                            Dict.insert k (1 + Maybe.withDefault 0 (Dict.get k acc)) acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        topSpecs =
            Dict.toList specCounts
                |> List.sortBy (\( _, n ) -> negate n)
                |> List.take 5
                |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                |> String.join " "

        widenedHistLine =
            if Dict.isEmpty stats.widenedSizeHist then
                "(none)"

            else
                String.join " "
                    (Dict.foldr (\size count acc -> (String.fromInt size ++ "->" ++ String.fromInt count) :: acc) [] stats.widenedSizeHist)

        kernelMissLine =
            if Dict.isEmpty stats.kernelMissHist then
                "(none)"

            else
                Dict.toList stats.kernelMissHist
                    |> List.sortBy (\( _, n ) -> negate n)
                    |> List.take 12
                    |> List.map (\( k, n ) -> k ++ "=" ++ String.fromInt n)
                    |> String.join " "

        -- ===== The resolution ledger (plans/lss-unknown-elimination.md §2.5)
        --
        -- The acceptance metric for the unknown-elimination arc: what fraction
        -- of arrow positions the analysis can give a CONCRETE answer for, and
        -- how many of those answers are genuinely multi-member. Derived
        -- entirely from counters that already exist — no new instrumentation:
        --
        --   concrete k=1 = sizeHist[1]
        --   concrete k>=2 = sum over k>=2 of sizeHist[k]
        --   over-cap     = widenedBySize   (resolved, then discarded by maxSetSize)
        --   top          = causePoison + causeEdgeTop
        --   var          = causeFlex   + causeEdgeEmpty   (Phase 3: LVar)
        --   ------------------------------------------
        --   total        = setsZonked
        --
        -- and the identity `sum sizeHist == causeSet + causeEdgeSet` closes it.
        --
        -- RECONCILES is the point of the line: it is a self-check that fires
        -- the moment a new zonk cause arm is added to `Store.LssZonkAcc`
        -- without being wired in here. Any new arm MUST land in exactly one of
        -- the five buckets above.
        --
        -- CAVEAT that must ride with every quote of these numbers: the `zc|`
        -- cause counters are gated by `censusOn = env.lss.report`
        -- (`Store.bumpCauseC`) and read 0 without ECO_MONO_LSS_REPORT=1.
        -- `sizeHist`/`widenedBySize` are unconditional. This whole report only
        -- renders under `lss.report`, so the line is always self-consistent —
        -- but never compare it against an arm measured with the flag off.
        --
        -- SECOND CAVEAT (§2.5.5): these are per-ZONK-READBACK counts, not per
        -- distinct arrow position. A hot slot read 50 times counts 50 times.
        -- Sound as a relative signal across arms of the same corpus; NOT an
        -- answer to "how many positions did we resolve".
        censusAt key =
            Maybe.withDefault 0 (Dict.get key stats.sigStats.argFlowCensus)

        ledgerK1 =
            Maybe.withDefault 0 (Dict.get 1 stats.sizeHist)

        ledgerKN =
            Dict.foldl
                (\size count acc ->
                    if size >= 2 then
                        acc + count

                    else
                        acc
                )
                0
                stats.sizeHist

        ledgerTop =
            censusAt "zc|all|poison" + censusAt "zc|all|edgeTop"

        -- Phase 3: this bucket is `LVar` — a set VARIABLE, "to be determined".
        -- It was Phase 1's `LUnknown`, and before that it was silently inside
        -- `top`. The census keys keep their historical names so the rows stay
        -- joinable against every earlier arm.
        ledgerUnknown =
            censusAt "zc|all|flex" + censusAt "zc|all|edgeEmpty"

        ledgerSum =
            ledgerK1 + ledgerKN + stats.widenedBySize + ledgerTop + ledgerUnknown

        multiSetArrowHist =
            let
                h =
                    Dict.foldl (\_ ms acc -> Dict.insert (List.length ms) (1 + Maybe.withDefault 0 (Dict.get (List.length ms) acc)) acc) Dict.empty stats.sigStats.multiSetsByArrow
            in
            if Dict.isEmpty h then
                "(none)"

            else
                String.join " " (Dict.foldr (\k v acc -> (String.fromInt k ++ "->" ++ String.fromInt v) :: acc) [] h)

        -- ===== The SETTLED ledger (plans/lss-post-mono-architecture.md §3.2)
        --
        -- The same readbacks as `ledgerLine`, replayed at `finishNode` — after
        -- the item finished writing rather than during. Same variables, same
        -- multiplicity, so `total` must MATCH the in-flight `setsZonked` and
        -- only the buckets may move. `MATCHES=NO` means the log lost readbacks
        -- (a missed clear on a store swap, or a zonk outside any item) and the
        -- deltas below are then meaningless — a bug signal, not a finding.
        --
        -- Because `resetItem` gives every work item a FRESH store, this is not
        -- an approximation of a post-mono read: it is the complete UPPER BOUND
        -- on what reading-later can buy inside the current architecture.
        settled =
            stats.sigStats.settled

        settledK1 =
            Maybe.withDefault 0 (Dict.get 1 settled.hist)

        settledKN =
            Dict.foldl
                (\size count acc ->
                    if size >= 2 then
                        acc + count

                    else
                        acc
                )
                0
                settled.hist

        settledSum =
            settledK1 + settledKN + settled.widenedBySize + settled.causeTop + settled.causeVar

        -- §5.1 `Q` IN SHADOW MODE. The GATE is the `REPRODUCES` verdict: `Q`
        -- must reproduce the eager answer everywhere the eager answer is
        -- defined, so every `diverge*` bucket is a defect report on the
        -- RECORDING, not a result about the program. `unresolved` is the
        -- separate, legitimate population — classes with no eager answer at
        -- item end, i.e. what a per-item store cannot settle and a def-boundary
        -- solve could carry.
        q =
            stats.sigStats.qShadow

        qi =
            stats.sigStats.qInfer

        qiDiverge =
            qi.divergeSuper + qi.divergeSub + qi.divergeTop + qi.divergeOther

        qInferLine =
            "Q-infer: constraints="
                ++ String.fromInt (qi.members + qi.tops + qi.edges)
                ++ " (members="
                ++ String.fromInt qi.members
                ++ " tops="
                ++ String.fromInt qi.tops
                ++ " edges="
                ++ String.fromInt qi.edges
                ++ ") units="
                ++ String.fromInt qi.items
                ++ " classes="
                ++ String.fromInt qi.classes
                ++ " agree="
                ++ String.fromInt qi.agree
                ++ " diverge="
                ++ String.fromInt qiDiverge
                ++ "(super="
                ++ String.fromInt qi.divergeSuper
                ++ " sub="
                ++ String.fromInt qi.divergeSub
                ++ "[merged="
                ++ String.fromInt qi.subMerged
                ++ " unseen="
                ++ String.fromInt qi.subUnseen
                ++ "] top="
                ++ String.fromInt qi.divergeTop
                ++ " other="
                ++ String.fromInt qi.divergeOther
                ++ ") | partition reaching="
                ++ String.fromInt qi.reaching
                ++ " internal="
                ++ String.fromInt qi.internal
                ++ "(agree="
                ++ String.fromInt qi.internAgree
                ++ " diverge="
                ++ String.fromInt qi.internDiverge
                ++ ") REPRODUCES="
                ++ (if qiDiverge == 0 then
                        "yes"

                    else
                        "NO"
                   )

        qDiverge =
            q.divergeSuper + q.divergeSub + q.divergeTop + q.divergeOther

        qDefined =
            q.classes - q.unresolved

        qLine =
            "Q-shadow: constraints="
                ++ String.fromInt (q.members + q.tops + q.edges)
                ++ " (members="
                ++ String.fromInt q.members
                ++ " tops="
                ++ String.fromInt q.tops
                ++ " edges="
                ++ String.fromInt q.edges
                ++ ") items="
                ++ String.fromInt q.items
                ++ " classes="
                ++ String.fromInt q.classes
                ++ " defined="
                ++ String.fromInt qDefined
                ++ " agree="
                ++ String.fromInt q.agree
                ++ " diverge="
                ++ String.fromInt qDiverge
                ++ "(super="
                ++ String.fromInt q.divergeSuper
                ++ " sub="
                ++ String.fromInt q.divergeSub
                ++ "[merged="
                ++ String.fromInt q.subMerged
                ++ " unseen="
                ++ String.fromInt q.subUnseen
                ++ "]"
                ++ " top="
                ++ String.fromInt q.divergeTop
                ++ " other="
                ++ String.fromInt q.divergeOther
                ++ ") unresolved="
                ++ String.fromInt q.unresolved
                ++ " edgeOnly="
                ++ String.fromInt q.edgeClasses
                ++ " scratchDropped="
                ++ String.fromInt q.scratchDropped
                ++ " | partition sigRoots="
                ++ String.fromInt q.sigRoots
                ++ " reaching="
                ++ String.fromInt q.reaching
                ++ " internal="
                ++ String.fromInt q.internal
                ++ "(agree="
                ++ String.fromInt q.internAgree
                ++ " diverge="
                ++ String.fromInt q.internDiverge
                ++ ")"
                ++ " REPRODUCES="
                ++ (if qDiverge == 0 then
                        "yes"

                    else
                        "NO"
                   )

        qSampleLines =
            String.join "\n" q.divergeSamples

        settledLine =
            "ledger-settled: k1="
                ++ String.fromInt settledK1
                ++ " kN="
                ++ String.fromInt settledKN
                ++ " overcap="
                ++ String.fromInt settled.widenedBySize
                ++ " top="
                ++ String.fromInt settled.causeTop
                ++ " var="
                ++ String.fromInt settled.causeVar
                ++ " total="
                ++ String.fromInt settled.zonked
                ++ " items="
                ++ String.fromInt settled.items
                ++ " RECONCILES="
                ++ (if settledSum == settled.zonked then
                        "yes"

                    else
                        "NO(" ++ String.fromInt settledSum ++ ")"
                   )
                ++ " MATCHES="
                ++ (if settled.zonked == stats.setsZonked then
                        "yes"

                    else
                        -- A shortfall is EXPECTED, not automatically a bug:
                        -- readbacks made inside a scratch store
                        -- (`Engine.withScratchStore`) are counted in-flight but
                        -- cannot be replayed — those Points die with the
                        -- scratch store. `scratchCalls` is how many logged
                        -- readback CALLS were dropped that way; if the
                        -- shortfall tracks it, the ledger is reconciled and
                        -- only an UNEXPLAINED shortfall is a log bug.
                        "NO(inflight="
                            ++ String.fromInt stats.setsZonked
                            ++ " short="
                            ++ String.fromInt (stats.setsZonked - settled.zonked)
                            ++ " scratchCalls="
                            ++ String.fromInt settled.scratchDropped
                            ++ ")"
                   )
                ++ " dVar="
                ++ String.fromInt (settled.causeVar - ledgerUnknown)
                ++ " dK1="
                ++ String.fromInt (settledK1 - ledgerK1)
                ++ " dKN="
                ++ String.fromInt (settledKN - ledgerKN)

        -- §3.2's actual stop criterion. Of the arrows still reading back a
        -- VARIABLE after their item settled, how many have members recorded —
        -- from some OTHER item — in the global `multiSetsByArrow` table?
        --
        --   known    the information exists in the program but not in this
        --            item's store, which per-item teardown can never fix and a
        --            solve over one global graph would. This is the prize.
        --   unknown  nothing anywhere writes that arrow (kernel/FFI/port/Debug
        --            boundary). No reordering reaches it; the ceiling is Eco's
        --            setting, not its schedule.
        --
        -- Reads 0/0 unless arrow identity is on — `arrowOfSlot` is empty
        -- otherwise, so there is no key to attribute a readback to.
        -- Scored against `setArrows` — every arrow that read back a CONCRETE
        -- set of ANY size, anywhere in the run — NOT against
        -- `multiSetsByArrow`, which is gated at |set| >= 2. An arrow resolved
        -- to a SINGLETON in another item is still known elsewhere; scoring it
        -- against the multi-set table alone would misfile it as unconstrained
        -- and overstate the kernel-boundary ceiling.
        settledKnownElsewhere =
            Dict.foldl
                (\akey n ( known, unknown ) ->
                    if Dict.member akey settled.setArrows then
                        ( known + n, unknown )

                    else
                        ( known, unknown + n )
                )
                ( 0, 0 )
                settled.varArrows

        settledArrowLine =
            let
                ( known, unknown ) =
                    settledKnownElsewhere

                knownArrows =
                    Dict.foldl
                        (\akey _ n ->
                            if Dict.member akey settled.setArrows then
                                n + 1

                            else
                                n
                        )
                        0
                        settled.varArrows
            in
            "settled-var-arrows: varArrows="
                ++ String.fromInt (Dict.size settled.varArrows)
                ++ " setArrows="
                ++ String.fromInt (Dict.size settled.setArrows)
                ++ " attributed="
                ++ String.fromInt (known + unknown)
                ++ " ofVar="
                ++ String.fromInt settled.causeVar
                ++ " knownElsewhere="
                ++ String.fromInt known
                ++ "/"
                ++ String.fromInt knownArrows
                ++ "arr unknownEverywhere="
                ++ String.fromInt unknown
                ++ "/"
                ++ String.fromInt (Dict.size settled.varArrows - knownArrows)
                ++ "arr"

        -- ARTIFACT COVERAGE (2026-08-26): the position-based completeness
        -- metric. One tally per arrow per SPECIALIZATION, taken from the
        -- registry's stored types — i.e. the signature of every specialized
        -- function in the emitted program. Unlike the ledger below this has a
        -- FIXED denominator (it does not move with how many times the analysis
        -- reads a slot), which is what makes it gateable.
        coverage =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( _, monoType ) ->
                            Mono.annoCoverage monoType acc

                        Nothing ->
                            acc
                )
                Mono.emptyAnnoCoverage
                g.registry.reverseMapping

        coverageLine =
            let
                concrete =
                    coverage.k1 + coverage.kN

                positions =
                    concrete + coverage.var + coverage.top
            in
            "coverage: positions="
                ++ String.fromInt positions
                ++ " k1="
                ++ String.fromInt coverage.k1
                ++ " kN="
                ++ String.fromInt coverage.kN
                ++ " var="
                ++ String.fromInt coverage.var
                ++ " top="
                ++ String.fromInt coverage.top
                ++ " coveredBp="
                ++ String.fromInt
                    (if positions == 0 then
                        0

                     else
                        (10000 * concrete) // positions
                    )

        -- PROVENANCE (plans/lss-provenance-ratio-census.md): layer-1 fidelity —
        -- how much of the paper's `ζ = 𝓔(ξ)` survived into LSS at all. An arrow
        -- reaches `AssignMVarIds` either carrying `SolverRoot` (the checker's
        -- identity survived) or `NoArrow` (the lockstep stamping walk lost it,
        -- or it was built after the solve). Only the first kind can participate
        -- in an 𝓔 equality, so `withRoot / arrows` bounds from ABOVE how much of
        -- the paper's constraint generation we are capable of reproducing.
        --
        -- This is the layer the shadow `Q` verifier CANNOT see: `Q` re-solves
        -- the constraints we emitted, so a constraint never emitted is absent
        -- from its input and from its verdict. `REPRODUCES=yes` is evidence
        -- about solving only.
        --
        -- `tieBp` is the necessary companion: provenance alone is not
        -- information. If every arrow sat in its own root class, 𝓔 would be the
        -- identity relation and a perfect `provBp` would be worth nothing.
        -- `tieBp` is the share of provenance-carrying arrows that share a class
        -- with at least one other arrow — the part that can actually tie.
        --
        -- UPPER BOUND, not a prediction: tying two slots that are both empty
        -- changes nothing, so `1 - prov` bounds the damage rather than
        -- forecasting a coverage gain. And the denominator is PROGRAM arrows at
        -- AssignMVarIds time, NOT the artifact positions `coverage:` counts —
        -- different populations, never divide one into the other.
        provenanceLine =
            let
                arrows =
                    sFinal.env.arrowTotal

                withRoot =
                    Dict.size sFinal.env.arrowRootOf

                rootClasses =
                    sFinal.env.arrowRootClasses

                bp num den =
                    if den <= 0 then
                        0

                    else
                        (10000 * num) // den
            in
            "provenance: arrows="
                ++ String.fromInt arrows
                ++ " withRoot="
                ++ String.fromInt withRoot
                ++ " rootClasses="
                ++ String.fromInt rootClasses
                ++ " provBp="
                ++ String.fromInt (bp withRoot arrows)
                ++ " tieBp="
                ++ String.fromInt (bp (withRoot - rootClasses) withRoot)
                ++ " SANE="
                ++ (if
                        arrows
                            >= withRoot
                            && withRoot
                            >= rootClasses
                            && rootClasses
                            >= 0
                            && (withRoot == 0)
                            == (rootClasses == 0)
                    then
                        "yes"

                    else
                        "NO"
                   )

        -- POSITION ATTRIBUTION (plans/lss-ctor-arrow-identity.md §3 P0): one row
        -- per UNCOVERED arrow position, naming the global and the structural
        -- path to the arrow. The aggregate `coverage:` line says HOW MANY
        -- positions are uncovered; this says WHICH — which is what makes a
        -- prediction like "the ctor spine ordinals will flip" falsifiable
        -- BEFORE any mechanism is built.
        --
        -- A path-carrying SIBLING of `Mono.annoCoverage` rather than an
        -- extension of it: that walker runs over every registry entry on every
        -- compile and must stay allocation-free.
        --
        -- Path syntax: `a<n>` argument n, `r` result, `l` list element,
        -- `t<n>` tuple slot, `f:<name>` record field, `c<n>` custom-type arg.
        -- The arrow itself is the position; its path is where it sits.
        --
        -- Report-gated AND flag-gated (rides `lss.arrowCensus`): probe-scale
        -- output is a dozen rows, self-compile scale is tens of thousands.
        posWalk path monoType acc =
            case monoType of
                Mono.MFunction _ anno args result ->
                    let
                        acc1 =
                            case anno of
                                Mono.LSet [ _ ] ->
                                    -- L4 P0 instrument
                                    -- (plans/lss-coverage-four-levers.md
                                    -- §1.4): covered positions emit too,
                                    -- so the transport candidate set —
                                    -- (global, path) LSet in one spec,
                                    -- LVar in another — is computable
                                    -- post-hoc from one census log.
                                    ( path, "k1" ) :: acc

                                Mono.LSet _ ->
                                    ( path, "kN" ) :: acc

                                Mono.LVar vn ->
                                    -- P0.a (plans/lss-ctor-arrow-identity.md
                                    -- §8.1): the zonked flex id, so the
                                    -- MIRROR hypothesis (one write filling
                                    -- several positions) is decidable from
                                    -- one census log. Ids are canonical per
                                    -- SLOT within ONE entry's zonk only
                                    -- (AR-v2-7), so the row builder prefixes
                                    -- the entry index.
                                    ( path, "var@" ++ String.fromInt vn ) :: acc

                                Mono.LTop tpK ->
                                    -- §4.9: pos| rows carry the birth kind
                                    -- (`top@abi` etc.) — position-level
                                    -- provenance in one census log.
                                    ( path, "top@" ++ Mono.topKindLabel tpK ) :: acc

                        accR =
                            posWalk (path ++ "/r") result acc1
                    in
                    List.foldl
                        (\( i, a ) accA ->
                            posWalk (path ++ "/a" ++ String.fromInt i) a accA
                        )
                        accR
                        (List.indexedMap Tuple.pair args)

                Mono.MList _ inner ->
                    posWalk (path ++ "/l") inner acc

                Mono.MTuple _ elems ->
                    List.foldl
                        (\( i, e ) accE ->
                            posWalk (path ++ "/t" ++ String.fromInt i) e accE
                        )
                        acc
                        (List.indexedMap Tuple.pair elems)

                Mono.MRecord _ fields ->
                    Dict.foldl (\fname t a -> posWalk (path ++ "/f:" ++ fname) t a) acc fields

                Mono.MCustom _ _ _ args ->
                    List.foldl
                        (\( i, a ) accA ->
                            posWalk (path ++ "/c" ++ String.fromInt i) a accA
                        )
                        acc
                        (List.indexedMap Tuple.pair args)

                _ ->
                    acc

        posRows =
            Tuple.second
                (Array.foldl
                    (\entry ( idx, acc ) ->
                        case entry of
                            Just ( key, monoType ) ->
                                let
                                    gname =
                                        case key of
                                            Mono.Global _ n ->
                                                n

                                            _ ->
                                                "?"

                                    -- P0.a: qualify var ids by ENTRY — a flex
                                    -- number is canonical only within the
                                    -- entry that zonked it.
                                    qualify kind =
                                        if String.startsWith "var@" kind then
                                            "var@" ++ String.fromInt idx ++ "." ++ String.dropLeft 4 kind

                                        else
                                            kind
                                in
                                ( idx + 1
                                , List.map (\( pth, kind ) -> "pos|" ++ gname ++ "|" ++ pth ++ "|" ++ qualify kind)
                                    (posWalk "" monoType [])
                                    ++ acc
                                )

                            Nothing ->
                                ( idx + 1, acc )
                    )
                    ( 0, [] )
                    g.registry.reverseMapping
                )

        posLine =
            String.join "\n" (List.sort posRows)

        -- ⊤ SITE SPLIT (plans/lss-provenance-join-and-demand-sigs.md §4.6):
        -- with rsTop healing the recoverable placeholder class at licensed
        -- kernel-alias joins, the SURVIVING ⊤s are an undifferentiated mix.
        -- Classify each final-registry ⊤ position by its NODE class — the
        -- census attributes by SITE (which mechanism could still reach it),
        -- not by HISTORY (placeholder-vs-poison transport needs the Part-A
        -- provenance bit).
        --   licAlias   licensed kernel alias whose stored side stayed ⊤ —
        --              the demands never established a set: inherited-unknown
        --              (transported poison OR a genuinely unknown callback).
        --   refAlias   TypeFaithful row exists but the license refused this
        --              occurrence type (LSS_022 fail-safe).
        --   unlicAlias kernel alias with NO row — recoverable by audit.
        --   elm/cycle  ⊤ manufactured or absorbed in an Elm body (conflict
        --              joins, widening, transported poison).
        --   ctor/port/manager/accessor/none — the rest, named.
        topSiteClassOf key =
            case key of
                Mono.Global tsHome tsName ->
                    topSiteClassOfGlobal (TOpt.Global tsHome tsName)

                _ ->
                    "accessor"

        topSiteClassOfGlobal tsGlobal =
            case HashMap.get TOpt.globalHash (==) tsGlobal sFinal.env.toptNodes of
                Nothing ->
                    "none"

                Just node ->
                    case LssInfer.kernelAliasOf tsGlobal sFinal of
                        Just ( _, kHome, kName ) ->
                            if licensedKernelAliasNode node sFinal then
                                "licAlias"

                            else
                                case KernelSetFacts.factFor kHome kName of
                                    Just _ ->
                                        "refAlias"

                                    Nothing ->
                                        "unlicAlias"

                        Nothing ->
                            case node of
                                TOpt.Define _ _ _ ->
                                    "elm"

                                TOpt.TrackedDefine _ _ _ _ ->
                                    "elm"

                                TOpt.Cycle _ _ _ _ ->
                                    "cycle"

                                TOpt.Ctor _ _ _ ->
                                    "ctor"

                                TOpt.Enum _ _ ->
                                    "ctor"

                                TOpt.Box _ ->
                                    "ctor"

                                TOpt.Kernel _ _ ->
                                    "kernelDef"

                                TOpt.Manager _ ->
                                    "manager"

                                TOpt.PortIncoming _ _ _ ->
                                    "port"

                                TOpt.PortOutgoing _ _ _ ->
                                    "port"

                                TOpt.Link target ->
                                    -- Chase to the linked target's class
                                    -- (kernelAliasOf already chased the
                                    -- ALIAS case; this attributes the rest).
                                    topSiteClassOfGlobal target

        topPosClassOf pth =
            if pth == "" then
                "head"

            else if List.all (\seg -> seg == "r") (List.filter (\x -> x /= "") (String.split "/" pth)) then
                "spine"

            else
                "nested"

        topSiteAndKindCounts =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case List.filter (\( _, kind ) -> String.startsWith "top" kind) (posWalk "" monoType []) of
                                [] ->
                                    acc

                                tops ->
                                    let
                                        cls =
                                            topSiteClassOf key
                                    in
                                    List.foldl
                                        (\( pth, kindTag ) ( accSite, accKind ) ->
                                            let
                                                kindLabel =
                                                    String.dropLeft 4 kindTag

                                                bump k d =
                                                    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d
                                            in
                                            ( bump (cls ++ "|" ++ topPosClassOf pth) accSite
                                            , bump (kindLabel ++ "|" ++ cls) accKind
                                            )
                                        )
                                        acc
                                        tops

                        Nothing ->
                            acc
                )
                ( Dict.empty, Dict.empty )
                g.registry.reverseMapping

        -- §9.6 step 4 — Fix B's P0, the END-OF-RUN half. For every ctor-node
        -- registry entry, compare it position-wise against the set-biased
        -- union of ALL entries of the same ctor global (self included — a ⊤
        -- contributes nothing under the enrich fold). `top,k1` counts the
        -- positions a completion-time/late recovery could flip to a
        -- singleton: the order-free CEILING, against `destrBnow`'s
        -- translation-time floor. GO for building Fix B: k1+kN ≥ 300 (§9.6).
        ctorGlobalKeyOf key =
            case key of
                Mono.Global cgHome cgName ->
                    if topSiteClassOf key == "ctor" then
                        Just (TOpt.toComparableGlobal (TOpt.Global cgHome cgName))

                    else
                        Nothing

                _ ->
                    Nothing

        ctorUnions =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case ctorGlobalKeyOf key of
                                Just gk ->
                                    Dict.update gk
                                        (\v ->
                                            Just
                                                (case v of
                                                    Just u ->
                                                        Mono.enrichAnnotations u monoType

                                                    Nothing ->
                                                        monoType
                                                )
                                        )
                                        acc

                                Nothing ->
                                    acc

                        Nothing ->
                            acc
                )
                Dict.empty
                g.registry.reverseMapping

        destrBendCounts =
            Array.foldl
                (\entry acc ->
                    case entry of
                        Just ( key, monoType ) ->
                            case ctorGlobalKeyOf key of
                                Just gk ->
                                    case Dict.get gk ctorUnions of
                                        Just u ->
                                            countTopCells monoType u acc

                                        Nothing ->
                                            acc

                                Nothing ->
                                    acc

                        Nothing ->
                            acc
                )
                ( 0, 0, 0 )
                g.registry.reverseMapping

        countTopCells a b acc =
            case ( a, b ) of
                ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
                    if List.length argsA == List.length argsB then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac)
                            (countTopCells retA retB (countTopCell annoA annoB acc))
                            (List.map2 Tuple.pair argsA argsB)

                    else
                        acc

                ( Mono.MList _ xa, Mono.MList _ xb ) ->
                    countTopCells xa xb acc

                ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
                    if List.length xsa == List.length xsb then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac) acc (List.map2 Tuple.pair xsa xsb)

                    else
                        acc

                ( Mono.MRecord _ fa, Mono.MRecord _ fb ) ->
                    Dict.foldl
                        (\k va ac ->
                            case Dict.get k fb of
                                Just vb ->
                                    countTopCells va vb ac

                                Nothing ->
                                    ac
                        )
                        acc
                        fa

                ( Mono.MCustom _ _ _ xsa, Mono.MCustom _ _ _ xsb ) ->
                    if List.length xsa == List.length xsb then
                        List.foldl (\( x, y ) ac -> countTopCells x y ac) acc (List.map2 Tuple.pair xsa xsb)

                    else
                        acc

                _ ->
                    acc

        countTopCell annoA annoB acc =
            let
                ( nK1, nKN, nNo ) =
                    acc
            in
            case ( annoA, annoB ) of
                ( Mono.LTop _, Mono.LSet [ _ ] ) ->
                    ( nK1 + 1, nKN, nNo )

                ( Mono.LTop _, Mono.LSet _ ) ->
                    ( nK1, nKN + 1, nNo )

                ( Mono.LTop _, _ ) ->
                    ( nK1, nKN, nNo + 1 )

                _ ->
                    acc

        destrBendLine =
            let
                ( bK1, bKN, bNo ) =
                    destrBendCounts
            in
            "destrBend: k1=" ++ String.fromInt bK1 ++ " kN=" ++ String.fromInt bKN ++ " no=" ++ String.fromInt bNo

        topSiteLine =
            "top sites: "
                ++ String.join " "
                    (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                        (Dict.toList (Tuple.first topSiteAndKindCounts))
                    )

        -- §4.9: WHY (birth kind) × WHERE (node class) for every surviving ⊤.
        topKindLine =
            "top kinds: "
                ++ String.join " "
                    (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                        (Dict.toList (Tuple.second topSiteAndKindCounts))
                    )

        -- LIVENESS (plans/lss-provenance-ratio-census.md §7): of the arrows
        -- that read back as `var`, how many are ever APPLIED?
        --
        --   var AND applied   = a real call site whose target we cannot name.
        --                       The paper would have a set here; genuine
        --                       incompleteness, and the honest numerator.
        --   var NOT applied   = a function-typed position never invoked. `var`
        --                       is defensible and the paper would not have
        --                       needed a set — arguably not ours to count.
        --
        -- `controlBp` is NOT decoration and must be read FIRST. Concrete arrows
        -- are overwhelmingly ones we resolved because they are called, so if
        -- they do not register as applied the hook is not seeing applications
        -- and the var split above means NOTHING. A low control invalidates the
        -- finding; it does not become the finding.
        livenessLine =
            let
                applied =
                    stats.sigStats.appliedArrows

                countIn arrows =
                    Dict.foldl
                        (\akey _ n ->
                            if Dict.member akey applied then
                                n + 1

                            else
                                n
                        )
                        0
                        arrows

                varApplied =
                    countIn settled.varArrows

                setApplied =
                    countIn settled.setArrows

                bp num den =
                    if den <= 0 then
                        0

                    else
                        (10000 * num) // den
            in
            "liveness: attempts="
                ++ String.fromInt (censusAt "apply|attempt")
                ++ " hit="
                ++ String.fromInt (censusAt "apply|hit")
                ++ " noSlot="
                ++ String.fromInt (censusAt "apply|noSlot")
                ++ " noArrowId="
                ++ String.fromInt (censusAt "apply|noArrowId")
                ++ " hitBp="
                ++ String.fromInt (bp (censusAt "apply|hit") (censusAt "apply|attempt"))
                ++ " | appliedArrows="
                ++ String.fromInt (Dict.size applied)
                ++ " varArrows="
                ++ String.fromInt (Dict.size settled.varArrows)
                ++ " varApplied="
                ++ String.fromInt varApplied
                ++ " setArrows="
                ++ String.fromInt (Dict.size settled.setArrows)
                ++ " setApplied="
                ++ String.fromInt setApplied
                ++ " liveBp="
                ++ String.fromInt (bp varApplied (Dict.size settled.varArrows))
                ++ " controlBp="
                ++ String.fromInt (bp setApplied (Dict.size settled.setArrows))

        -- STAMPING-WALK CENSUS (plans/lss-provenance-ratio-census.md §8):
        -- WHERE the provenance loss happens. `SolverRoots.stampArrowRoots`
        -- returns a node unstamped AND unrecursed on a lockstep mismatch, so
        -- one failure sheds a whole subtree — meaning the `provenance:` loss
        -- could be a few big abandonments or many small ones, which call for
        -- opposite fixes.
        --
        --   partial — SOME arrows stamped, some not. The walk ran, descended,
        --             and broke: provable mid-walk abandonment. Repairing the
        --             walk reaches these.
        --   none    — NO arrow stamped. Never walked, or failed at the root.
        --             Repairing the walk does NOT reach these; the target
        --             would be post-solve type construction instead.
        --
        -- RECONCILES against the `provenance:` line: the two lost populations
        -- must sum to `arrows - withRoot`. A mismatch means the census wrapper
        -- missed a top-level `rewriteCanType` call site, so the line says so
        -- rather than being quietly believed.
        stampWalkLine =
            let
                lost =
                    sFinal.env.stampArrowsInNone + sFinal.env.stampArrowsUnstampedInPartial

                expected =
                    sFinal.env.arrowTotal - Dict.size sFinal.env.arrowRootOf
            in
            "stampwalk: types="
                ++ String.fromInt
                    (sFinal.env.stampTypesAll + sFinal.env.stampTypesNone + sFinal.env.stampTypesPartial)
                ++ " all="
                ++ String.fromInt sFinal.env.stampTypesAll
                ++ " none="
                ++ String.fromInt sFinal.env.stampTypesNone
                ++ " partial="
                ++ String.fromInt sFinal.env.stampTypesPartial
                ++ " | arrowsNone="
                ++ String.fromInt sFinal.env.stampArrowsInNone
                ++ " arrowsPartialUnstamped="
                ++ String.fromInt sFinal.env.stampArrowsUnstampedInPartial
                ++ " lostTotal="
                ++ String.fromInt lost
                ++ " expected="
                ++ String.fromInt expected
                ++ " RECONCILES="
                ++ (if lost == expected then
                        "yes"

                    else
                        "NO"
                   )

        ledgerLine =
            "ledger: k1="
                ++ String.fromInt ledgerK1
                ++ " kN="
                ++ String.fromInt ledgerKN
                ++ " overcap="
                ++ String.fromInt stats.widenedBySize
                ++ " top="
                ++ String.fromInt ledgerTop
                ++ " var="
                ++ String.fromInt ledgerUnknown
                ++ " total="
                ++ String.fromInt stats.setsZonked
                ++ " RECONCILES="
                ++ (if ledgerSum == stats.setsZonked then
                        "yes"

                    else
                        "NO(" ++ String.fromInt ledgerSum ++ ")"
                   )
    in
    String.join "\n"
        ([ "=== LSS census ==="
        , "members: " ++ String.fromInt sFinal.nextMemberId ++ " total (" ++ String.fromInt lambdaCount ++ " source lambdas, " ++ String.fromInt internedCount ++ " interned)"
        , "signatures: " ++ String.fromInt sigCount ++ " memoized (" ++ String.fromInt trivialCount ++ " trivial)"
        , "sets zonked: " ++ String.fromInt stats.setsZonked ++ "; size histogram: " ++ histLine
        , coverageLine
        , provenanceLine
        , ledgerLine
        , settledLine
        ]
            -- §7.7: the liveness line appears ONLY when its own flag ran the
            -- census. Under `report` alone the counters are all zero, and a
            -- zero row reads as "measured, found nothing" rather than "never
            -- executed" — the `qCensus` misreading, one flag along.
            ++ (if sFinal.env.lss.arrowCensus then
                    [ stampWalkLine, livenessLine, topSiteLine, topKindLine, destrBendLine, posLine ]

                else
                    []
               )
            ++ (if sFinal.env.lss.qCensus then
                    -- §5.1/§5.6: the shadow-`Q` verifier lines appear only when
                    -- the verifier RAN. Printing them under `lss.report` alone
                    -- would render all-zero counters as `REPRODUCES=yes`, which
                    -- reads as a passing check that never executed.
                    [ qInferLine, qLine, qSampleLines ]

                else
                    []
               )
            ++ [ settledArrowLine
        , "widened: bySize=" ++ String.fromInt stats.widenedBySize ++ " byKernel=" ++ String.fromInt stats.widenedByKernel ++ " byBudget=" ++ String.fromInt stats.widenedByBudget ++ " bySigSize=" ++ String.fromInt stats.sigStats.widenedBySigSize
        , "widened sizes: " ++ widenedHistLine
        , "join flush: rounds=" ++ String.fromInt stats.joinRounds ++ " retranslations=" ++ String.fromInt stats.retranslations

        -- Substrate census (Phase 1, plans/lss-set-write-substrate.md).
        , "set-writes: skip=" ++ String.fromInt stats.setWriteSkip ++ " flex=" ++ String.fromInt stats.setWriteFlex ++ " topJoin=" ++ String.fromInt stats.setWriteTopJoin ++ " union=" ++ String.fromInt stats.setWriteUnion ++ " slow=" ++ String.fromInt stats.setWriteSlow ++ " slotsMinted=" ++ String.fromInt stats.slotsMinted
        , "joins: identical=" ++ String.fromInt stats.joinIdenticalHit ++ " noop=" ++ String.fromInt stats.joinNoop ++ " changed=" ++ String.fromInt stats.joinChanged ++ " completion=" ++ String.fromInt stats.completionJoins ++ " completionNoop=" ++ String.fromInt stats.completionJoinNoop
        , "devirtDirect=" ++ String.fromInt stats.devirtDirect ++ " devirtKernel=" ++ String.fromInt stats.devirtKernel ++ " unqualifiedLambdaMints=" ++ String.fromInt stats.unqualifiedLambdaMints

        -- LSS_018 monitoring, derived FREE from implementation state at
        -- report time (the per-event fidelity counters were removed after
        -- their one-shot census — Run J: muTied=0 widenedByLet=672
        -- localMultiBypass=469; see plan §7). Meaningful under lss.muTie;
        -- reads 0 flag-off (tables are flag-gated).
        , "muTie: tied=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.muTied) ++ " qualifiedRecorded=" ++ String.fromInt (Dict.size sFinal.lssMemberTable.lambdaQualified)

        -- LSS_019 standalone-member grounding census
        -- (plans/lss-fidelity-2-standalone-member-grounding.md §5):
        -- `deferred` is the residual-arrow precision frontier.
        , "grounding: grounded=" ++ String.fromInt stats.grounding.grounded ++ " deferred=" ++ String.fromInt stats.grounding.deferred

        -- LSS_024 layout-qualification census
        -- (plans/lss-layout-qualified-members.md §2.5): `shared` = id reuse
        -- across distinct enclosing specs (the fix working), `fallback` =
        -- mints with no captured widened key (expected 0), `tieBypass` =
        -- §2.3 equal-id μ-tie bypasses. All 0 flag-off.
        , "layoutQual: mints=" ++ String.fromInt stats.layoutQual.mints ++ " shared=" ++ String.fromInt stats.layoutQual.shared ++ " fallback=" ++ String.fromInt stats.layoutQual.fallback ++ " tieBypass=" ++ String.fromInt stats.layoutQual.tieBypass

        -- LSS_020 signature-flow census
        -- (plans/lss-fidelity-3-signature-flow-completion.md §B.4):
        -- widenedByCf/kernelFactHits/kernelLicensed are report-gated bumps,
        -- so they read 0 unless ECO_MONO_LSS_REPORT was on for the run.
        -- LSS_022: kernelFactHits counts POSITIONAL row applications and
        -- kernelLicensed counts TypeFaithful pass-throughs — disjoint tiers,
        -- and only the former can also appear in widenedByKernel.
        , "sigflow: widenedByCf=" ++ String.fromInt stats.sigStats.widenedByCf ++ " kernelFactHits=" ++ String.fromInt stats.sigStats.kernelFactHits ++ " kernelLicensed=" ++ String.fromInt stats.sigStats.kernelLicensed ++ " edges=" ++ String.fromInt stats.sigStats.edgesInstalled ++ " degraded=" ++ String.fromInt stats.sigStats.flowDegraded

        -- LSS_026(a) honest ∅-as-source: how often a members-carrying
        -- resolution crossed a dangling (FlexVar) inflow and was widened to
        -- ⊤ rather than published as a false-COMPLETE set — signature side /
        -- demand side. Unconditional policy counters. The `ARGF` block below
        -- is the LSS census and is report-gated.
        , "honestSources: topMixedFlex=" ++ String.fromInt stats.sigStats.topMixedFlexSig ++ "/" ++ String.fromInt stats.sigStats.topMixedFlexDemand

        -- Multi-set census (M3): distinct ARROW POSITIONS carrying a
        -- multi-member set, which is the question `sizeHist`'s per-readback
        -- counting cannot answer. `readbacks` is the ledger's kN for contrast:
        -- positions << readbacks means a few hot arrows, positions ~ readbacks
        -- means a broad population.
        , "multisets: arrows=" ++ String.fromInt (Dict.size stats.sigStats.multiSetsByArrow) ++ " readbacks=" ++ String.fromInt ledgerKN ++ " byK=" ++ multiSetArrowHist
        , argFlowCensusBlock stats.sigStats.argFlowCensus
        , multiSetCensusBlock stats.sigStats.multiSetsByArrow sFinal.lssMemberTable

        -- Census (2026-07-21): E9.2 guard-decline split (declinedKernelCNumber
        -- = the E10.0 `declinedUnsettled` proxy) + the whitelist-growth list.
        , "kernel declines: shape=" ++ String.fromInt stats.declinedKernelShape ++ " cnumber=" ++ String.fromInt stats.declinedKernelCNumber ++ " emission=" ++ String.fromInt stats.declinedKernelEmission ++ " arity=" ++ String.fromInt stats.declinedKernelArity
        , "kernel whitelist misses: " ++ kernelMissLine
        , "kernel licenses REFUSED at the occurrence: "
            ++ (if Dict.isEmpty stats.kernelUnsolvedHist then
                    "(none)"

                else
                    String.join " "
                        (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
                            (List.sortBy (\( _, v ) -> -v) (Dict.toList stats.kernelUnsolvedHist))
                        )
               )
        , "top specs/global: " ++ topSpecs
        , "=================="
        ]
        )


{-| Multi-set census dump (M3). One `MSET\t<arrowId>\t<size>\t<memberKeys>`
line per ARROW that ever read back a multi-member set, sorted by arrow id so
two runs of the same tree produce byte-identical blocks.

**Keyed by ArrowId, and members rendered as KEYS, both deliberately.** ArrowIds
are minted by `AssignMVarIds` from the syntax and do not depend on any lss
flag, so they are the one identity that JOINS ACROSS ARMS — unlike symbol
names (`lambda_N` renumbers; runtime-calls Run AE) and unlike member ids
(`internMemberKey` assigns them in mint order, which differs per arm). The
member KEY string is stable, so an offline join can ask the question the
whole census exists for: is this multi-set present in BOTH arms — structural,
the analysis found genuine alternatives — or does it appear only when slot
sharing is on, i.e. merge-induced?

Empty (a single marker line) when the run was not report-gated.
-}
multiSetCensusBlock : Dict.Dict Int (List Int) -> Engine.LssMemberTable -> String
multiSetCensusBlock byArrow memberTable =
    if Dict.isEmpty byArrow then
        "MSET\t(none)\t0\t"

    else
        let
            keyOf =
                Dict.foldl (\k mid acc -> Dict.insert mid k acc) Dict.empty memberTable.byKey
        in
        String.join "\n"
            (List.map
                (\( akey, members ) ->
                    "MSET\t"
                        ++ String.fromInt akey
                        ++ "\t"
                        ++ String.fromInt (List.length members)
                        ++ "\t"
                        ++ String.join "|" (List.map (\m -> Maybe.withDefault ("?" ++ String.fromInt m) (Dict.get m keyOf)) members)
                )
                (Dict.toList byArrow)
            )


{-| LSS_026 Phase-0 census dump (plans/lss-gap2-callarg-transport.md §2.1):
one `ARGF\t<key>\t<count>` line per key, sorted by key so two runs of the
same tree produce byte-identical blocks (the census rail — compare as
multisets, never by line index). Empty (a single marker line) when the run
was not report-gated.
-}
argFlowCensusBlock : Dict.Dict String Int -> String
argFlowCensusBlock census =
    if Dict.isEmpty census then
        "ARGF\t(none)\t0"

    else
        String.join "\n"
            (List.map (\( k, v ) -> "ARGF\t" ++ k ++ "\t" ++ String.fromInt v)
                (List.sortBy Tuple.first (Dict.toList census))
            )



-- ====== INITIAL STATE ======


initState : Config.LssConfig -> Config.SpecLimits -> IO.Canonical -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.AnnotationsByGlobal TypeIds.MVarId -> TypeEnv.GlobalTypeEnv -> AssignMVarIds.GlobalMVarState -> S
initState lssConfig limits currentModule nodes annotations globalTypeEnv mvarState =
    { worklist = []
    , nodes = Array.empty
    , inProgress = BitSet.empty
    , scheduled = BitSet.empty
    , registry = Registry.emptyRegistry
    , ports = []
    , lambdaCounter = 0
    , superTable = mvarState.superVars
    , nextMVarId = mvarState.nextId
    , lssSignatures = Dict.empty
    , lssInProgress = Dict.empty
    , lssMemberTable = Engine.emptyMemberTable
    , nextMemberId = Id.toComparable mvarState.nextLam
    , lssStats = Engine.emptyLssStats
    , monoMemo = Engine.emptyMonoMemo
    , nodeResolution = Dict.empty
    , intern = Intern.empty
    , env =
        { -- 4c: one O(n) conversion at init (~10-20k globals) buys a
          -- string-build-free probe at every occurrence site. `DMap.foldl`
          -- ignores its ordering argument (Data/Map.elm:240-242); it is passed
          -- for documentation only.
          toptNodes =
            DMap.foldl TOpt.compareGlobal
                (\g node acc -> HashMap.insert TOpt.globalHash (==) g node acc)
                HashMap.empty
                nodes
        , annotations = annotations
        , globalTypeEnv = globalTypeEnv
        , currentModule = currentModule
        , superStatic = mvarState.superVars
        , lss = lssConfig
        , lssKeyedSet = keyedGlobalSet lssConfig.keyedGlobals
        , lamLabels = mvarState.lamLabels
        , arrowRootOf = mvarState.arrowRootOf

        -- Provenance census denominators, read once here rather than
        -- recomputed: `nextArrow` less its origin is every arrow occurrence
        -- stamped, and the negative root-key supply starts at -1 and
        -- decrements, so `-nextRootKey - 1` is the number of distinct solver
        -- root classes minted.
        , arrowTotal =
            Id.toComparable mvarState.nextArrow - Id.toComparable TypeIds.firstArrowId
        , arrowRootClasses = -mvarState.nextRootKey - 1
        , stampTypesAll = mvarState.typesAll
        , stampTypesNone = mvarState.typesNone
        , stampTypesPartial = mvarState.typesPartial
        , stampArrowsInNone = mvarState.arrowsInNone
        , stampArrowsUnstampedInPartial = mvarState.arrowsUnstampedInPartial
        , limits = limits
        }
    , currentGlobal = Nothing
    , store = Engine.freshStore
    , memo = Dict.empty
    , revMemo = Array.empty
    , varEnv = Dict.empty
    , numberMulti = []
    , localMulti = []
    , derivedDestructors = Dict.empty
    , localCanTypes = Dict.empty

    , dirtySpecs = BitSet.empty
    , dirtyList = []
    , specCountByGlobal = Dict.empty
    , itemAux = Engine.emptyItemAux
    , scratchRootKeys = False
    }


{-| E5: parse `lss.keyedGlobals` user entries
(`author/project:Module.Name.value`) into the comparable-gkey set the
`enqueueSpec` gate consults. The comparable shape must match
`Mono.toComparableGlobal`, so build a real `Mono.Global` and key it.
Unparseable entries are skipped (the Builder env override already warned).
-}
keyedGlobalSet : List String -> Dict.Dict String ()
keyedGlobalSet entries =
    List.filterMap parseKeyedGlobal entries
        |> List.map (\g -> ( Mono.toComparableGlobal g, () ))
        |> Dict.fromList


parseKeyedGlobal : String -> Maybe Mono.Global
parseKeyedGlobal entry =
    case String.split ":" entry of
        [ pkg, def ] ->
            case ( String.split "/" pkg, List.reverse (String.split "." def) ) of
                ( [ author, project ], valueName :: revModSegs ) ->
                    if List.isEmpty revModSegs then
                        Nothing

                    else
                        Just
                            (Mono.Global
                                (IO.Canonical ( author, project ) (String.join "." (List.reverse revModSegs)))
                                valueName
                            )

                _ ->
                    Nothing

        _ ->
            Nothing


seedSpec : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
seedSpec global monoType s =
    let
        ( specId, reg1 ) =
            Registry.getOrCreateSpecId global monoType s.registry

        -- LSS_024 §2.2: entry-seeded specs are keyed-ROUTED under the
        -- all-keyed default (the routing predicate is per-mint, not
        -- per-creation-path), so their bodies' lambda mints consult
        -- `specWidenedKeys` — capture here too, or every entry-global lambda
        -- takes the SpecId fallback and "fallback expected 0" is false by
        -- construction. One pure widenSets for the 1-2 seeded specs; the
        -- flags-decoder seed arrives through this same function.
        s1 =
            if s.env.lss.enabled && s.env.lss.layoutQualMembers then
                Engine.recordSpecWidenedKey specId
                    (Mono.toComparableMonoType (Mono.widenSets monoType))
                    s

            else
                s
    in
    ( specId
    , { s1
        | registry = reg1
        , worklist = SpecializeGlobal specId :: s1.worklist
        , scheduled = BitSet.insertGrowing specId s1.scheduled
      }
    )


seedFlagsDecoder : Maybe TOpt.Global -> DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> S -> ( Maybe Mono.SpecId, S )
seedFlagsDecoder maybeFlagsGlobal nodes s =
    case maybeFlagsGlobal of
        Nothing ->
            ( Nothing, s )

        Just flagsGlobal ->
            case EntryPrep.findNodeAnnotationType flagsGlobal nodes of
                Nothing ->
                    ( Nothing, s )

                Just decoderTipe ->
                    let
                        decoderMonoType =
                            Zonk.canTypeToMono Dict.empty decoderTipe

                        ( specId, s1 ) =
                            case Translate.stampSelfSpine flagsGlobal decoderMonoType s of
                                Ok ( stampedDec, sb ) ->
                                    seedSpec (toptToMonoGlobal flagsGlobal) stampedDec sb

                                Err _ ->
                                    seedSpec (toptToMonoGlobal flagsGlobal) decoderMonoType s
                    in
                    ( Just specId, s1 )



-- ====== WORKLIST DRAIN ======


drain : S -> Result Failure S
drain s =
    case s.worklist of
        [] ->
            -- LSS_010 drain-end flush: specs whose stored types were
            -- annotation-JOINED since their translation re-translate now,
            -- once per ROUND with their fully-joined demands (never once
            -- per join — that cascade was hour-scale on the self-compile).
            -- Each round only exists because some stored type CHANGED, and
            -- joins are monotone in a finite lattice, so rounds terminate;
            -- the cap turns a would-be livelock into a loud EngineBug.
            case s.dirtyList of
                [] ->
                    Ok s

                dirty ->
                    if s.lssStats.joinRounds >= maxJoinRounds then
                        Err
                            (EngineBug
                                ("LSS_010 join flush exceeded "
                                    ++ String.fromInt maxJoinRounds
                                    ++ " rounds ("
                                    ++ String.fromInt (List.length dirty)
                                    ++ " specs still dirty: "
                                    ++ String.join ", "
                                        (List.map
                                            (\sid ->
                                                case Registry.lookupSpecKey sid s.registry of
                                                    Just ( g, _ ) ->
                                                        Mono.toComparableGlobal g ++ "#" ++ String.fromInt sid

                                                    Nothing ->
                                                        "#" ++ String.fromInt sid
                                            )
                                            (List.take 5 dirty)
                                        )
                                    ++ ") — non-monotone join or registry/actualType oscillation"
                                )
                            )

                    else
                        let
                            stats0 =
                                s.lssStats
                        in
                        drain
                            { s
                                | worklist = List.map SpecializeGlobal dirty
                                , dirtyList = []
                                , lssStats = { stats0 | joinRounds = stats0.joinRounds + 1 }
                            }

        (SpecializeGlobal specId) :: rest ->
            case processItem specId { s | worklist = rest } of
                Err e ->
                    Err e

                Ok s1 ->
                    drain s1


{-| LSS_010 flush-round cap. Real programs stabilize in a handful of
rounds (set-flow chain depth); triple digits means something is
oscillating and must fail loudly rather than spin.
-}
maxJoinRounds : Int
maxJoinRounds =
    100


processItem : Mono.SpecId -> S -> Result Failure S
processItem specId s =
    if BitSet.member specId s.inProgress then
        -- Recursive self-reference: already being specialized; drop.
        Ok s

    else if nodeAlreadyDone specId s && not (BitSet.member specId s.dirtySpecs) then
        -- Stale duplicate work item: a LSS_010 re-push already satisfied by a
        -- later (re-)translation, or a duplicate re-push. Flag-off never
        -- reaches this (each spec is pushed exactly once).
        Ok s

    else
        case Registry.lookupSpecKey specId s.registry of
            Nothing ->
                Ok s

            Just ( global, monoType ) ->
                let
                    stats0 =
                        s.lssStats

                    stats1 =
                        if nodeAlreadyDone specId s then
                            { stats0 | retranslations = stats0.retranslations + 1 }

                        else
                            stats0

                    sItemR =
                        Engine.resetItem
                            { s
                                | inProgress = BitSet.insertGrowing specId s.inProgress
                                , currentGlobal = Just global
                                , lssStats = stats1

                                -- LSS_010: consume the dirty mark before
                                -- translating with the (joined) stored type; a
                                -- join arriving DURING this translation re-marks
                                -- it for the next flush round.
                                , dirtySpecs = BitSet.removeGrowing specId s.dirtySpecs
                            }

                    auxR =
                        sItemR.itemAux

                    -- Fix B (LSS_017): expose the spec being translated to the
                    -- lambda-instance member mints. AFTER resetItem — it
                    -- rebuilds itemAux. LSS_018 rides along: the μ-tie scan of
                    -- the STORED demand for qualified members of raw lambdas
                    -- (rebuilt per item, so LSS_010 re-translations re-tie
                    -- against the fully-joined demand — monotone).
                    sItem =
                        { sItemR
                            | itemAux =
                                { auxR
                                    | currentSpecId = Just specId
                                    , demandQualified = demandQualifiedFor monoType sItemR
                                }
                        }
                in
                case global of
                    Mono.Accessor fieldName ->
                        case monoType of
                            Mono.MFunction _ _ [ Mono.MRecord _ fields ] fieldType ->
                                Ok
                                    (finishNode specId
                                        (Mono.MonoTailFunc
                                            [ ( "record", Mono.mRecord fields ) ]
                                            (Mono.MonoRecordAccess (Mono.MonoVarLocal "record" (Mono.mRecord fields)) fieldName fieldType)
                                            monoType
                                        )
                                        sItem
                                    )

                            _ ->
                                Err (EngineBug ("accessor global " ++ fieldName ++ ": expected Mono.mFunction [Mono.mRecord] fieldType"))

                    Mono.Global home name ->
                        let
                            -- D13: resolve the node + its annotation-id set ONCE per
                            -- global (both depend only on the immutable node map), then
                            -- reuse across every spec of the same global. `sItem2`
                            -- carries the memo insert on the first resolve.
                            ( resolution, sItem2 ) =
                                resolveGlobalNode home name sItem
                        in
                        case resolution.node of
                            Nothing ->
                                Ok (finishNode specId (Mono.MonoExtern monoType) sItem2)

                            Just node ->
                                if nodeAlreadyDone specId s && not (nodeSupportsRetranslation node) then
                                    -- LSS_010 latent-bug guard (found by E9): a
                                    -- dirty-flush RE-translation only makes sense
                                    -- for body-bearing nodes. Ctor/enum/box/
                                    -- kernel/manager specs have no set-consuming
                                    -- body, AND their registry type was updated
                                    -- to `nodeType` (the VALUE/result type) at
                                    -- finishNode — feeding that back through
                                    -- `specializeCtorViaScheme`'s whole-scheme
                                    -- unify crashes (arrow vs value). Keep the
                                    -- existing node; the dirty mark was consumed
                                    -- above. Mirror finishNode's bookkeeping
                                    -- (inProgress + currentGlobal) without
                                    -- touching the node.
                                    Ok
                                        (let
                                            aux2 =
                                                sItem2.itemAux
                                         in
                                         { sItem2
                                            | inProgress = BitSet.removeGrowing specId sItem2.inProgress
                                            , currentGlobal = Nothing
                                            , itemAux = { aux2 | currentSpecId = Nothing }
                                         }
                                        )

                                else
                                case specializeNodeSaturating 1 name home node monoType sItem2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoNode0, s1raw ) ->
                                        let
                                            -- Harvest Join-R number taints from this item's store into
                                            -- the global super table before the store is discarded —
                                            -- EXCLUDING the node's own annotation vars (per-spec, memoized).
                                            s1 =
                                                Engine.harvestSuperTableExcept resolution.annIds s1raw

                                            ( monoNode, newLambdaCounter ) =
                                                ResolveAccessorValues.rewriteNode home s1.lambdaCounter monoNode0

                                            actualType =
                                                Mono.nodeType monoNode

                                            -- LSS_010 registry-join invariant (found by
                                            -- E9): for a NON-body node (ctor/enum/box/
                                            -- kernel/manager) `nodeType` is the VALUE/
                                            -- result type, and overwriting the stored
                                            -- FUNCTION-typed demand with it makes every
                                            -- later same-key enqueue mismatch-join —
                                            -- storedChanged oscillates and the flush
                                            -- never converges (and a re-translation
                                            -- would feed the value type to the ctor
                                            -- scheme unify — a crash). Keep the demand
                                            -- for those; body-bearing nodes keep the
                                            -- actualType update they need.
                                            -- Phase 4a: run the completion join
                                            -- ONCE, keeping its changed flag for
                                            -- both the registry write and the
                                            -- census. `Just` exactly when the
                                            -- join site is live (lss on + a
                                            -- body-bearing node).
                                            completionJoin =
                                                if s1.env.lss.enabled && nodeSupportsRetranslation node then
                                                    case Registry.lookupSpecKey specId s1.registry of
                                                        Just ( specKey, storedT ) ->
                                                            let
                                                                ( changedJ, joined0 ) =
                                                                    Mono.joinAnnotationsChanged actualType storedT

                                                                -- P0 join-collision census
                                                                -- (plans/lss-provenance-join-and-demand-sigs.md
                                                                -- §4.1, site 1): cells on the RAW
                                                                -- pair, BEFORE the L1 re-stamp, so
                                                                -- the census sees the collisions
                                                                -- the stamp currently masks.
                                                                -- aVar = the body zonk was ignorant;
                                                                -- sVar = every demand was ignorant.
                                                                censusCells =
                                                                    if s1.env.lss.report then
                                                                        case specKey of
                                                                            Mono.Global jcHome jcName ->
                                                                                Mono.joinCollisionCells
                                                                                    (LssInfer.declaredArityOf (TOpt.Global jcHome jcName) 8 s1)
                                                                                    actualType
                                                                                    storedT

                                                                            _ ->
                                                                                []

                                                                    else
                                                                        []

                                                                -- P1 restatement-⊤ recovery
                                                                -- (plans/lss-provenance-join-and-demand-sigs.md
                                                                -- §4.3): licensed kernel-alias
                                                                -- nodes only. Where the join
                                                                -- reads ⊤ but the stored type
                                                                -- held a complete LSet, the ⊤
                                                                -- is the ABI rebuild's
                                                                -- placeholder restating an
                                                                -- ignorance the license already
                                                                -- discharges — recover the
                                                                -- stored set. Runs BEFORE the
                                                                -- L1 stamp (AR-P1-5: the stamp
                                                                -- never overwrites an LSet, so
                                                                -- the pair is idempotent).
                                                                ( joinedR, recoveredN ) =
                                                                    if s1.env.lss.rsTop && licensedKernelAliasNode node s1 then
                                                                        Mono.recoverStoredSets joined0 storedT

                                                                    else
                                                                        ( joined0, 0 )

                                                                -- L1 (plans/lss-coverage-four-levers.md
                                                                -- §1.1): re-stamp the self spine on the
                                                                -- FINALIZED stored type. Heals the two
                                                                -- head-⊤ manufacturers (the kernel-ABI
                                                                -- rebuild's hardcoded ⊤ — whose store is
                                                                -- never read, so no store-side fix can
                                                                -- work — and the slot-split LSet∪LVar=⊤
                                                                -- join). stampSpineGo is idempotent and
                                                                -- never overwrites an LSet, so the write
                                                                -- stays monotone; the changed flag is
                                                                -- deliberately NOT recomputed (AR-2: the
                                                                -- stamp enriches future demands and the
                                                                -- census, it does not need a re-flush).
                                                                joined1 =
                                                                    if s1.env.lss.injTotal then
                                                                        case specKey of
                                                                            Mono.Global sgHome sgName ->
                                                                                case Translate.stampSelfSpine (TOpt.Global sgHome sgName) joinedR s1 of
                                                                                    Ok ( stamped, _ ) ->
                                                                                        stamped

                                                                                    Err _ ->
                                                                                        joinedR

                                                                            _ ->
                                                                                -- Accessor keys: no self
                                                                                -- global to stamp (AR-3).
                                                                                joinedR

                                                                    else
                                                                        joinedR

                                                                -- P1 census: one cell per
                                                                -- recovered position (report-
                                                                -- gated inside the bump).
                                                                censusCells1 =
                                                                    List.repeat recoveredN "rsTop|recovered" ++ censusCells
                                                            in
                                                            Just ( changedJ, joined1, censusCells1 )

                                                        Nothing ->
                                                            Just ( False, actualType, [] )

                                                else
                                                    Nothing

                                            registry2 =
                                                if nodeSupportsRetranslation node then
                                                    -- LSS_010 monotonicity (found by E9): the
                                                    -- registry entry is the JOIN of every
                                                    -- admitted demand's annotations; a plain
                                                    -- actualType overwrite DISCARDS demand-side
                                                    -- members the body's own zonk doesn't carry
                                                    -- (arg-side injected globals), so join-grow /
                                                    -- update-shrink ping-pongs the flush forever
                                                    -- ("registry/actualType oscillation").
                                                    -- Structure from actualType, annos UNIONED
                                                    -- with the stored entry. Flag-off the annos
                                                    -- are all LTop — keep the byte-identical
                                                    -- plain update there.
                                                    --
                                                    -- Phase 4a: the changed flag does NOT gate
                                                    -- this write. `False` means the join result
                                                    -- IS actualType by pointer, but the registry
                                                    -- still holds storedT, so the update must run
                                                    -- either way — the win here is the elided
                                                    -- rebuild, not an elided write.
                                                    case completionJoin of
                                                        Just ( _, joined, _ ) ->
                                                            Registry.updateRegistryType specId joined s1.registry

                                                        Nothing ->
                                                            Registry.updateRegistryType specId actualType s1.registry

                                                else
                                                    s1.registry

                                            s2 =
                                                { s1
                                                    | registry = registry2
                                                    , lambdaCounter = newLambdaCounter
                                                }

                                            -- Phase 1 census: count the joins
                                            -- this site runs (one per completed
                                            -- body-bearing spec). Phase 4a splits
                                            -- out the no-op subset, which the
                                            -- changed flag gives for free:
                                            -- `completion` stays the total.
                                            s3 =
                                                case completionJoin of
                                                    Just ( True, _, _ ) ->
                                                        Engine.bumpCompletionJoin s2

                                                    Just ( False, _, _ ) ->
                                                        Engine.bumpCompletionJoinNoop s2

                                                    Nothing ->
                                                        s2

                                            -- P0 site-1 cell bumps.
                                            s4 =
                                                case completionJoin of
                                                    Just ( _, _, cells ) ->
                                                        List.foldl Engine.bumpArgFlowCensus s3 cells

                                                    Nothing ->
                                                        s3
                                        in
                                        Ok (finishNode specId monoNode s4)


{-| LSS_018 (μ-tie): raw-lambda → smallest qualified member id present in the
spec's stored demand type. Consulted by `Engine.lambdaInstanceMemberId` on
routed mints; smallest-id choice makes the canonical family id
deterministic. Built ONLY under `lss.muTie` — the flag-off default path
pays no per-item type walk (the one-shot eligible census, Run J, measured
the population at 0 on the self-compile). The routing predicate is NOT
re-checked here: the map is only ever read after
`lambdaInstanceMemberId`'s own routed check.
-}
demandQualifiedFor : Mono.MonoType -> S -> Dict.Dict Int Int
demandQualifiedFor monoType s =
    if not (s.env.lss.enabled && s.env.lss.muTie) then
        Dict.empty

    else
        List.foldl
            (\mid acc ->
                case Dict.get mid s.lssMemberTable.lambdaQualified of
                    Just ( raw, _ ) ->
                        Dict.update raw
                            (\cur ->
                                Just (min mid (Maybe.withDefault mid cur))
                            )
                            acc

                    Nothing ->
                        acc
            )
            Dict.empty
            (Mono.collectAnnoMembers monoType)


{-| MONO_029 stale-read barrier (R2 of
plans/solver-layout-connectivity-reconciliation.md): translate the item and, if
any recorded CEcoValue residual was read from a var the translation LATER
bound (read-before-saturation), re-translate immediately AGAINST THE SAME
STORE. The item store is monotone — pass 2's zonks see every binding pass 1
made anywhere in the body, so the previously-stale reads come back concrete.
Re-translation must happen here (store in hand), not at the drain-end flush:
`resetItem` would rebuild the store from scratch and deterministically
reproduce the same stale snapshot.

Convergence: each pass only ADDS bindings to one finite store; a pass with no
newly-bound residual reads is a fixpoint. The cap turns oscillation into a
loud EngineBug. Side effects of discarded passes are benign: `enqueueSpec` is
key-idempotent (a spec enqueued under a since-healed erased key may survive as
an unreferenced spec and is pruned), and multi-instance stacks are re-pushed
per pass.
-}
specializeNodeSaturating : Int -> Name -> IO.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNodeSaturating attempt name home node monoType s =
    case specializeNode name home node monoType s of
        Err e ->
            Err e

        Ok ( monoNode, s1 ) ->
            if not (staleResidualRead s1) then
                Ok ( monoNode, s1 )

            else if attempt >= maxSaturationPasses then
                Err
                    (EngineBug
                        ("MONO_029 stale-read saturation exceeded "
                            ++ String.fromInt maxSaturationPasses
                            ++ " passes for "
                            ++ name
                            ++ " — residual reads keep preceding their bindings"
                        )
                    )

            else
                specializeNodeSaturating (attempt + 1) name home node monoType (Engine.clearResidualReads s1)


{-| Stale-read re-translation cap. One extra pass suffices for the observed
shapes (a destructure recorded before a later app-shape unification); anything
deeper indicates reads and bindings chasing each other and must fail loudly.
-}
maxSaturationPasses : Int
maxSaturationPasses =
    5


{-| Specialize one top-level node. `name`/`home` identify the definition (used
for ctor tags and to follow links to their target's name/home).
-}
specializeNode : Name -> IO.Canonical -> TOpt.Node TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
specializeNode name home node monoType s =
    case node of
        TOpt.Define expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.TrackedDefine _ expr _ meta ->
            defineFrom meta.tipe expr monoType s

        TOpt.Kernel _ _ ->
            Ok ( Mono.MonoExtern monoType, s )

        TOpt.Ctor index arity canType ->
            Engine.runStep (Translate.specializeCtorViaScheme name (CtorTag.effective home name index) arity canType monoType) s

        TOpt.Enum index canType ->
            Engine.runStep (Translate.enumNode (CtorTag.effective home name index) canType monoType) s

        TOpt.Box canType ->
            -- @unbox single-field type: a 1-field ctor with literal tag 0.
            Engine.runStep (Translate.specializeCtorViaScheme name 0 1 canType monoType) s

        TOpt.Link linkedGlobal ->
            case HashMap.get TOpt.globalHash (==) linkedGlobal s.env.toptNodes of
                Nothing ->
                    Ok ( Mono.MonoExtern monoType, s )

                Just linkedNode ->
                    case linkedGlobal of
                        TOpt.Global linkedHome linkedName ->
                            specializeNode linkedName linkedHome linkedNode monoType s

        TOpt.Manager _ ->
            case home of
                IO.Canonical _ modName ->
                    Ok ( Mono.MonoManagerLeaf (Name.toElmString modName) monoType, s )

        TOpt.Cycle _ valueDefs funcDefs _ ->
            -- The demand reaches the cycle node through a `_M$<first>` Link, so
            -- `name` here is the group name; the REQUESTED member is the original
            -- demand preserved in `currentGlobal`. Each member's cross-references
            -- enqueue its siblings, so members materialize as separate work items.
            let
                reqName =
                    case s.currentGlobal of
                        Just (Mono.Global _ n) ->
                            n

                        _ ->
                            name
            in
            Engine.runStep (Translate.specializeCycle reqName valueDefs funcDefs monoType) s

        TOpt.PortIncoming expr _ meta ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    Engine.runStep (Translate.specializePort True expr meta.tipe monoType) s

                _ ->
                    -- The same port Global demanded at its DECODER (non-function)
                    -- type: compile the payload decoder as a plain value node
                    -- (mirrors the original engine's split).
                    defineFrom (TOpt.typeOf expr) expr monoType s

        TOpt.PortOutgoing expr _ meta ->
            Engine.runStep (Translate.specializePort False expr meta.tipe monoType) s


{-| D13: resolve a `Mono.Global` to its `TOpt.Node` and annotation-id set, memoized
by the comparable global. The node map and `nodeAnnotationIds` are both functions
of the immutable `toptNodes`, so a global with N specializations resolves once and
the DMap descent + `freeVarIds` walk are skipped for the other N-1. The memo lives
in `S.nodeResolution` (survives `resetItem`); byte-identical to recomputing.
-}
resolveGlobalNode : IO.Canonical -> Name -> S -> ( Engine.NodeResolution, S )
resolveGlobalNode home name s =
    let
        gkey =
            TOpt.toComparableGlobal (TOpt.Global home name)
    in
    case Dict.get gkey s.nodeResolution of
        Just resolution ->
            ( resolution, s )

        Nothing ->
            let
                node =
                    HashMap.get TOpt.globalHash (==) (TOpt.Global home name) s.env.toptNodes

                annIds =
                    case node of
                        Just n ->
                            nodeAnnotationIds n

                        Nothing ->
                            EverySet.empty

                resolution =
                    { node = node, annIds = annIds }
            in
            ( resolution, { s | nodeResolution = Dict.insert gkey resolution s.nodeResolution } )


{-| The item node's annotation free-var ids (excluded from taint harvest).
-}
nodeAnnotationIds : TOpt.Node TypeIds.MVarId -> EverySet.EverySet Int Int
nodeAnnotationIds node =
    let
        fromCan t =
            EverySet.fromList identity (List.map Id.toComparable (KernelAbi.freeVarIds t []))
    in
    case node of
        TOpt.Define _ _ meta ->
            fromCan meta.tipe

        TOpt.TrackedDefine _ _ _ meta ->
            fromCan meta.tipe

        _ ->
            EverySet.empty


{-| Specialize a value definition: assert the demanded type against the def's
annotation in the store (so a polymorphic body concretizes via the shared memo),
then translate the body. For a monomorphic global the demand equals the
annotation and the unification is a no-op.
-}
defineFrom : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> S -> Result Failure ( Mono.MonoNode, S )
defineFrom annCanType expr demand s =
    case Engine.runStep (Translate.demandUnifyRoot annCanType demand expr) s of
        Err e ->
            Err e

        Ok ( (), s1 ) ->
            case Engine.runStep (Translate.translate expr) s1 of
                Err e ->
                    Err e

                Ok ( monoExpr, s2 ) ->
                    -- LSS_026 §11 tried widening a WRAP-CLASS def's head
                    -- annotation here (the adoption input of
                    -- `Mono.singletonHeadMember`). MEASURED NO-GO — see the
                    -- plan's §11.5: it removed ALL adoption-blocking
                    -- (`declinedBlocked` 156 → 0) and moved dispatch coverage
                    -- by 0.000 pp, while costing 19 k singleton sets and 60 %
                    -- of grounding. Do not re-attempt without first
                    -- establishing what the fast→gen conversion actually is.
                    Ok ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s2 )


{-| LSS_010 re-translation eligibility: only body-bearing nodes can be
meaningfully re-translated with a joined demand. Ctor/enum/box/kernel/
manager specs are shape-derived — and their registry type is rewritten to
the node's VALUE type at finishNode, which the ctor-scheme unify rejects.
Links chase to their target's kind.
-}
nodeSupportsRetranslation : TOpt.Node TypeIds.MVarId -> Bool
nodeSupportsRetranslation node =
    case node of
        TOpt.Define _ _ _ ->
            True

        TOpt.TrackedDefine _ _ _ _ ->
            True

        TOpt.Cycle _ _ _ _ ->
            True

        TOpt.PortIncoming _ _ _ ->
            True

        TOpt.PortOutgoing _ _ _ ->
            True

        TOpt.Link _ ->
            -- The linked target is Define/Cycle in practice; allowing the
            -- chase is safe (specializeNode recurses into the target).
            True

        _ ->
            False


{-| P1 (plans/lss-provenance-join-and-demand-sigs.md §4.3, AR-P1-2): is this
node an eta-free KERNEL ALIAS whose kernel carries a `TypeFaithful` license
that APPLIES at the alias's occurrence type? This is the sole node class
where restatement-⊤ recovery is sound: the alias body contributes no members
of its own (the ⊤s on its actual side are the kernel-ABI rebuild's
placeholders), and the license is the audited proof the kernel fabricates no
function inhabitants beyond its type's variable sharing — so a stored `LSet`
(every demand agreed on a complete set) really is complete. Link-chased like
`LssInfer.kernelAliasOf`, but keeps the body meta for the occurrence check.
-}
licensedKernelAliasNode : TOpt.Node TypeIds.MVarId -> S -> Bool
licensedKernelAliasNode nd s =
    let
        licensed kHome kName kMeta =
            case KernelSetFacts.factFor kHome kName of
                Just (KernelSetFacts.TypeFaithful license) ->
                    KernelSetFacts.licenseApplies (Engine.isScalarVar s) license kMeta.tipe

                _ ->
                    False
    in
    case nd of
        TOpt.Define (TOpt.VarKernel _ _ kHome kName kMeta) _ _ ->
            licensed kHome kName kMeta

        TOpt.TrackedDefine _ (TOpt.VarKernel _ _ kHome kName kMeta) _ _ ->
            licensed kHome kName kMeta

        TOpt.Link target ->
            case HashMap.get TOpt.globalHash (==) target s.env.toptNodes of
                Just nd2 ->
                    licensedKernelAliasNode nd2 s

                Nothing ->
                    False

        _ ->
            False


finishNode : Mono.SpecId -> Mono.MonoNode -> S -> S
finishNode specId monoNode s =
    -- A join that landed mid-translation left the spec's dirty mark set;
    -- the drain-end flush re-pushes it (LSS_010) — no per-item re-push.
    let
        -- §3.2 (plans/lss-post-mono-architecture.md): replay this item's
        -- readbacks NOW — same store, same variables, same multiplicity, just
        -- after the item finished writing instead of during. Report-gated and
        -- read-only; the next `resetItem` discards this store, so this is the
        -- last moment the experiment is possible at all.
        --
        -- BEFORE the itemAux update below, because `rezonkSettled` reads
        -- `itemAux.zonkLog` and `itemAux.arrowOfSlot`.
        sSettled =
            Store.rezonkSettled s

        -- §5.1 (plans/lss-paper-inclusion-constraints.md): solve this item's
        -- shadow `Q` and score it against the store the eager union built.
        -- Same placement and the same read-only discipline as the re-zonk
        -- above, and for the same reason: the next `resetItem` throws this
        -- store away, so item end is the last moment the comparison exists.
        sQ =
            Store.qShadowCensus sSettled

        aux =
            sQ.itemAux
    in
    { sQ
        | nodes = arraySetGrowing specId (Just monoNode) sQ.nodes
        , inProgress = BitSet.removeGrowing specId sQ.inProgress
        , currentGlobal = Nothing

        -- Fix B (LSS_017): a mint outside any item must not silently adopt a
        -- stale spec — clear alongside currentGlobal.
        , itemAux = { aux | currentSpecId = Nothing, qLog = [] }
    }


{-| Did any recorded CEcoValue residual read become resolvable after the fact?
Point-based reads (`ecoResidualReads`) are stale only when (a) the var's class
is now bound (structure/alias — or a Number super that Prune would close to
MInt) AND (b) the class is UF-equivalent to the ITEM MEMO's point for the
var's canonical id — i.e. the shared canonical family. Isolated per-call
instantiations (loadType with a fresh memo, the SKI/per-call-site design) are
read-free-then-bound on EVERY pass by construction; treating them as stale
livelocks the saturation loop (R0 census finding, RecordNarrow corpus).
Key-based reads (`ecoResidualKeyReads`) are vars that had not entered the
store when classified; they are stale only if the memo has since gained a
BOUND point for them.
-}
staleResidualRead : S -> Bool
staleResidualRead s =
    List.any (staleVarRead s) s.itemAux.ecoResidualReads
        || List.any
            (\key ->
                case Dict.get key s.memo of
                    Just pt ->
                        varResolvedNow s.store pt

                    Nothing ->
                        False
            )
            s.itemAux.ecoResidualKeyReads


staleVarRead : S -> IO.Variable -> Bool
staleVarRead s var =
    varResolvedNow s.store var
        && (case Maybe.andThen identity (Array.get (Engine.pointKey var) s.revMemo) of
                Nothing ->
                    False

                Just mid ->
                    case Dict.get (Engine.mvarIdKey mid) s.memo of
                        Nothing ->
                            False

                        Just memoPoint ->
                            let
                                ( _, eq ) =
                                    UF.equivalent memoPoint var s.store
                            in
                            eq
           )


varResolvedNow : IO.State -> IO.Variable -> Bool
varResolvedNow store var =
    let
        ( _, desc ) =
            UF.get var store
    in
    case desc.content of
        IO.Structure _ ->
            True

        IO.Alias _ _ _ _ ->
            True

        IO.FlexSuper IO.Number _ ->
            True

        IO.RigidSuper IO.Number _ ->
            True

        _ ->
            False


nodeAlreadyDone : Mono.SpecId -> S -> Bool
nodeAlreadyDone specId s =
    case Array.get specId s.nodes of
        Just (Just _) ->
            True

        _ ->
            False



-- ====== ASSEMBLY (mirror of assembleRawGraphFrom) ======


assembleRawGraph : S -> Mono.SpecId -> Maybe Mono.SpecId -> Mono.MonoGraph
assembleRawGraph s mainSpecId flagsDecoderSpecId =
    let
        nextId : Int
        nextId =
            s.registry.nextId

        nodesArray : Array (Maybe Mono.MonoNode)
        nodesArray =
            let
                currentLen =
                    Array.length s.nodes
            in
            if currentLen >= nextId then
                s.nodes

            else
                Array.append s.nodes (Array.repeat (nextId - currentLen) Nothing)

        ( callEdgesArray, specHasEffects, specValueUsed ) =
            Array.foldl
                (\maybeNode ( specId, ( edgesAcc, effectsAcc, valueUsedAcc ) ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, ( edgesAcc, effectsAcc, valueUsedAcc ) )

                        Just node ->
                            let
                                -- D14: one fused walk yields both the call-edges and
                                -- the effects flag (was two full `foldExpr` passes over
                                -- the same expr). Byte-identical: same traversal order,
                                -- same cons order for edges, same Debug-kernel effect.
                                ( neighbors, hasEffects ) =
                                    collectEdgesAndEffectsFromNode node

                                newEdges =
                                    Array.set specId (Just neighbors) edgesAcc

                                newEffects =
                                    if hasEffects then
                                        BitSet.insertGrowing specId effectsAcc

                                    else
                                        effectsAcc

                                newValueUsed =
                                    List.foldl (\calleeId acc -> BitSet.insertGrowing calleeId acc) valueUsedAcc neighbors
                            in
                            ( specId + 1, ( newEdges, newEffects, newValueUsed ) )
                )
                ( 0, ( Array.repeat nextId Nothing, BitSet.empty, BitSet.empty ) )
                nodesArray
                |> Tuple.second

        valueUsedWithMain : BitSet.BitSet
        valueUsedWithMain =
            BitSet.insertGrowing mainSpecId specValueUsed
    in
    Mono.MonoGraph
        { nodes = nodesArray
        , registry = { nextId = nextId, mapping = Mono.specKeyMapEmpty, reverseMapping = s.registry.reverseMapping, countByGlobal = Dict.empty }
        , main = Just (Mono.StaticMain mainSpecId)
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = s.lambdaCounter
        , callEdges = callEdgesArray
        , specHasEffects = specHasEffects
        , specValueUsed = valueUsedWithMain
        , ports = s.ports
        , flagsDecoder = flagsDecoderSpecId
        , lssMemberOrigins = buildMemberOrigins s.env.toptNodes s.lssMemberTable
        , lssBlockedMembers = s.lssMemberTable.muTied
        }


{-| B3.5: invert `LssMemberTable.byKey` into member-id → origin, dispatching on
the 2-char key prefix (`g|`/`c|`/`k|`/`a|`; `l|` lambdas are skipped — resolved
via the instance index). TOpt.Global payloads convert to Mono.Global here (the
origin carries Monomorphized's own Global; this site imports TOpt).
-}
buildMemberOrigins : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> Engine.LssMemberTable -> Dict.Dict Int Mono.MemberOrigin
buildMemberOrigins toptNodes table =
    Dict.foldl
        (\key mid acc ->
            case String.left 2 key of
                "g|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceGlobal g) ->
                            Dict.insert mid (globalOrigin toptNodes g) acc

                        _ ->
                            acc

                "c|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceGlobal g) ->
                            Dict.insert mid (Mono.OriginCtor (toptToMono g)) acc

                        _ ->
                            acc

                "k|" ->
                    case Dict.get mid table.sources of
                        Just (Engine.SourceKernel ( _, home, name )) ->
                            Dict.insert mid (Mono.OriginKernel home name) acc

                        _ ->
                            acc

                "a|" ->
                    Dict.insert mid (Mono.OriginAccessor (String.dropLeft 2 key)) acc

                _ ->
                    acc
        )
        Dict.empty
        table.byKey


{-| F-5A: a `g|` member whose node IS a constructor gets `OriginCtor`.

Only nullary-enum and box constructors are minted under `c|`
(`TypedOptimized.elm:155-156` — `VarEnum` / `VarBox`); every other
constructor — `Just`, `List.::`, any user-defined unary ctor — canonicalizes
to a `TOpt.VarGlobal` and lands under `g|`. Consumers read the origin to
decide whether a member's evaluation can reach `Debug`, and CONSTRUCTING a
value never can, so the key prefix must not be the answer.

Link-chased, and eta-free ctor ALIASES are chased through their `Define`
body: without that, `let w = Wrap in List.map w` declines while
`List.map Wrap` licenses — an asymmetry with no explanation in the census.
Depth-bounded so a malformed `Link` cycle cannot hang the compiler.
(`LssInfer.kernelAliasOf` is the same pattern, but it runs against `Engine.S`
and is not importable here.)

-}
globalOrigin : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> TOpt.Global -> Mono.MemberOrigin
globalOrigin toptNodes g =
    if ctorBackedGlobal toptNodes 8 g then
        Mono.OriginCtor (toptToMono g)

    else
        Mono.OriginGlobal (toptToMono g)


ctorBackedGlobal : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -> Int -> TOpt.Global -> Bool
ctorBackedGlobal toptNodes fuel g =
    if fuel <= 0 then
        False

    else
        case HashMap.get TOpt.globalHash (==) g toptNodes of
            Just (TOpt.Ctor _ _ _) ->
                True

            Just (TOpt.Box _) ->
                True

            Just (TOpt.Link target) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.Define (TOpt.VarBox _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.Define (TOpt.VarGlobal _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.TrackedDefine _ (TOpt.VarBox _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            Just (TOpt.TrackedDefine _ (TOpt.VarGlobal _ target _) _ _) ->
                ctorBackedGlobal toptNodes (fuel - 1) target

            _ ->
                False


toptToMono : TOpt.Global -> Mono.Global
toptToMono (TOpt.Global h n) =
    Mono.Global h n


pruneGraph : S -> Mono.MonoGraph -> Mono.MonoGraph
pruneGraph s rawGraph =
    Prune.pruneUnreachableSpecs
        (State.initMVarEnv s.nextMVarId s.superTable)
        s.env.globalTypeEnv
        rawGraph



-- ====== CALL-EDGE / EFFECT COLLECTION (mirror of the original private helpers) ======


{-| D14: fused edge-and-effect step. One `foldExpr` pass accumulates both the
call-edge spec ids (a `MonoVarGlobal`, cons order preserved) and the effects flag
(a `Debug` kernel reference). Replaces the former `extractSpecId` + `checkExpr`
double walk over the same expr; each expr node contributes to at most one field,
so the union is exact and byte-identical.
-}
collectEdgesAndEffects : Mono.MonoExpr -> ( List Int, Bool ) -> ( List Int, Bool )
collectEdgesAndEffects expr (( edges, effects ) as acc) =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            ( specId :: edges, effects )

        Mono.MonoVarKernel _ _ "Debug" _ _ ->
            ( edges, True )

        _ ->
            acc


collectEdgesAndEffectsFromNode : Mono.MonoNode -> ( List Int, Bool )
collectEdgesAndEffectsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoTailFunc _ expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortIncoming expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        Mono.MonoPortOutgoing expr _ ->
            Traverse.foldExpr collectEdgesAndEffects ( [], False ) expr

        _ ->
            ( [], False )



-- ====== HELPERS ======


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing index value arr =
    let
        len =
            Array.length arr
    in
    if index < len then
        Array.set index value arr

    else
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))


renderFailure : Failure -> String
renderFailure failure =
    case failure of
        Unsupported msg ->
            "MonoSolver.unsupported: " ++ msg

        UnifyMismatch msg ->
            "MonoSolver.unify-mismatch: " ++ msg

        EngineBug msg ->
            "MonoSolver.bug: " ++ msg

        LimitExceeded msg ->
            -- MONO_030: a resource watchdog, deliberately NOT framed as a
            -- compiler bug — the message itself names the limit, the env
            -- var, and the likely cause (poly-rec via annotated mutual
            -- cycles is legal Elm).
            msg
