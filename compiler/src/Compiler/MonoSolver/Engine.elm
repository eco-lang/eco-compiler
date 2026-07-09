module Compiler.MonoSolver.Engine exposing
    ( S, Step, Failure(..), WorkItem(..), NumberMultiEntry, NumberInstance
    , succeed, fail, andThen, map, map2, traverse, foldlS
    , getS, modifyS, liftIO, runStep
    , freshVar, enqueueSpec
    , freshStore, resetItem, harvestSuperTable, harvestSuperTableExcept
    , insertVar, lookupVar, scoped
    , pushNumberMulti, popNumberMulti, isNumberMultiTarget, recordNumberInstance, numberMultiRootType
    , pushLocalMulti, popLocalMulti, isLocalMultiTarget, recordLocalInstance
    , mvarIdKey, pointKey
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


{-| The whole engine state: global fields persist across work items; the
per-item fields (`store`, `memo`, `revMemo`) are reset by `resetItem`.
-}
type alias S =
    { -- Global accumulators (mirror State.SpecAccum minus the subst machinery)
      worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , ports : List Mono.PortRegistration
    , lambdaCounter : Int

    -- Number/super truth: seeded from AssignMVarIds' superVars, read by
    -- loadType when minting a var, and fed to shared Prune at the end.
    , superTable : Dict Int IO.SuperType -- static solver truth + Join-R harvested number-taint (zonk/key/Prune)
    , superStatic : Dict Int IO.SuperType -- static solver truth ONLY (loadVar) — one item's bindings must never constrain another item's instantiation
    , nextMVarId : TypeIds.MVarId

    -- Fixed context (currentGlobal changes per item)
    , toptNodes : DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId)
    , annotations : TOpt.AnnotationsByGlobal TypeIds.MVarId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , currentModule : IO.Canonical -- entry module; home of every AnonymousLambda (matches original)
    , currentGlobal : Maybe Mono.Global

    -- Per-work-item solver state
    , store : IO.State
    , memo : Dict Int IO.Variable -- MVarId (Id.toComparable) -> Point
    , revMemo : Dict Int TypeIds.MVarId -- Point index -> first MVarId that minted it
    , varEnv : CoreDict.Dict String Mono.MonoType -- local variable name -> monomorphized type
    , numberMulti : List NumberMultiEntry -- stack of let-bound number vars being multi-specialized
    , localMulti : List NumberMultiEntry -- stack of let-bound FUNCTIONS being multi-specialized (f, f$1, …)
    , derivedDestructors : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- destructor-bound name -> the destructor's canType (bridges a derived fn's call back to its root's type vars)
    , localCanTypes : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- let-bound name -> its RHS canType (destructor root slot lookup)
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


map : (a -> b) -> Step a -> Step b
map f step =
    andThen (\a -> succeed (f a)) step


map2 : (a -> b -> c) -> Step a -> Step b -> Step c
map2 f sa sb =
    andThen (\a -> andThen (\b -> succeed (f a b)) sb) sa


{-| Thread a step over a list, preserving order.
-}
traverse : (a -> Step b) -> List a -> Step (List b)
traverse f items =
    map List.reverse (foldlS (\x acc -> map (\b -> b :: acc) (f x)) [] items)


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



-- ====== WORKLIST / REGISTRY ======


{-| Allocate or reuse the SpecId for a specialization, scheduling it if new.
Mirrors the original `enqueueSpec`: LIFO worklist (cons), `scheduled` dedups.
-}
enqueueSpec : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpec global monoType =
    \s ->
        let
            ( specId, reg1 ) =
                Registry.getOrCreateSpecId global monoType s.registry
        in
        if BitSet.member specId s.scheduled then
            Ok ( specId, { s | registry = reg1 } )

        else
            Ok
                ( specId
                , { s
                    | registry = reg1
                    , scheduled = BitSet.insertGrowing specId s.scheduled
                    , worklist = SpecializeGlobal specId :: s.worklist
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
    { s | store = freshStore, memo = CoreDict.empty, revMemo = CoreDict.empty, varEnv = CoreDict.empty, numberMulti = [], localMulti = [], derivedDestructors = CoreDict.empty, localCanTypes = CoreDict.empty }


{-| Bind a local variable's monomorphized type.
-}
insertVar : String -> Mono.MonoType -> Step ()
insertVar name monoType =
    modifyS (\s -> { s | varEnv = CoreDict.insert name monoType s.varEnv })


{-| Look up a local variable's type (populated by let/lambda/destructor bindings).
-}
lookupVar : String -> Step (Maybe Mono.MonoType)
lookupVar name =
    getS (\s -> CoreDict.get name s.varEnv)


{-| Push an empty number-multi entry for a let-bound number var before walking
its body (instance discovery is body-first).
-}
pushNumberMulti : String -> Step ()
pushNumberMulti defName =
    modifyS (\s -> { s | numberMulti = { defName = defName, instances = CoreDict.empty } :: s.numberMulti })


{-| Pop the top number-multi entry after the body is specialized.
-}
popNumberMulti : Step (Maybe NumberMultiEntry)
popNumberMulti =
    \s ->
        case s.numberMulti of
            top :: rest ->
                Ok ( Just top, { s | numberMulti = rest } )

            [] ->
                Ok ( Nothing, s )


{-| Is `name` a let-bound number var currently being multi-specialized?
-}
isNumberMultiTarget : String -> Step Bool
isNumberMultiTarget name =
    getS (\s -> List.any (\e -> e.defName == name) s.numberMulti)


{-| The eager (index-0, bare-name) instance monoType of a number-multi target,
or Nothing if `name` is not one. Used by the destructor-derived divert to
overlay a refined slot onto the root container's type.
-}
numberMultiRootType : String -> Step (Maybe Mono.MonoType)
numberMultiRootType name =
    getS
        (\s ->
            case List.head (List.filter (\e -> e.defName == name) s.numberMulti) of
                Just entry ->
                    List.head (List.filter (\i -> i.freshName == name) (CoreDict.values entry.instances))
                        |> Maybe.map .monoType

                Nothing ->
                    Nothing
        )


{-| Record (or reuse) an instance of a number-multi var at the demanded type,
returning its per-instance name (`defName` for the first/Int instance, then
`defName$v<idx>`). Keyed by `toComparableMonoType`.
-}
recordNumberInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordNumberInstance =
    recordMultiInstance .numberMulti (\stk s -> { s | numberMulti = stk }) "$v"


{-| Push an empty local-multi entry for a let-bound function before walking its
body (each use records the concrete type it is applied at).
-}
pushLocalMulti : String -> Step ()
pushLocalMulti defName =
    modifyS (\s -> { s | localMulti = { defName = defName, instances = CoreDict.empty } :: s.localMulti })


popLocalMulti : Step (Maybe NumberMultiEntry)
popLocalMulti =
    \s ->
        case s.localMulti of
            top :: rest ->
                Ok ( Just top, { s | localMulti = rest } )

            [] ->
                Ok ( Nothing, s )


isLocalMultiTarget : String -> Step Bool
isLocalMultiTarget name =
    getS (\s -> List.any (\e -> e.defName == name) s.localMulti)


{-| Record (or reuse) an instance of a local-multi FUNCTION at a demanded type;
per-instance name is `defName` (first) then `defName$<idx>`.
-}
recordLocalInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordLocalInstance =
    recordMultiInstance .localMulti (\stk s -> { s | localMulti = stk }) "$"


{-| Shared machinery behind `recordNumberInstance` / `recordLocalInstance`:
find the entry for `name` in the given stack, get-or-create an instance keyed
by `toComparableMonoType`, and name it `defName` for index 0 else
`defName ++ sep ++ idx`.
-}
recordMultiInstance : (S -> List NumberMultiEntry) -> (List NumberMultiEntry -> S -> S) -> String -> String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordMultiInstance getStack setStack sep name monoType =
    \s ->
        let
            key =
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
scoped step =
    \s0 ->
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
        ( _, superTable1 ) =
            CoreDict.foldl
                (\pointIdx mvarId ( store, super ) ->
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
                ( s.store, s.superTable )
                s.revMemo
    in
    { s | superTable = superTable1 }



-- ====== KEYS ======


mvarIdKey : TypeIds.MVarId -> Int
mvarIdKey =
    Id.toComparable


pointKey : IO.Variable -> Int
pointKey (IO.Pt n) =
    n
