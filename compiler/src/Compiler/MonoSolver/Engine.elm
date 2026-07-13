module Compiler.MonoSolver.Engine exposing
    ( S, Env, Step, Failure(..), WorkItem(..), NumberMultiEntry, NumberInstance, NodeResolution
    , ArrowFact, LssSignature, LssStats
    , succeed, fail, andThen, map, map2, traverse, foldlS
    , getS, modifyS, liftIO, runStep
    , freshVar, enqueueSpec
    , freshStore, resetItem, harvestSuperTable, harvestSuperTableExcept
    , insertVar, lookupVar, scoped
    , pushNumberMulti, popNumberMulti, isNumberMultiTarget, recordNumberInstance, numberMultiRootType
    , pushLocalMulti, popLocalMulti, isLocalMultiTarget, recordLocalInstance, localVarInfo
    , lookupSchemeMono, putSchemeMono, lookupKernelAbi, putKernelAbi
    , lookupCallMemo, putCallMemo
    , mvarIdKey, pointKey
    , memberIdFor, srcLambdaKey, trivialSignature, emptyLssStats
    , bumpWidenedByKernel, withScratchStore
    )

{-| Core state + step monad for the solver-based monomorphizer.

`S` is one record threading BOTH the global monomorphization state (worklist,
registry, nodes, …) and the per-work-item solver state (the union-find `store`
plus the `memo` mapping MVarIds to union-find Points). `Step a = S -> Result
Failure (a, S)` is a state monad with a failure short-circuit: a `Failure`
aborts the whole monomorphization with a loud `Err` (no fallback to the
original engine — see the module doc of `Compiler.MonoSolver.Monomorphize`).

@docs S, Step, Failure, WorkItem
@docs succeed, fail, andThen, map, map2, traverse, foldlS
@docs getS, modifyS, liftIO, runStep
@docs freshVar, enqueueSpec
@docs freshStore, resetItem
@docs mvarIdKey, pointKey

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Data.Map as DMap
import Data.Set as EverySet
import Dict as CoreDict exposing (Dict)
import System.TypeCheck.IO as IO



-- ====== STATE ======


{-| A unit of pending work: specialize the definition behind this SpecId.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| One annotation arrow's LSS facts (design §7.1):

  - `rep`: smallest ordinal whose set slot the body unified with this one
    (the "same α at two positions" linkage, e.g. `twice : (a -> a) -> a -> a`
    sharing its two arrows).
  - `members`: ids the body itself injects into this arrow's set.
  - `top`: the body forces ⊤ (e.g. the arrow reaches a kernel boundary).

-}
type alias ArrowFact =
    { rep : Int
    , members : List Int
    , top : Bool
    }


{-| Per-definition lambda-set signature: the facts a caller must apply to the
arrows of a fresh instantiation of the def's annotation type, indexed by
ARROW ORDINAL — position in the slot array minted by
`Store.loadTypeIsolatedWithArrows`/`loadTypeWithArrows` over the SAME
annotation type (LSS_006).
-}
type alias LssSignature =
    { arrows : Array ArrowFact
    , trivial : Bool -- every fact is {rep=self, members=[], top=False}
    }


{-| LSS census counters (rendered by the report, `lss.report`).
-}
type alias LssStats =
    { setsZonked : Int
    , joinRounds : Int -- LSS_010 drain-end flush rounds
    , retranslations : Int -- specs re-translated across all flush rounds
    , widenedBySize : Int
    , widenedByKernel : Int
    , widenedByBudget : Int
    , sizeHist : CoreDict.Dict Int Int -- set size -> count (post-zonk)
    }


emptyLssStats : LssStats
emptyLssStats =
    { setsZonked = 0, joinRounds = 0, retranslations = 0, widenedBySize = 0, widenedByKernel = 0, widenedByBudget = 0, sizeHist = CoreDict.empty }


{-| The all-defaults signature for an annotation with `n` arrows.
-}
trivialSignature : Int -> LssSignature
trivialSignature n =
    { arrows = Array.initialize n (\i -> { rep = i, members = [], top = False })
    , trivial = True
    }


{-| A source lambda's member id IS its stamped id (the engine's interning
supply is seeded past `GlobalMVarState.nextLam`, so the two never collide).
-}
srcLambdaKey : TypeIds.SrcLambdaId -> Int
srcLambdaKey =
    Id.toComparable


bumpWidenedByKernel : S -> S
bumpWidenedByKernel s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | widenedByKernel = stats.widenedByKernel + 1 } }


{-| M7: the immutable Reader-style context — set once at `initState`, never
updated. Grouped so `S` updates copy one `env` ref rather than five dead ones.
-}
type alias Env =
    { toptNodes : DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId)
    , annotations : TOpt.AnnotationsByGlobal TypeIds.MVarId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , currentModule : IO.Canonical -- entry module; home of every AnonymousLambda
    , superStatic : Dict Int IO.SuperType -- static solver truth ONLY (loadVar)
    , lss : Config.LssConfig -- lambda-set specialization knobs; enabled=False is byte-identical off
    , lamLabels : CoreDict.Dict Int String -- member id -> "defKey#id" (census rendering only)
    }


{-| The whole engine state: global fields persist across work items; the
per-item fields (`store`, `memo`, `revMemo`) are reset by `resetItem`.
-}
type alias S =
    { -- Global accumulators (mirror State.SpecAccum minus the subst machinery)
      worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , dirtySpecs : BitSet -- LSS_010: specs whose stored type was annotation-JOINED after scheduling; re-translated at drain-end flush rounds (flag-off: never set)
    , dirtyList : List Mono.SpecId -- enumeration twin of dirtySpecs (BitSet has no iteration); duplicate-free via the bit check; consumed by the drain-end flush
    , specCountByGlobal : CoreDict.Dict String Int -- M4 keyed budget: specs created per global (only maintained under lss.keyed; consulted by underBudget)
    , registry : Mono.SpecializationRegistry
    , ports : List Mono.PortRegistration
    , lambdaCounter : Int

    -- Number/super truth: seeded from AssignMVarIds' superVars, read by
    -- loadType when minting a var, and fed to shared Prune at the end.
    , superTable : Dict Int IO.SuperType -- static solver truth + Join-R harvested number-taint (zonk/key/Prune)
    , nextMVarId : TypeIds.MVarId

    -- M2 caches (GLOBAL — survive resetItem; a ground/closed classification is
    -- item-independent). schemeMono: a CLOSED (var-free) callee scheme's
    -- classification, keyed by TOpt.toComparableGlobal. kernelAbiMono: a kernel
    -- ABI derived at all-ground args, keyed by "home.name|argKeys".
    -- LSS (all GLOBAL — survive resetItem; signatures/members are per-run facts)
    , lssSignatures : CoreDict.Dict String LssSignature -- TOpt.toComparableGlobal -> signature
    , lssInProgress : CoreDict.Dict String () -- in-flight inference units (re-entry = EngineBug)
    , lssMembers : CoreDict.Dict String Int -- interned non-lambda member ids (§3.3 keys)
    , nextMemberId : Int -- shared supply, seeded past GlobalMVarState.nextLam
    , lssStats : LssStats

    , schemeMono : CoreDict.Dict String Mono.MonoType
    , kernelAbiMono : CoreDict.Dict String Mono.MonoType
    , callMemo : CoreDict.Dict String ( Mono.MonoType, Mono.MonoType, Mono.SpecId ) -- open-scheme call at all-ground args: (funcMonoType, resultMonoType, specId) — D10 caches specId to skip re-enqueue/re-serialize on a hit
    , nodeResolution : CoreDict.Dict String NodeResolution -- D13: per-GLOBAL node lookup + annotation-id set, keyed by TOpt.toComparableGlobal. Depends only on the immutable toptNodes, so it survives resetItem; a global with N specs resolves once instead of N times.

    -- M7: the 5 IMMUTABLE context fields (never updated after initState) live in
    -- one `env` sub-record, so each `{ s | … }` copies one `env` ref instead of
    -- five refs it never changes.
    , env : Env
    , currentGlobal : Maybe Mono.Global -- (changes per item — stays top-level)

    -- Per-work-item solver state
    , store : IO.State
    , memo : Dict Int IO.Variable -- MVarId (Id.toComparable) -> Point
    , revMemo : Array (Maybe TypeIds.MVarId) -- A2: Point index -> first MVarId that minted it. Point indices are DENSE from 0 in a fresh per-item store, so an Array (indexed by point) replaces the former Dict Int — O(log32) point-keyed reads with no `_Utils_cmp`, sparse structure-point slots hold Nothing.
    , varEnv : CoreDict.Dict String Mono.MonoType -- local variable name -> monomorphized type
    , numberMulti : List NumberMultiEntry -- stack of let-bound number vars being multi-specialized
    , localMulti : List NumberMultiEntry -- stack of let-bound FUNCTIONS being multi-specialized (f, f$1, …)
    , derivedDestructors : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- destructor-bound name -> the destructor's canType (bridges a derived fn's call back to its root's type vars)
    , localCanTypes : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- let-bound name -> its RHS canType (destructor root slot lookup)
    , lssRootAnn : Maybe ( Can.Type TypeIds.MVarId, IO.Variable ) -- lss on, function-root defs only: the demandUnify-seeded annotation var, consumed ONCE by the def-root classifyLambdaHead so binder/param types zonk demand-transported lambda sets (a fresh loadType mints fresh set slots — LSS_006 — so re-loading would lose them)
    }


{-| D13: the per-global result of resolving a `Mono.Global` against `toptNodes`,
plus the annotation-id set harvested from the resolved node. Both depend only on
the immutable node map, so they are computed once per global and reused across
every specialization of that global (memoized in `S.nodeResolution`).
-}
type alias NodeResolution =
    { node : Maybe (TOpt.Node TypeIds.MVarId)
    , annIds : EverySet.EverySet Int Int
    }


{-| A let-bound value being specialized at multiple monomorphic types
(number-multi / value-multi). `instances` is keyed by `toComparableMonoType` of
the demanded type; index 0 keeps the bare name, later ones get `$v<idx>`.
-}
type alias NumberMultiEntry =
    { defName : String
    , instances : CoreDict.Dict String NumberInstance
    }


type alias NumberInstance =
    { freshName : String
    , monoType : Mono.MonoType
    }


{-| Why a work item was abandoned. All are surfaced as a top-level `Err`
(never a fallback): `Unsupported` = feature not yet built; `UnifyMismatch` =
the real unifier rejected something the old engine absorbed silently;
`EngineBug` = an invariant the engine believes cannot happen.
-}
type Failure
    = Unsupported String
    | UnifyMismatch String
    | EngineBug String



-- ====== STEP MONAD ======


{-| A state transition that may fail. Failure aborts the whole pass.
-}
type alias Step a =
    S -> Result Failure ( a, S )


succeed : a -> Step a
succeed a =
    \s -> Ok ( a, s )


fail : Failure -> Step a
fail f =
    \_ -> Err f


andThen : (a -> Step b) -> Step a -> Step b
andThen f step =
    \s ->
        case step s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                f a s1


{-| D1: direct form. The former `andThen (\a -> succeed (f a)) step` allocated the
`\a -> …` closure PLUS the `succeed (f a)` closure on every run; `map` fires on
essentially every zonk/encode node, so the direct `case` form (one closure) is a
broad cut to the monad-closure bucket. Monad-law-preserving → byte-identical.
-}
map : (a -> b) -> Step a -> Step b
map f step =
    \s ->
        case step s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                Ok ( f a, s1 )


map2 : (a -> b -> c) -> Step a -> Step b -> Step c
map2 f sa sb =
    \s ->
        case sa s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                case sb s1 of
                    Err e ->
                        Err e

                    Ok ( b, s2 ) ->
                        Ok ( f a b, s2 )


{-| Thread a step over a list, preserving order. Direct order-preserving
recursion (no intermediate reversed list, no per-element `map` closure); the
lists here are short (type arities / tuple slots / record fields), matching the
non-tail shape already used by `Store.loadListC`/`Translate.classifyList`.
-}
traverse : (a -> Step b) -> List a -> Step (List b)
traverse f items =
    \s -> traverseGo f items s


traverseGo : (a -> Step b) -> List a -> S -> Result Failure ( List b, S )
traverseGo f items s =
    case items of
        [] ->
            Ok ( [], s )

        x :: rest ->
            case f x s of
                Err e ->
                    Err e

                Ok ( b, s1 ) ->
                    case traverseGo f rest s1 of
                        Err e ->
                            Err e

                        Ok ( bs, s2 ) ->
                            Ok ( b :: bs, s2 )


{-| Left fold in the Step monad.
-}
foldlS : (a -> b -> Step b) -> b -> List a -> Step b
foldlS f acc items =
    case items of
        [] ->
            succeed acc

        x :: rest ->
            andThen (\acc1 -> foldlS f acc1 rest) (f x acc)


runStep : Step a -> S -> Result Failure ( a, S )
runStep step s =
    step s


getS : (S -> a) -> Step a
getS f =
    \s -> Ok ( f s, s )


modifyS : (S -> S) -> Step ()
modifyS f =
    \s -> Ok ( (), f s )


{-| Run a solver `IO` action against the item's store.
-}
liftIO : IO.IO a -> Step a
liftIO io =
    \s ->
        let
            ( store1, a ) =
                io s.store
        in
        Ok ( a, { s | store = store1 } )



-- ====== SOLVER-STORE HELPERS ======


{-| Mint a fresh union-find Point with the given content, at the single fixed
engine rank (`outermostRank`). No generalization happens, so any fixed rank is
safe (`Unify.merge` uses `min`, `Occurs` ignores rank).
-}
freshVar : IO.Content -> Step IO.Variable
freshVar content =
    liftIO (UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing))


{-| Member id for a non-lambda function value, interned by kind+identity.
Keys: "g|<global>" (global function ref), "c|<global>" (ctor used as a
function), "k|home.name" (kernel ref), "a|field" (accessor value). Ids come
from the same supply as Phase-0 lambda ids (`nextMemberId` is seeded past
`GlobalMVarState.nextLam`), so member ids never collide (LSS_003).
-}
memberIdFor : String -> Step Int
memberIdFor key s =
    case CoreDict.get key s.lssMembers of
        Just mid ->
            Ok ( mid, s )

        Nothing ->
            let
                mid =
                    s.nextMemberId
            in
            Ok
                ( mid
                , { s
                    | lssMembers = CoreDict.insert key mid s.lssMembers
                    , nextMemberId = mid + 1
                  }
                )


{-| Run a Step against a fresh scratch store, restoring the item's
store/memo/revMemo afterward. This is `Translate.retranslateAt`'s
stash/restore promoted to a combinator — the scratch store's Points never
leak into the surrounding item, and vice versa.
-}
withScratchStore : Step a -> Step a
withScratchStore step s0 =
    let
        sFresh =
            { s0 | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty }
    in
    case step sFresh of
        Err e ->
            Err e

        Ok ( a, s1 ) ->
            Ok ( a, { s1 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo } )



-- ====== WORKLIST / REGISTRY ======


{-| Allocate or reuse the SpecId for a specialization, scheduling it if new.
Mirrors the original `enqueueSpec`: LIFO worklist (cons), `scheduled` dedups.
-}
enqueueSpec : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpec global monoType s =
    -- A1: explicit trailing-S param (was `\s -> …`) → saturated callers avoid the
    -- per-call closure; body unchanged → byte-identical.
    if s.env.lss.enabled && s.env.lss.keyed then
        enqueueSpecKeyed global monoType s

    else
    let
        ( specId, reg1, storedChanged ) =
            if s.env.lss.enabled then
                -- §8.5, keyed=False (M2/M3): keys are today's keys — lambda
                -- sets never fan out specializations; the stored demand is the
                -- annotation JOIN of every admitted demand (LSS_010).
                Registry.getOrCreateSpecIdKeyed global (Mono.widenSets monoType) monoType s.registry

            else
                -- lss off (byte-identical path — no widenSets allocation).
                let
                    ( sid, r ) =
                        Registry.getOrCreateSpecId global monoType s.registry
                in
                ( sid, r, False )
    in
        if BitSet.member specId s.scheduled then
            if storedChanged then
                -- LSS_010: a later demand widened the stored annotations of an
                -- already-scheduled spec. The node (translated, in flight, or
                -- pending) was/will be seeded from a NARROWER demand — its
                -- body annotations could claim a singleton set that lies about
                -- this caller's values, and a fast-dispatch stamp on such a
                -- site is a silent miscompile. Mark dirty ONLY — re-translation
                -- happens in drain-end flush rounds (markDirty), so a spec
                -- re-translates once per round with its FULLY-joined demand
                -- instead of once per join (the per-join immediate re-push
                -- cascaded into hour-scale churn on the self-compile).
                Ok ( specId, markDirty specId reg1 s )

            else
                -- D2: already scheduled and stored type unchanged ⇒ the
                -- registry is the SAME value, so `{ s | registry = reg1 }`
                -- would copy the whole S to change nothing. Return S unaltered.
                Ok ( specId, s )

        else
            Ok
                ( specId
                , { s
                    | registry = reg1
                    , scheduled = BitSet.insertGrowing specId s.scheduled
                    , worklist = SpecializeGlobal specId :: s.worklist
                  }
                )


{-| LSS_010: record that a scheduled spec's stored type was join-widened.
Duplicate-free: the BitSet guards the list. The drain-end flush re-pushes
and `processItem` consumes the bit when it re-translates.
-}
markDirty : Mono.SpecId -> Mono.SpecializationRegistry -> S -> S
markDirty specId reg1 s =
    if BitSet.member specId s.dirtySpecs then
        { s | registry = reg1 }

    else
        { s
            | registry = reg1
            , dirtySpecs = BitSet.insertGrowing specId s.dirtySpecs
            , dirtyList = specId :: s.dirtyList
        }


{-| M4 (`keyed = True`, design §8.5): the dedup KEY is the fully annotated
type while this global is under its spec budget — lambda sets fan out
specializations, giving each caller's member its own copy of the callee
(the precondition for fast dispatch inside shared HOF bodies). Past the
budget, new demands fall back to the widened key (types never widen —
MONO_020/021/024) and the event is counted in `widenedByBudget`.

BOTH branches go through the JOINING variant (LSS_010): an annotated key
can collide with a widened one when the demand is all-`LTop` (an escaping
reference's storeless classify keys exactly like a widened set-bearing
type), and a plain first-demand-wins hit there would resurrect the shared
-spec miscompile through the keyed path. Under-budget hits with identical
annotations short-circuit inside `getOrCreateSpecIdKeyed` (equal stored
type, or a join that changes nothing).

`specCountByGlobal` counts CREATED specs per global (detected by
`registry.nextId` advancing), so budget checks are O(log n) and reuse of
an existing spec never burns budget.
-}
enqueueSpecKeyed : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpecKeyed global monoType s =
    let
        gkey =
            Mono.toComparableGlobal global

        count =
            Maybe.withDefault 0 (CoreDict.get gkey s.specCountByGlobal)

        underBudget =
            count < s.env.lss.maxSpecsPerGlobal

        ( specId, reg1, storedChanged ) =
            if underBudget then
                Registry.getOrCreateSpecIdKeyed global monoType monoType s.registry

            else
                Registry.getOrCreateSpecIdKeyed global (Mono.widenSets monoType) monoType s.registry

        created =
            reg1.nextId > s.registry.nextId

        stats0 =
            s.lssStats

        s1 =
            { s
                | registry = reg1
                , specCountByGlobal =
                    if created then
                        CoreDict.insert gkey (count + 1) s.specCountByGlobal

                    else
                        s.specCountByGlobal
                , lssStats =
                    if underBudget then
                        stats0

                    else
                        { stats0 | widenedByBudget = stats0.widenedByBudget + 1 }
            }
    in
    if BitSet.member specId s1.scheduled then
        if storedChanged then
            -- LSS_010 dirty machinery — mark only; drain-end flush re-pushes.
            Ok ( specId, markDirty specId s1.registry s1 )

        else
            Ok ( specId, s1 )

    else
        Ok
            ( specId
            , { s1
                | scheduled = BitSet.insertGrowing specId s1.scheduled
                , worklist = SpecializeGlobal specId :: s1.worklist
              }
            )



-- ====== PER-ITEM RESET ======


{-| A fresh, empty solver store. Built here (rather than via a private IO.elm
seed) so the engine touches zero lines of the type checker.
-}
freshStore : IO.State
freshStore =
    { ioRefsWeight = Array.empty
    , ioRefsPointInfo = Array.empty
    , ioRefsDescriptor = Array.empty
    , ioRefsMVector = Array.empty
    , names =
        { taken = CoreDict.empty
        , normals = 0
        , numbers = 0
        , comparables = 0
        , appendables = 0
        , compAppends = 0
        }
    , nodeIds =
        { mapping = Array.empty
        , syntheticExprIds = EverySet.empty
        , schemeBinderVars = CoreDict.empty
        , recording = False
        }
    }


{-| Reset the per-work-item solver state before specializing a node.
-}
resetItem : S -> S
resetItem s =
    { s | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, varEnv = CoreDict.empty, numberMulti = [], localMulti = [], derivedDestructors = CoreDict.empty, localCanTypes = CoreDict.empty, lssRootAnn = Nothing }


{-| Bind a local variable's monomorphized type.
-}
insertVar : String -> Mono.MonoType -> Step ()
insertVar name monoType s =
    Ok ( (), { s | varEnv = CoreDict.insert name monoType s.varEnv } )


{-| Look up a local variable's type (populated by let/lambda/destructor bindings).
-}
lookupVar : String -> Step (Maybe Mono.MonoType)
lookupVar name s =
    Ok ( CoreDict.get name s.varEnv, s )


{-| Push an empty number-multi entry for a let-bound number var before walking
its body (instance discovery is body-first).
-}
pushNumberMulti : String -> Step ()
pushNumberMulti defName s =
    Ok ( (), { s | numberMulti = { defName = defName, instances = CoreDict.empty } :: s.numberMulti } )


{-| Pop the top number-multi entry after the body is specialized.
-}
popNumberMulti : Step (Maybe NumberMultiEntry)
popNumberMulti s =
    case s.numberMulti of
        top :: rest ->
            Ok ( Just top, { s | numberMulti = rest } )

        [] ->
            Ok ( Nothing, s )


{-| Is `name` a let-bound number var currently being multi-specialized?
-}
isNumberMultiTarget : String -> Step Bool
isNumberMultiTarget name s =
    Ok ( List.any (\e -> e.defName == name) s.numberMulti, s )


{-| The eager (index-0, bare-name) instance monoType of a number-multi target,
or Nothing if `name` is not one. Used by the destructor-derived divert to
overlay a refined slot onto the root container's type.
-}
numberMultiRootType : String -> Step (Maybe Mono.MonoType)
numberMultiRootType name s =
    Ok
        ( case List.head (List.filter (\e -> e.defName == name) s.numberMulti) of
            Just entry ->
                List.head (List.filter (\i -> i.freshName == name) (CoreDict.values entry.instances))
                    |> Maybe.map .monoType

            Nothing ->
                Nothing
        , s
        )


{-| Record (or reuse) an instance of a number-multi var at the demanded type,
returning its per-instance name (`defName` for the first/Int instance, then
`defName$v<idx>`). Keyed by `toComparableMonoType`.
-}
recordNumberInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordNumberInstance name monoType s =
    recordMultiInstance .numberMulti (\stk st -> { st | numberMulti = stk }) "$v" name monoType s


{-| Push an empty local-multi entry for a let-bound function before walking its
body (each use records the concrete type it is applied at).
-}
pushLocalMulti : String -> Step ()
pushLocalMulti defName s =
    Ok ( (), { s | localMulti = { defName = defName, instances = CoreDict.empty } :: s.localMulti } )


popLocalMulti : Step (Maybe NumberMultiEntry)
popLocalMulti s =
    case s.localMulti of
        top :: rest ->
            Ok ( Just top, { s | localMulti = rest } )

        [] ->
            Ok ( Nothing, s )


isLocalMultiTarget : String -> Step Bool
isLocalMultiTarget name s =
    Ok ( List.any (\e -> e.defName == name) s.localMulti, s )


{-| D9: read all three `VarLocal` classifiers in one `getS` (is-local-multi,
is-number-multi, varEnv binding) — collapses three sequential `getS` andThen
closures on the hot local-ref node into one.
-}
localVarInfo : String -> Step ( Bool, Bool, Maybe Mono.MonoType )
localVarInfo name s =
    Ok
        ( ( List.any (\e -> e.defName == name) s.localMulti
          , List.any (\e -> e.defName == name) s.numberMulti
          , CoreDict.get name s.varEnv
          )
        , s
        )


{-| Record (or reuse) an instance of a local-multi FUNCTION at a demanded type;
per-instance name is `defName` (first) then `defName$<idx>`.
-}
recordLocalInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordLocalInstance name monoType s =
    recordMultiInstance .localMulti (\stk st -> { st | localMulti = stk }) "$" name monoType s


{-| Shared machinery behind `recordNumberInstance` / `recordLocalInstance`:
find the entry for `name` in the given stack, get-or-create an instance keyed
by `toComparableMonoType`, and name it `defName` for index 0 else
`defName ++ sep ++ idx`.
-}
recordMultiInstance : (S -> List NumberMultiEntry) -> (List NumberMultiEntry -> S -> S) -> String -> String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordMultiInstance getStack setStack sep name monoType s =
        let
            key =
                -- Deliberately annotation-SENSITIVE (M4 == audit): local-multi
                -- instances are specialization-intent — differing lambda sets
                -- mint separate per-instance bindings (f / f$1), never share.
                Mono.toComparableMonoType monoType

            update entry =
                case CoreDict.get key entry.instances of
                    Just inst ->
                        ( entry, ( inst.freshName, inst.monoType ) )

                    Nothing ->
                        let
                            idx =
                                CoreDict.size entry.instances

                            freshName =
                                if idx == 0 then
                                    name

                                else
                                    name ++ sep ++ String.fromInt idx

                            inst =
                                { freshName = freshName, monoType = monoType }
                        in
                        ( { entry | instances = CoreDict.insert key inst entry.instances }
                        , ( freshName, monoType )
                        )

            go entries =
                case entries of
                    [] ->
                        ( [], ( name, monoType ) )

                    e :: rest ->
                        if e.defName == name then
                            let
                                ( e1, result ) =
                                    update e
                            in
                            ( e1 :: rest, result )

                        else
                            let
                                ( rest1, result ) =
                                    go rest
                            in
                            ( e :: rest1, result )

            ( newStack, res ) =
                go (getStack s)
        in
        Ok ( res, setStack newStack s )


{-| Run a step in a nested variable scope: bindings introduced inside are
discarded afterward (so they don't leak to sibling expressions). Mirrors the
original engine's varEnv push/pop.
-}
scoped : Step a -> Step a
scoped step s0 =
    case step s0 of
        Err e ->
            Err e

        Ok ( a, s1 ) ->
            Ok ( a, { s1 | varEnv = s0.varEnv } )


{-| Harvest number-taint (Join-R, §5.5) from the finished item's store into the
global super table: every Point that resolved to a `Number` super marks its
originating MVarId as `Number`. The shared Prune then closes any `MVar id
CEcoValue` whose `id` became a number through unification (e.g. a call argument
threading a `number` into a polymorphic parameter) to `MInt`, matching the
original engine's taint-then-close behaviour. Runs before the store is discarded.
-}
harvestSuperTable : S -> S
harvestSuperTable s =
    harvestSuperTableExcept EverySet.empty s


{-| Harvest, excluding the given MVarId keys. Annotation vars of the item's own
global MUST be excluded: they are re-instantiated at a different type by every
specialization of that global, and a Number binding from one spec would make
another spec's residuals stamp CNumber (→ closed to MInt) behind an
erased-typed call site — an ABI break (ListConcatMap empty-call crash).
-}
harvestSuperTableExcept : EverySet.EverySet Int Int -> S -> S
harvestSuperTableExcept excluded s =
    let
        -- A2: revMemo is now an Array indexed by point index; Array.foldl visits
        -- indices 0,1,2,… ascending (== the former Dict.foldl ascending-key order)
        -- with a threaded index counter, skipping empty (Nothing) structure-point
        -- slots (== keys the Dict never had). Byte-identical harvest.
        step maybeMvarId ( pointIdx, ( store, super ) ) =
            ( pointIdx + 1
            , case maybeMvarId of
                Nothing ->
                    ( store, super )

                Just mvarId ->
                    if EverySet.member identity (mvarIdKey mvarId) excluded then
                        ( store, super )

                    else
                        let
                            ( store1, desc ) =
                                UF.get (IO.Pt pointIdx) store
                        in
                        case desc.content of
                            IO.FlexSuper IO.Number _ ->
                                ( store1, CoreDict.insert (mvarIdKey mvarId) IO.Number super )

                            IO.RigidSuper IO.Number _ ->
                                ( store1, CoreDict.insert (mvarIdKey mvarId) IO.Number super )

                            _ ->
                                ( store1, super )
            )

        ( _, ( _, superTable1 ) ) =
            Array.foldl step ( 0, ( s.store, s.superTable ) ) s.revMemo
    in
    { s | superTable = superTable1 }



-- ====== M2 CACHES ======


lookupSchemeMono : String -> Step (Maybe Mono.MonoType)
lookupSchemeMono key =
    getS (\s -> CoreDict.get key s.schemeMono)


putSchemeMono : String -> Mono.MonoType -> Step ()
putSchemeMono key monoType =
    modifyS (\s -> { s | schemeMono = CoreDict.insert key monoType s.schemeMono })


lookupKernelAbi : String -> Step (Maybe Mono.MonoType)
lookupKernelAbi key =
    getS (\s -> CoreDict.get key s.kernelAbiMono)


putKernelAbi : String -> Mono.MonoType -> Step ()
putKernelAbi key monoType =
    modifyS (\s -> { s | kernelAbiMono = CoreDict.insert key monoType s.kernelAbiMono })


lookupCallMemo : String -> Step (Maybe ( Mono.MonoType, Mono.MonoType, Mono.SpecId ))
lookupCallMemo key =
    getS (\s -> CoreDict.get key s.callMemo)


putCallMemo : String -> ( Mono.MonoType, Mono.MonoType, Mono.SpecId ) -> Step ()
putCallMemo key entry =
    modifyS (\s -> { s | callMemo = CoreDict.insert key entry s.callMemo })



-- ====== KEYS ======


mvarIdKey : TypeIds.MVarId -> Int
mvarIdKey =
    Id.toComparable


pointKey : IO.Variable -> Int
pointKey (IO.Pt n) =
    n
