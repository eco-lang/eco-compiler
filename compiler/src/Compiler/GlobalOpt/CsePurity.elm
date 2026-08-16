module Compiler.GlobalOpt.CsePurity exposing
    ( Oracle
    , analyze
    , costOf
    , countLocalUses
    , isSafeCall
    , isSafeExpr
    , safeSpecCount
    )

{-| Shared purity oracle for Mono-level CSE (kernel-opt-13, executing
`plans/cse-pure-calls.md` carve-out 3).

Two questions, and the second is the one the outline left implicit:

1.  **Is this kernel call CSE-safe?** Answered by kernel-opt-07's audited
    `cseSafe` bit. Whitelist discipline: an unlisted kernel is NOT safe.
2.  **Is this call to a global spec CSE-safe?** This needs a TRANSITIVE answer,
    because a user function that internally `Debug.log`s is not safe even though
    its own call node looks innocent. `analyze` computes that as a fixpoint over
    the spec graph and hands back a `BitSet` of safe spec ids.

**Why the graph's own caches are not used.** `MonoGraph` carries `callEdges`,
`specHasEffects` and `specValueUsed`, and all three are DEAD at this point in
the pipeline: `MonoInlineSimplify.optimize` rebuilds the graph with them empty
and runs before GlobalOpt. Reading them here would classify every spec as
Debug-free — an unsound-optimistic oracle. Do not "optimize" `analyze` by
consulting them, and do not repopulate them.

`OPT_DEBUG_ORDER_001` D-2 is enforced BY CONSTRUCTION here: any spec that can
reach a `Debug.*` kernel is unsafe, and a direct `Debug.*` reference is unsafe,
so no merge this oracle licenses can change how many log lines are emitted.

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Dict exposing (Dict)
import Set exposing (Set)


{-| Two different questions, and conflating them is a miscompile.

`safeSpecs` answers **"can evaluating this reach `Debug`?"** — the
`OPT_DEBUG_ORDER_001` D-2 question the `List.map` template's licence asks. A
CONSTRUCTION cannot reach `Debug`, so ctor and enum specs belong here.

`mergeableSpecs` answers **"may two structurally equal occurrences of this
become ONE value?"** — what MonoCse asks. A construction may NOT: allocation
identity is observable through `==`'s pointer-equality fast path, so merging
two `Point nan nan` allocations makes them compare EQUAL when `NaN == NaN`
must be `False`. Measured: seeding constructions into the merge oracle turned
`ContainerEqualityCustomFloatTest` red under `ECO_CSE=1` (2026-08-15) — the
same NaN-sharing class that reverted the MLIR CSE flip in Run R.

`mergeableSpecs` is therefore the pre-2026-08-15 fixpoint, unchanged, and CSE
behaviour is bit-identical to before the split.

`Set Int` rather than `Compiler.Data.BitSet`: the fixpoint needs member
REMOVAL and a membership count, and BitSet exposes neither (`size` is its bit
capacity, and only `removeGrowing` exists). `analyze` runs once per compile over
~12k specs, so the log-factor is irrelevant next to getting the fixpoint right.

-}
type alias Oracle =
    { safeSpecs : Set Int
    , mergeableSpecs : Set Int
    }


{-| Number of specs classified safe; for the census line.
-}
safeSpecCount : Oracle -> Int
safeSpecCount oracle =
    Set.size oracle.safeSpecs



-- KERNEL AXIS


{-| A kernel call is CSE-safe iff kernel-opt-07's audit says so. `hoistable` is
`cseSafe`; the key form folds in the whitelist default (unlisted ⇒ False), which
is exactly the carve-out-3 requirement.
-}
kernelCseSafe : Name -> Name -> Bool
kernelCseSafe home name =
    KernelFacts.hoistableFor ( home, name )



-- SPEC AXIS (transitive)


{-| Classify every spec by whether evaluating it can be observed.

One pass builds each spec's direct verdict plus its callee set; a fixpoint then
poisons any spec that reaches an unsafe one. Poison travels callee → caller, so
the fixpoint is monotone and terminates: a spec only ever moves safe → unsafe.

-}
analyze : Mono.MonoGraph -> Oracle
analyze (Mono.MonoGraph g) =
    let
        -- Pass 1: direct verdict + callee edges, per spec.
        scan =
            Array.foldl
                (\maybeNode ( sid, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( sid + 1, acc )

                        Just node ->
                            case bodyOf node of
                                Nothing ->
                                    -- Bodiless specs. `MonoCtor`/`MonoEnum`
                                    -- ARE observation-free — a construction
                                    -- cannot reach `Debug` — so they seed the
                                    -- safe set with no edges. `MonoExtern` is
                                    -- opaque and `MonoManagerLeaf` is an
                                    -- effect stub: both stay absent, which is
                                    -- permanent poison, as intended.
                                    --
                                    -- The previous comment claimed nothing
                                    -- calls these as specs "so the
                                    -- conservative answer costs nothing".
                                    -- Both clauses were false: `scanBody`
                                    -- records a callee edge for ANY
                                    -- `MonoVarGlobal` reference, so merely
                                    -- MENTIONING a ctor poisoned the
                                    -- mentioning spec and then every caller.
                                    -- Measured before this change: safeSpecs
                                    -- 17,531 of 30,905, and all 50 of the
                                    -- `List.map` template's
                                    -- `declinedOpaqueGlobal`.
                                    --
                                    -- Seeding them is only SOUND alongside
                                    -- the template's argument-position taint
                                    -- rule: un-starving `Maybe.map` unmasks
                                    -- `\x -> Maybe.map g x`, which was safe
                                    -- by accident while `Maybe.map` itself
                                    -- was poisoned. That rule landed
                                    -- 2026-08-14 (plans/list-map-mlir-template.md
                                    -- F-4); do not revert one without the
                                    -- other.
                                    ( sid + 1
                                    , if isPureConstruction node then
                                        { acc | constructions = Set.insert sid acc.constructions }

                                      else
                                        acc
                                    )

                                Just body ->
                                    let
                                        ( direct, callees ) =
                                            scanBody body
                                    in
                                    ( sid + 1
                                    , { acc
                                        | direct =
                                            if direct then
                                                Set.insert sid acc.direct

                                            else
                                                acc.direct
                                        , edges = Dict.insert sid callees acc.edges
                                      }
                                    )
                )
                ( 0, { direct = Set.empty, constructions = Set.empty, edges = Dict.empty } )
                g.nodes
                |> Tuple.second

        -- Pass 2: poison to a fixpoint.
        settle safe =
            let
                next =
                    Dict.foldl
                        (\sid callees acc ->
                            if Set.member sid acc && List.any (\c -> not (Set.member c acc)) callees then
                                Set.remove sid acc

                            else
                                acc
                        )
                        safe
                        scan.edges
            in
            if Set.size next == Set.size safe then
                next

            else
                settle next
    in
    { safeSpecs = settle (Set.union scan.direct scan.constructions)
    , mergeableSpecs = settle scan.direct
    }


{-| Is this bodiless spec a pure CONSTRUCTION (so, observation-free)?

`MonoCtor` builds a value and `MonoEnum` is a constant; neither can reach
`Debug`. `MonoExtern` is opaque and `MonoManagerLeaf` runs effects, so both
must stay unsafe. Nodes WITH bodies never reach here.

-}
isPureConstruction : Mono.MonoNode -> Bool
isPureConstruction node =
    case node of
        Mono.MonoCtor _ _ ->
            True

        Mono.MonoEnum _ _ ->
            True

        _ ->
            False


bodyOf : Mono.MonoNode -> Maybe MonoExpr
bodyOf node =
    case node of
        Mono.MonoDefine body _ ->
            Just body

        Mono.MonoTailFunc _ body _ ->
            Just body

        Mono.MonoPortIncoming body _ ->
            Just body

        Mono.MonoPortOutgoing body _ ->
            Just body

        _ ->
            Nothing


{-| One walk: is this body directly observation-free, and which specs does it
call? "Directly" ignores the callees, which the fixpoint handles.
-}
scanBody : MonoExpr -> ( Bool, List Int )
scanBody root =
    let
        go expr ( ok, callees ) =
            if not ok then
                ( False, callees )

            else
                case expr of
                    MonoVarKernel _ _ home name _ ->
                        -- A bare kernel reference in value position mints a PAP
                        -- at worst; what matters is whether it is Debug.
                        ( home /= "Debug", callees )

                    MonoVarGlobal _ sid _ ->
                        ( True, sid :: callees )

                    MonoCall _ func args _ _ ->
                        List.foldl go (go func ( ok, callees )) args

                    _ ->
                        foldChildren go ( ok, callees ) expr
    in
    go root ( True, [] )


{-| Is this expression safe to merge with a structurally equal sibling?

Conservative and total: every leaf must be inert, every kernel call must be
audited `cseSafe`, and every global call must land in the oracle's safe set.

-}
isSafeExpr : Oracle -> MonoExpr -> Bool
isSafeExpr oracle root =
    let
        go expr ok =
            if not ok then
                False

            else
                case expr of
                    MonoVarKernel _ _ home name _ ->
                        kernelCseSafe home name

                    MonoVarGlobal _ sid _ ->
                        Set.member sid oracle.mergeableSpecs

                    MonoClosure _ _ _ ->
                        -- Creating a closure is pure, but v1 excludes closures
                        -- from candidacy anyway (different eval frequency).
                        False

                    MonoTailCall _ _ _ ->
                        False

                    _ ->
                        foldChildren go ok expr
    in
    go root True


{-| Candidate test for a CALL specifically — the shape CSE targets.
-}
isSafeCall : Oracle -> MonoExpr -> Bool
isSafeCall oracle expr =
    case expr of
        MonoCall _ _ _ _ _ ->
            isSafeExpr oracle expr

        _ ->
            False



-- COST


{-| Transcribed from `MonoInlineSimplify.computeCost` for the constructors v1
admits, because that function is not exposed. The census and the pass share this
one definition so the reported histogram and the `minCost` cut cannot disagree.
-}
costOf : MonoExpr -> Int
costOf expr =
    case expr of
        MonoList _ items _ ->
            3 + List.foldl (\i n -> n + costOf i) 0 items

        MonoCall _ func args _ _ ->
            5 + costOf func + List.foldl (\a n -> n + costOf a) 0 args

        MonoRecordCreate fields _ ->
            3 + List.foldl (\( _, e ) n -> n + costOf e) 0 fields

        MonoTupleCreate _ items _ ->
            3 + List.foldl (\i n -> n + costOf i) 0 items

        MonoRecordAccess inner _ _ ->
            1 + costOf inner

        _ ->
            1



-- LIVENESS (kernel-opt-11 ride-along)


{-| Occurrences of a local name. `MonoInlineSimplify`'s equivalents are not
reachable: `usesInDefs` is a `let`-local inside `dropDeadDefs` and `countUsages`
is top-level but not exposed.
-}
countLocalUses : Name -> MonoExpr -> Int
countLocalUses name root =
    let
        go expr n =
            case expr of
                MonoVarLocal v _ ->
                    if v == name then
                        n + 1

                    else
                        n

                _ ->
                    foldChildren go n expr
    in
    go root 0


{-| Fold `f` over the DIRECT sub-expressions of `expr`, left to right.

Written here rather than imported: `Compiler.AST.Monomorphized` exposes no
generic child traversal, and every consumer in this module wants the same
shape. Being exhaustive over the constructor list is the point — a new
`MonoExpr` constructor should break this compile rather than be silently
skipped by a catch-all that returns the accumulator unchanged.

-}
foldChildren : (MonoExpr -> a -> a) -> a -> MonoExpr -> a
foldChildren f acc expr =
    case expr of
        MonoLiteral _ _ ->
            acc

        MonoVarLocal _ _ ->
            acc

        MonoVarGlobal _ _ _ ->
            acc

        MonoVarKernel _ _ _ _ _ ->
            acc

        MonoUnit ->
            acc

        MonoAccessorValue _ _ _ ->
            acc

        MonoList _ items _ ->
            List.foldl f acc items

        MonoClosure _ body _ ->
            f body acc

        MonoCall _ func args _ _ ->
            List.foldl f (f func acc) args

        MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> f e a) acc args

        MonoIf branches final _ ->
            f final (List.foldl (\( c, t ) a -> f t (f c a)) acc branches)

        MonoLet def body _ ->
            f body (f (defBound def) acc)

        MonoDestruct _ body _ ->
            f body acc

        MonoCase _ _ decider branches _ ->
            List.foldl (\( _, e ) a -> f e a)
                (foldDecider f acc decider)
                branches

        MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> f e a) acc fields

        MonoRecordAccess inner _ _ ->
            f inner acc

        MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> f e a) (f inner acc) updates

        MonoTupleCreate _ items _ ->
            List.foldl f acc items


foldDecider : (MonoExpr -> a -> a) -> a -> Mono.Decider Mono.MonoChoice -> a
foldDecider f acc decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            f e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            foldDecider f (foldDecider f acc success) failure

        Mono.FanOut _ tests fallback ->
            foldDecider f
                (List.foldl (\( _, d ) a -> foldDecider f a d) acc tests)
                fallback


defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
