module Compiler.GlobalOpt.MapTemplate exposing
    ( Info, Callee(..), Templates, Stats
    , derive, empty, lookup, report
    , ArgTaintCauses, UnresolvedCauses
    )

{-| Decides which specializations of elm/core's `List.map` code generation may
emit as the `eco.list.map` MLIR op, and records what emission needs to name the
callback when it may.

The ordinary lowering of `List.map` is elm/core's own definition, which applies
the callback to the elements from last to first. The `eco.list.map` op applies
it from first to last, once per element. The two give the same list, and they
differ only in the order the callback runs. That order can be observed only
through `Debug`, whose kernels log or crash. So the rule this module rests on is:
a spec is _licensed_ for the op only when every function its callback may be is
proven _Debug-free_, meaning no evaluation of it reaches a `Debug` kernel.
Anything not proven is _declined_, which keeps the ordinary lowering and is
always sound.

The callback parameter's type carries a lambda-set annotation, the set of
functions (its _members_) that value may be. An `LSet` lists every member. An
`LPartial` lists only some, so it never licenses, and neither do `LTop` (the set
is unknown) and `LVar` (not yet named). Each member gets a _verdict_: `Clean`,
or the poison that stops it. Three sources feed the verdicts.

  - A global spec is judged by `CsePurity.analyze`: it is trusted when its id is
    in `safeSpecs`.
  - An inline lambda has no spec id, so its body is walked here, and the globals
    it mentions are looked up in `safeSpecs`.
  - A function value reaching a call is checked here, in two positions.
    In callee position, as in `\x -> g x` with `g` a captured or parameter
    function, the value's own lambda set must be Debug-free. In argument
    position, as in `\x -> List.sortWith g x`, the callee may be trusted and
    still apply `g`, so every argument whose type contains a function must be
    Debug-free as a value. This is _argument taint_.

One walker, `scanWith`, builds the table of member verdicts, and a map spec's
callback is judged by looking up its members in that table. The table is built by
scanning every member, recording each reference to another member as an edge,
and then propagating poison along the edges until nothing changes.

A licensed spec's `Info` names what the op calls per element. A single Clean
member that is not a constructor is named by the stamp `Compiler.GlobalOpt.AbiCloning`
left on the `f x` call in the map body, so a spec that pass did not stamp is
declined. A single constructor or global is named by its own spec id, found by
matching its type in the specialization registry. A set of several Clean members
is licensed as a generic, indirect call, but only when the result element is
boxed.

When `list.mapTemplate` is on, `Stats` counts every recognized map spec
exactly once, as licensed or under one decline cause, and `report` prints it.

@docs Info, Callee, Templates, Stats
@docs derive, empty, lookup, report
@docs ArgTaintCauses, UnresolvedCauses

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.Borrow.LssFacts as LssFacts
import Compiler.GlobalOpt.CsePurity as CsePurity
import Compiler.GlobalOpt.ListCombinators as ListCombinators
import Dict exposing (Dict)
import Set exposing (Set)


{-| The licence for one `List.map` spec: what the op calls per element, and the
kinds of the elements it reads and writes.

`inKind` and `outKind` are slot kinds, the 2-bit code for how a value is stored
in a heap slot: 0 boxed, 1 Int, 2 Float, 3 Char. Bool is boxed. `inKind` is for
the input list's elements and `outKind` for the callback's result.

-}
type alias Info =
    { callee : Callee
    , inKind : Int
    , outKind : Int
    }


{-| What the emitted `eco.list.map` op calls for each element.

`CalleeLambda` is one closure, named by the lambda id `AbiCloning` stamped on
the map body's call of the callback. The list holds the types of its captured
values, in capture order.

`CalleeSpec` is a spec id used directly as the callback: a bare constructor, as
in `List.map Just`, or a bare global function, as in `List.map f`. It has no
captures.

`CalleeGeneric` is a callback that may be any of several functions, so no single
one can be named, and the op calls the closure value indirectly.

-}
type Callee
    = CalleeLambda Mono.LambdaId (List Mono.MonoType)
    | CalleeSpec Int
    | CalleeGeneric


{-| The census of one `derive`: how many `List.map` specs were recognized, how
many were licensed, and why each of the rest was declined.

Every recognized spec is counted once, as `licensed` or in one `declined`
field. When `list.chunks` is off, `recognized` stays 0 and only
`declinedChunksOff` is set; otherwise `licensed` plus the `declined` fields
equals `recognized`.
`argTaintCauses` and `unresolvedCauses` split `declinedArgTaint` and
`declinedUnresolvedMember` by cause and are not part of that sum.
`declinedCalleeLocalLSet` is never incremented. `allocFreeCallbacks` counts
licensed closure callbacks that `allocationFree` judges not to allocate; it only
feeds the census.

-}
type alias Stats =
    { recognized : Int
    , licensed : Int
    , declinedDebug : Int
    , declinedOpaqueGlobal : Int
    , declinedCalleeLocalLSet : Int
    , declinedCalleeLocalLTop : Int
    , declinedCalleeOther : Int
    , declinedArgTaint : Int
    , declinedWidened : Int
    , declinedUnresolvedMember : Int
    , declinedSpecUnresolved : Int
    , declinedGenericUnboxed : Int
    , declinedEngine : Int
    , declinedChunksOff : Int
    , declinedShape : Int
    , declinedNoStamp : Int
    , allocFreeCallbacks : Int

    -- Splits of one counter each, outside the sum
    , argTaintCauses : ArgTaintCauses
    , unresolvedCauses : UnresolvedCauses
    }


{-| The split of `declinedUnresolvedMember` by why a member had no verdict.

`blocked` counts members `LssFacts` records as `MemberBlocked`. `global` counts
members standing for, or reaching along a callee edge, a global function or a
partial application of one, whose verdict the member table cannot give.
`missing` likewise counts members absent from the table, or reaching one along
a callee edge.

-}
type alias UnresolvedCauses =
    { blocked : Int
    , global : Int
    , missing : Int
    }


{-| The split of `declinedArgTaint` by why a function-valued argument could not
be proven Debug-free.

`ltop` counts an argument whose lambda set is not fully listed, or whose type
contains a type variable. `opaqueGlobal` counts a global outside `safeSpecs`.
`memberPoison` counts a listed member that
is poisoned, or poison reaching a member along an argument edge.
`closurePoison` counts an inline lambda whose body is poisoned.

-}
type alias ArgTaintCauses =
    { ltop : Int
    , opaqueGlobal : Int
    , memberPoison : Int
    , closurePoison : Int
    }


{-| The result of `derive`: the licence for each licensed `List.map` spec, keyed
by spec id, and the census.
-}
type alias Templates =
    { bySpec : Dict Int Info
    , stats : Stats
    }


{-| The result with no licensed specs and every count zero.
-}
empty : Templates
empty =
    { bySpec = Dict.empty
    , stats = emptyStats
    }


{-| The census with every count zero.
-}
emptyStats : Stats
emptyStats =
    { recognized = 0
    , licensed = 0
    , declinedDebug = 0
    , declinedOpaqueGlobal = 0
    , declinedCalleeLocalLSet = 0
    , declinedCalleeLocalLTop = 0
    , declinedCalleeOther = 0
    , declinedArgTaint = 0
    , declinedWidened = 0
    , declinedUnresolvedMember = 0
    , declinedSpecUnresolved = 0
    , declinedGenericUnboxed = 0
    , declinedEngine = 0
    , declinedChunksOff = 0
    , declinedShape = 0
    , declinedNoStamp = 0
    , allocFreeCallbacks = 0
    , argTaintCauses = { ltop = 0, opaqueGlobal = 0, memberPoison = 0, closurePoison = 0 }
    , unresolvedCauses = { blocked = 0, global = 0, missing = 0 }
    }


{-| Returns `causes` with the count for `cause` raised by one.
-}
bumpUnresolved : UnresolvedCause -> UnresolvedCauses -> UnresolvedCauses
bumpUnresolved cause causes =
    case cause of
        UnresolvedBlocked ->
            { causes | blocked = causes.blocked + 1 }

        UnresolvedGlobal ->
            { causes | global = causes.global + 1 }

        UnresolvedMissing ->
            { causes | missing = causes.missing + 1 }


{-| Returns `causes` with the count for `cause` raised by one.
-}
bumpCause : ArgCause -> ArgTaintCauses -> ArgTaintCauses
bumpCause cause causes =
    case cause of
        ArgLTop ->
            { causes | ltop = causes.ltop + 1 }

        ArgOpaqueGlobal ->
            { causes | opaqueGlobal = causes.opaqueGlobal + 1 }

        ArgMemberPoison ->
            { causes | memberPoison = causes.memberPoison + 1 }

        ArgClosurePoison ->
            { causes | closurePoison = causes.closurePoison + 1 }


{-| Returns the licence for `specId`, or `Nothing` when that spec is not
licensed.
-}
lookup : Int -> Templates -> Maybe Info
lookup specId templates =
    Dict.get specId templates.bySpec


{-| Renders the census as text, each line starting `[map-template]`.

The first line has every top-level count of `Stats`. A line of the `argTaintCauses` split
follows only when `declinedArgTaint` is not zero, and one of the
`unresolvedCauses` split only when `declinedUnresolvedMember` is not zero.

-}
report : Templates -> String
report { stats } =
    "[map-template] mapTemplate{recognized="
        ++ String.fromInt stats.recognized
        ++ " licensed="
        ++ String.fromInt stats.licensed
        ++ " declinedDebug="
        ++ String.fromInt stats.declinedDebug
        ++ " declinedOpaqueGlobal="
        ++ String.fromInt stats.declinedOpaqueGlobal
        ++ " declinedCalleeLocalLSet="
        ++ String.fromInt stats.declinedCalleeLocalLSet
        ++ " declinedCalleeLocalLTop="
        ++ String.fromInt stats.declinedCalleeLocalLTop
        ++ " declinedCalleeOther="
        ++ String.fromInt stats.declinedCalleeOther
        ++ " declinedArgTaint="
        ++ String.fromInt stats.declinedArgTaint
        ++ " declinedWidened="
        ++ String.fromInt stats.declinedWidened
        ++ " declinedUnresolvedMember="
        ++ String.fromInt stats.declinedUnresolvedMember
        ++ " declinedSpecUnresolved="
        ++ String.fromInt stats.declinedSpecUnresolved
        ++ " declinedGenericUnboxed="
        ++ String.fromInt stats.declinedGenericUnboxed
        ++ " declinedEngine="
        ++ String.fromInt stats.declinedEngine
        ++ " declinedChunksOff="
        ++ String.fromInt stats.declinedChunksOff
        ++ " declinedShape="
        ++ String.fromInt stats.declinedShape
        ++ " declinedNoStamp="
        ++ String.fromInt stats.declinedNoStamp
        ++ "} allocFreeCallbacks="
        ++ String.fromInt stats.allocFreeCallbacks
        ++ (if stats.declinedArgTaint == 0 then
                ""

            else
                "\n[map-template] argTaint{ltop="
                    ++ String.fromInt stats.argTaintCauses.ltop
                    ++ " opaqueGlobal="
                    ++ String.fromInt stats.argTaintCauses.opaqueGlobal
                    ++ " memberPoison="
                    ++ String.fromInt stats.argTaintCauses.memberPoison
                    ++ " closurePoison="
                    ++ String.fromInt stats.argTaintCauses.closurePoison
                    ++ "}"
           )
        ++ (if stats.declinedUnresolvedMember == 0 then
                ""

            else
                "\n[map-template] unresolved{blocked="
                    ++ String.fromInt stats.unresolvedCauses.blocked
                    ++ " global="
                    ++ String.fromInt stats.unresolvedCauses.global
                    ++ " missing="
                    ++ String.fromInt stats.unresolvedCauses.missing
                    ++ "}"
           )



-- DERIVATION


{-| Returns the licences and census for every `List.map` spec in `graph`.

With `list.mapTemplate` off it returns `empty` without looking at the graph.
With `list.chunks` off it licenses nothing and counts every map spec as
`declinedChunksOff`.

-}
derive : Config.EcoConfig -> Mono.MonoGraph -> Templates
derive cfg graph =
    if not cfg.list.mapTemplate then
        empty

    else if not cfg.list.chunks then
        -- The op's expansion is built on the chunk machinery.
        { bySpec = Dict.empty
        , stats = { emptyStats | declinedChunksOff = countMapSpecs graph }
        }

    else
        deriveLicensed graph


{-| Returns how many specs `ListCombinators.recognize` marks as `Map`.
-}
countMapSpecs : Mono.MonoGraph -> Int
countMapSpecs graph =
    ListCombinators.recognize graph
        |> Dict.foldl
            (\_ comb n ->
                if comb == ListCombinators.Map then
                    n + 1

                else
                    n
            )
            0


{-| Returns the licences and census for every map spec, with both flags on.

A map spec whose node is missing from the graph is declined as
`declinedShape`.

-}
deriveLicensed : Mono.MonoGraph -> Templates
deriveLicensed graph =
    let
        (Mono.MonoGraph g) =
            graph

        purity : CsePurity.Oracle
        purity =
            CsePurity.analyze graph

        info : Dict Int LssFacts.MemberInfo
        info =
            LssFacts.buildMemberTable g.nodes g.lssMemberOrigins

        env : Env
        env =
            { purity = purity
            , info = info
            , verdicts = buildVerdictTable purity info
            , registry = g.registry
            }

        mapSpecs : List Int
        mapSpecs =
            ListCombinators.recognize graph
                |> Dict.foldl
                    (\specId comb acc ->
                        if comb == ListCombinators.Map then
                            specId :: acc

                        else
                            acc
                    )
                    []
    in
    List.foldl
        (\specId acc ->
            let
                stats0 =
                    acc.stats

                stats1 =
                    { stats0 | recognized = stats0.recognized + 1 }

                accCounted =
                    { acc | stats = stats1 }
            in
            case Array.get specId g.nodes of
                Just (Just node) ->
                    classify env specId node accCounted

                _ ->
                    bump (\s -> { s | declinedShape = s.declinedShape + 1 }) accCounted
        )
        { bySpec = Dict.empty, stats = emptyStats }
        mapSpecs


{-| What licensing reads for every spec: the purity oracle, what each lambda-set
member is, the settled member verdicts, and the specialization registry.
-}
type alias Env =
    { purity : CsePurity.Oracle
    , info : Dict Int LssFacts.MemberInfo
    , verdicts : Dict Int Verdict
    , registry : Mono.SpecializationRegistry
    }


{-| Returns `t` with `f` applied to its census.
-}
bump : (Stats -> Stats) -> Templates -> Templates
bump f t =
    { t | stats = f t.stats }


{-| Returns `acc` with the map spec `specId` licensed or declined.

Only a definition of a closure with exactly two parameters, the callback and the
list, goes on to be judged by its callback; anything else is declined as
`declinedShape`.

-}
classify : Env -> Int -> Mono.MonoNode -> Templates -> Templates
classify env specId node acc =
    case node of
        Mono.MonoDefine (MonoClosure closureInfo body _) specType ->
            case closureInfo.params of
                [ ( callbackName, callbackType ), ( _, listType ) ] ->
                    classifyBody env specId callbackName callbackType listType (resultElemKind specType) body acc

                _ ->
                    bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc

        _ ->
            bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc


{-| Returns the slot kind of the elements of the list a map spec returns, read
from the result of the outermost function stage of `specType`.

It returns 0, boxed, when `specType` is not a function or that stage's result is
not a list.

-}
resultElemKind : Mono.MonoType -> Int
resultElemKind specType =
    case specType of
        Mono.MFunction _ _ _ result ->
            kindOfElement result

        _ ->
            0


{-| Returns `acc` with the map spec licensed or declined according to the
lambda-set annotation on its callback parameter.

An `LTop`, `LVar` or `LPartial` annotation is declined: as `declinedEngine` when
the member table is empty, and as `declinedWidened` otherwise. A
single member that is `Clean` goes to `license`. A single member standing for a
global function or a partial application of one goes to
`licenseResolvedGlobal`, because only here is the
callback's type at hand to resolve it with. Any other single member is declined
under its verdict. Several members go to `licenseGeneric`.

-}
classifyBody : Env -> Int -> Name -> Mono.MonoType -> Mono.MonoType -> Int -> MonoExpr -> Templates -> Templates
classifyBody env specId callbackName callbackType listType resultKind body acc =
    let
        declineTopLike () =
            if Dict.isEmpty env.info then
                bump (\s -> { s | declinedEngine = s.declinedEngine + 1 }) acc

            else
                bump (\s -> { s | declinedWidened = s.declinedWidened + 1 }) acc
    in
    case Mono.headAnno callbackType of
        Mono.LTop _ ->
            declineTopLike ()

        Mono.LVar _ ->
            declineTopLike ()

        Mono.LPartial _ ->
            -- The listed members may not be all of them.
            declineTopLike ()

        Mono.LSet [ member ] ->
            case debugFreedom env member of
                Clean ->
                    license env specId member callbackName callbackType listType body acc

                PoisonUnresolved UnresolvedGlobal ->
                    licenseResolvedGlobal env specId member callbackType listType acc

                poisoned ->
                    countDecline poisoned acc

        Mono.LSet members ->
            licenseGeneric env specId members listType resultKind acc


{-| Returns `acc` with one decline counted under the cause `verdict` names.

`Clean` changes nothing; no caller passes it.

-}
countDecline : Verdict -> Templates -> Templates
countDecline verdict acc =
    case verdict of
        Clean ->
            acc

        PoisonDebug ->
            bump (\s -> { s | declinedDebug = s.declinedDebug + 1 }) acc

        PoisonOpaqueGlobal ->
            bump (\s -> { s | declinedOpaqueGlobal = s.declinedOpaqueGlobal + 1 }) acc

        PoisonHigherOrder HOLocalLTop ->
            bump (\s -> { s | declinedCalleeLocalLTop = s.declinedCalleeLocalLTop + 1 }) acc

        PoisonHigherOrder HOOther ->
            bump (\s -> { s | declinedCalleeOther = s.declinedCalleeOther + 1 }) acc

        PoisonArgTaint cause ->
            bump
                (\s ->
                    { s
                        | declinedArgTaint = s.declinedArgTaint + 1
                        , argTaintCauses = bumpCause cause s.argTaintCauses
                    }
                )
                acc

        PoisonUnresolved cause ->
            bump
                (\s ->
                    { s
                        | declinedUnresolvedMember = s.declinedUnresolvedMember + 1
                        , unresolvedCauses = bumpUnresolved cause s.unresolvedCauses
                    }
                )
                acc


{-| Returns `acc` with a map spec whose callback may be any of `members`
licensed as `CalleeGeneric`, or declined.

Every member must be `Clean`; otherwise the first poisoned member's verdict is
counted. The result element must also be boxed (`resultKind` 0), or the spec is
declined as `declinedGenericUnboxed`: an indirect call returns a boxed value, and
`outKind` would have to describe an unboxed one.

-}
licenseGeneric : Env -> Int -> List Int -> Mono.MonoType -> Int -> Templates -> Templates
licenseGeneric env specId members listType resultKind acc =
    let
        meet =
            List.foldl
                (\member v ->
                    if v == Clean then
                        debugFreedom env member

                    else
                        v
                )
                Clean
                members
    in
    case meet of
        Clean ->
            if resultKind == 0 then
                licenseWith specId
                    { callee = CalleeGeneric
                    , inKind = kindOfElement listType
                    , outKind = 0
                    }
                    0
                    acc

            else
                bump (\s -> { s | declinedGenericUnboxed = s.declinedGenericUnboxed + 1 }) acc

        poisoned ->
            countDecline poisoned acc


{-| Returns `acc` with a map spec whose single callback `member` is `Clean`
licensed, or declined because no callee can be named.

A constructor member is licensed as `CalleeSpec` of the constructor's spec at
the callback's type, with `outKind` 0 because a constructed value is boxed; if
`resolveSpecFor` finds no unique spec it is declined as
`declinedSpecUnresolved`. Any other member is licensed as `CalleeLambda` from
the stamp `findCallbackStamp` finds on the call of the callback in `body`, with
`outKind` read from the stamped return type, and is declined as
`declinedNoStamp` when there is none.

-}
license : Env -> Int -> Int -> Name -> Mono.MonoType -> Mono.MonoType -> MonoExpr -> Templates -> Templates
license env specId member callbackName callbackType listType body acc =
    case Dict.get member env.info of
        Just (LssFacts.MemberStandalone (Mono.OriginCtor ctorGlobal)) ->
            case resolveSpecFor env ctorGlobal callbackType of
                Just ctorSpecId ->
                    licenseWith specId
                        { callee = CalleeSpec ctorSpecId
                        , inKind = kindOfElement listType
                        , outKind = 0
                        }
                        0
                        acc

                Nothing ->
                    bump (\s -> { s | declinedSpecUnresolved = s.declinedSpecUnresolved + 1 }) acc

        _ ->
            case findCallbackStamp callbackName body of
                Nothing ->
                    bump (\s -> { s | declinedNoStamp = s.declinedNoStamp + 1 }) acc

                Just ( lambdaId, abi ) ->
                    licenseWith specId
                        { callee = CalleeLambda lambdaId abi.captureTypes
                        , inKind = kindOfElement listType
                        , outKind = kindOf abi.returnType
                        }
                        (if allocationFree env member then
                            1

                         else
                            0
                        )
                        acc


{-| Returns `acc` with `info` recorded for `specId`, `licensed` raised by one and
`allocFreeCallbacks` raised by `allocFreeInc`.
-}
licenseWith : Int -> Info -> Int -> Templates -> Templates
licenseWith specId info allocFreeInc acc =
    { bySpec = Dict.insert specId info acc.bySpec
    , stats =
        let
            s =
                acc.stats
        in
        { s
            | licensed = s.licensed + 1
            , allocFreeCallbacks = s.allocFreeCallbacks + allocFreeInc
        }
    }


{-| Returns `acc` with a map spec whose single callback `member` stands for a
global function licensed as `CalleeSpec`, or declined.

The global is resolved to one spec at the callback's type by `resolveSpecFor`,
and declined as `declinedSpecUnresolved` when there is no unique match. Knowing
which spec runs is not knowing it is Debug-free, so the spec must also be in
`safeSpecs`, or it is declined as `declinedOpaqueGlobal`. A member that stands
for a partial application rather than a bare global is declined as an
unresolved member.

-}
licenseResolvedGlobal : Env -> Int -> Int -> Mono.MonoType -> Mono.MonoType -> Templates -> Templates
licenseResolvedGlobal env specId member callbackType listType acc =
    case Dict.get member env.info of
        Just (LssFacts.MemberStandalone (Mono.OriginGlobal g)) ->
            case resolveSpecFor env g callbackType of
                Just globalSpecId ->
                    if BitSet.member globalSpecId env.purity.safeSpecs then
                        licenseWith specId
                            { callee = CalleeSpec globalSpecId
                            , inKind = kindOfElement listType
                            , outKind = resultKindOfCallback callbackType
                            }
                            0
                            acc

                    else
                        bump (\s -> { s | declinedOpaqueGlobal = s.declinedOpaqueGlobal + 1 }) acc

                Nothing ->
                    bump (\s -> { s | declinedSpecUnresolved = s.declinedSpecUnresolved + 1 }) acc

        _ ->
            countDecline (PoisonUnresolved UnresolvedGlobal) acc


{-| Returns the slot kind of the callback's result, read from the result of its
outermost function stage, or 0 when `callbackType` is not a function.
-}
resultKindOfCallback : Mono.MonoType -> Int
resultKindOfCallback callbackType =
    case callbackType of
        Mono.MFunction _ _ _ result ->
            kindOf result

        _ ->
            0


{-| Returns the one spec in the registry for the global `ctorGlobal` whose type
has the same layout (`Mono.eqLayout`) as `callbackType`, or `Nothing` when no
spec or more than one matches.

A constructor's specs are registered at the constructor's whole function type,
so a constructor taking more than one argument does not match a one-argument
callback type.

-}
resolveSpecFor : Env -> Mono.Global -> Mono.MonoType -> Maybe Int
resolveSpecFor env ctorGlobal callbackType =
    let
        step entry ( idx, found, ambiguous ) =
            case entry of
                Just ( g, ty ) ->
                    if g == ctorGlobal && Mono.eqLayout ty callbackType then
                        case found of
                            Nothing ->
                                ( idx + 1, Just idx, ambiguous )

                            Just _ ->
                                ( idx + 1, found, True )

                    else
                        ( idx + 1, found, ambiguous )

                Nothing ->
                    ( idx + 1, found, ambiguous )
    in
    case Array.foldl step ( 0, Nothing, False ) env.registry.reverseMapping of
        ( _, result, False ) ->
            result

        _ ->
            Nothing


{-| Returns the lambda id and capture ABI stamped on the first call in `root`, in
traversal order, that applies the local `callbackName` to one argument and
carries a usable stamp.

A usable stamp names a lambda (`fastEvaluator`) and a capture ABI with one
parameter, and has no partial-application prefix and no `fastEvaluatorSpec`.
A call stamped with a `fastEvaluatorSpec` is skipped because its instance is
emitted under the spec's name, and `CalleeLambda` names it by its lambda id.

-}
findCallbackStamp : Name -> MonoExpr -> Maybe ( Mono.LambdaId, Mono.CaptureABI )
findCallbackStamp callbackName root =
    let
        go expr found =
            case found of
                Just _ ->
                    found

                Nothing ->
                    case expr of
                        MonoCall _ func args _ callInfo ->
                            let
                                hit =
                                    case ( func, callInfo.fastEvaluator, callInfo.captureAbi ) of
                                        ( MonoVarLocal name _, Just lambdaId, Just abi ) ->
                                            if
                                                (name == callbackName)
                                                    && (callInfo.fastPapPrefix == Nothing)
                                                    && (callInfo.fastEvaluatorSpec == Nothing)
                                                    && (List.length args == 1)
                                                    && (List.length abi.paramTypes == 1)
                                            then
                                                Just ( lambdaId, abi )

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                            in
                            case hit of
                                Just _ ->
                                    hit

                                Nothing ->
                                    foldChildren go found expr

                        _ ->
                            foldChildren go found expr
    in
    go root Nothing



-- DEBUG-FREEDOM (the shared walker, the member table, and the taint rule)


{-| The verdict on whether a lambda-set member, or a body being walked, is
proven Debug-free, and if not, why not.

`PoisonDebug` is a reference to a `Debug` kernel in a walked body, a member that
stands for a `Debug` kernel, or either of these reached along an edge in the
member table.

`PoisonOpaqueGlobal` is a global spec outside `CsePurity`'s `safeSpecs`. That
covers a spec that really reaches `Debug` and one `CsePurity` cannot vouch for,
such as an external or effect-manager spec, and the oracle does not tell them
apart.

`PoisonHigherOrder` is a call whose callee is a function value not proven
Debug-free: a local whose lambda set is not fully listed, or another expression
shape the walk does not trust.

`PoisonArgTaint` is a function value passed as an argument that is not proven
Debug-free, since the callee may apply it.

`PoisonUnresolved` is a member the table has no verdict for.

-}
type Verdict
    = Clean
    | PoisonDebug
    | PoisonOpaqueGlobal
    | PoisonHigherOrder HOKind
    | PoisonArgTaint ArgCause
    | PoisonUnresolved UnresolvedCause


{-| Why a function-valued argument could not be proven Debug-free.

`ArgLTop` is an argument whose type contains a function whose lambda set is
`LTop`, `LVar` or `LPartial`, or a type variable, which might stand for a
function.

`ArgOpaqueGlobal` is a global spec outside `safeSpecs`.

`ArgMemberPoison` is a listed member that is poisoned, including one standing
for a global function, which the member table never resolves. Any poison other
than `PoisonDebug` that reaches a member along one of its argument edges is
also counted here.

`ArgClosurePoison` is an inline lambda whose body is poisoned.

-}
type ArgCause
    = ArgLTop
    | ArgOpaqueGlobal
    | ArgMemberPoison
    | ArgClosurePoison


{-| Why the member table has no verdict for a member.

`UnresolvedBlocked` is a member `LssFacts` records as `MemberBlocked`.
`UnresolvedGlobal` is a member standing for a global function or a partial
application of one; a global has a spec per type, and the table has no type to
choose one by. `UnresolvedMissing` is a member absent from the table.

-}
type UnresolvedCause
    = UnresolvedBlocked
    | UnresolvedGlobal
    | UnresolvedMissing


{-| Which kind of untrusted callee caused a `PoisonHigherOrder`.

`HOLocalLTop` is a local whose lambda set is `LTop`, `LVar` or `LPartial`.
`HOOther` is any callee expression the walk does not recognize as trusted. The
two only choose the census counter.

-}
type HOKind
    = HOLocalLTop
    | HOOther


{-| What `scanWith` does on meeting a fully listed lambda set, given its member
ids: `calleeSet` for a local in callee position, `argSet` for an argument.

The only hooks value is `deferHooks`, used to build the member table. Its hooks
answer `Clean` and record the members as edges, because the table they would be
looked up in does not exist yet.

-}
type alias Hooks =
    { calleeSet : List Int -> ( Verdict, Edges )
    , argSet : List Int -> ( Verdict, Edges )
    }


{-| The members a scanned body depends on, by the position it met them in.

`settle` passes a callee edge's poison on unchanged, and an argument edge's as
`PoisonArgTaint ArgMemberPoison` unless it is `PoisonDebug`.

-}
type alias Edges =
    { callee : Set Int
    , arg : Set Int
    }


{-| The empty set of edges.
-}
noEdges : Edges
noEdges =
    { callee = Set.empty, arg = Set.empty }


{-| Returns the edges of `a` and `b` together, position by position.
-}
unionEdges : Edges -> Edges -> Edges
unionEdges a b =
    { callee = Set.union a.callee b.callee, arg = Set.union a.arg b.arg }


{-| The hooks for building the member table: each answers `Clean` and records
the set's members as edges of its position.
-}
deferHooks : Hooks
deferHooks =
    { calleeSet = \ms -> ( Clean, { noEdges | callee = Set.fromList ms } )
    , argSet = \ms -> ( Clean, { noEdges | arg = Set.fromList ms } )
    }


{-| A `Clean` verdict with no edges.
-}
clean : ( Verdict, Edges )
clean =
    ( Clean, noEdges )


{-| Returns verdict `v` with no edges.
-}
poison : Verdict -> ( Verdict, Edges )
poison v =
    ( v, noEdges )


{-| Returns the first verdict unless it is `Clean`, in which case the second,
together with the edges of both.
-}
mergeInto : ( Verdict, Edges ) -> ( Verdict, Edges ) -> ( Verdict, Edges )
mergeInto ( v1, e1 ) ( v2, e2 ) =
    ( if v1 == Clean then
        v2

      else
        v1
    , unionEdges e1 e2
    )


{-| Returns the verdict on `root`, with the edges the hooks recorded.

The walk stops at the first poison, which decides the verdict: a `Debug` kernel
gives `PoisonDebug`, a global spec outside `safeSpecs` gives
`PoisonOpaqueGlobal`. A closure's capture expressions are not walked. At a
call, the callee position is judged by `calleeVerdict`, the callee and arguments
are walked, and only if all of that is `Clean` is each argument checked for
argument taint by `argTaint`. So a call whose arguments are poisoned in their
own right is declined under that poison, not as argument taint.

-}
scanWith : CsePurity.Oracle -> Hooks -> MonoExpr -> ( Verdict, Edges )
scanWith purity hooks root =
    let
        go : MonoExpr -> ( Verdict, Edges ) -> ( Verdict, Edges )
        go expr acc =
            if Tuple.first acc /= Clean then
                acc

            else
                case expr of
                    MonoVarKernel _ _ home _ _ ->
                        if home == "Debug" then
                            mergeInto acc (poison PoisonDebug)

                        else
                            acc

                    MonoVarGlobal _ specId _ ->
                        if BitSet.member specId purity.safeSpecs then
                            acc

                        else
                            -- Not `PoisonDebug`: outside `safeSpecs` means only
                            -- "not proven Debug-free". See `Verdict`.
                            mergeInto acc (poison PoisonOpaqueGlobal)

                    MonoCall _ func args _ _ ->
                        let
                            afterCallee =
                                mergeInto acc (calleeVerdict purity hooks func)

                            afterArgs =
                                List.foldl go (go func afterCallee) args
                        in
                        if Tuple.first afterArgs == Clean then
                            List.foldl (argTaint purity hooks) afterArgs args

                        else
                            afterArgs

                    _ ->
                        foldChildren go acc expr
    in
    go root clean


{-| Returns the verdict on the expression in a call's callee position.

A global in `safeSpecs`, a kernel other than `Debug`, and a record accessor are
`Clean`. A local is judged by its lambda set: a fully listed set goes to the
`calleeSet` hook, and any other set is `PoisonHigherOrder HOLocalLTop`. An
inline lambda applied directly is judged by walking its body, and a call in
callee position by its own callee. Anything else is
`PoisonHigherOrder HOOther`.

-}
calleeVerdict : CsePurity.Oracle -> Hooks -> MonoExpr -> ( Verdict, Edges )
calleeVerdict purity hooks func =
    case func of
        MonoVarGlobal _ specId _ ->
            if BitSet.member specId purity.safeSpecs then
                clean

            else
                poison PoisonOpaqueGlobal

        MonoVarKernel _ _ home _ _ ->
            if home == "Debug" then
                poison PoisonDebug

            else
                clean

        MonoAccessorValue _ _ _ ->
            clean

        MonoVarLocal _ ty ->
            case Mono.headAnno ty of
                Mono.LSet ms ->
                    hooks.calleeSet ms

                Mono.LTop _ ->
                    poison (PoisonHigherOrder HOLocalLTop)

                Mono.LVar _ ->
                    poison (PoisonHigherOrder HOLocalLTop)

                Mono.LPartial _ ->
                    poison (PoisonHigherOrder HOLocalLTop)

        MonoClosure _ body _ ->
            scanWith purity hooks body

        MonoCall _ inner _ _ _ ->
            -- The result of a call is applied again; the inner call's own
            -- arguments are walked separately by `scanWith`.
            calleeVerdict purity hooks inner

        _ ->
            poison (PoisonHigherOrder HOOther)


{-| Returns `acc` joined with the argument-taint verdict on `arg`, when `acc` is
still `Clean` and the type of `arg` contains a function.
-}
argTaint : CsePurity.Oracle -> Hooks -> MonoExpr -> ( Verdict, Edges ) -> ( Verdict, Edges )
argTaint purity hooks arg acc =
    if Tuple.first acc /= Clean then
        acc

    else
        case arrowAnnos (Mono.typeOf arg) of
            [] ->
                acc

            annos ->
                mergeInto acc (argProvenance purity hooks arg annos)


{-| Returns the verdict on a function-valued argument, given the lambda-set
annotations `annos` found in its type.

The argument's shape is tried first: a global in `safeSpecs`, a kernel other
than `Debug` and a record accessor are `Clean`, and an inline lambda is judged by
walking its body. Only another shape is judged by `annos`, where any set not
fully listed is `ArgLTop` and a fully listed one goes to the `argSet` hook. The
order matters because the type of a global's reference can carry an `LTop`
annotation even when the global is in `safeSpecs`.

-}
argProvenance : CsePurity.Oracle -> Hooks -> MonoExpr -> List Mono.LambdaSetAnno -> ( Verdict, Edges )
argProvenance purity hooks arg annos =
    case arg of
        MonoVarGlobal _ specId _ ->
            if BitSet.member specId purity.safeSpecs then
                clean

            else
                poison (PoisonArgTaint ArgOpaqueGlobal)

        MonoVarKernel _ _ home _ _ ->
            if home == "Debug" then
                poison (PoisonArgTaint ArgMemberPoison)

            else
                clean

        MonoAccessorValue _ _ _ ->
            clean

        MonoClosure _ body _ ->
            case scanWith purity hooks body of
                ( Clean, edges ) ->
                    ( Clean, edges )

                ( _, edges ) ->
                    ( PoisonArgTaint ArgClosurePoison, edges )

        _ ->
            List.foldl
                (\anno acc ->
                    if Tuple.first acc /= Clean then
                        acc

                    else
                        case anno of
                            Mono.LTop _ ->
                                ( PoisonArgTaint ArgLTop, Tuple.second acc )

                            Mono.LVar _ ->
                                ( PoisonArgTaint ArgLTop, Tuple.second acc )

                            Mono.LPartial _ ->
                                ( PoisonArgTaint ArgLTop, Tuple.second acc )

                            Mono.LSet ms ->
                                let
                                    ( v, e ) =
                                        hooks.argSet ms
                                in
                                ( if v == Clean then
                                    Clean

                                  else
                                    PoisonArgTaint ArgMemberPoison
                                , unionEdges (Tuple.second acc) e
                                )
                )
                clean
                annos


{-| Returns the lambda-set annotations of the function types found in `ty`.

Function parameters and results, list elements, tuple elements, record fields
and the type arguments of a custom type are searched. The fields of a custom
type are not, so a function held in a field of a type with no type arguments is
not found. A type variable gives `LTop`, because it may stand for a function.

-}
arrowAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
arrowAnnos ty =
    case ty of
        Mono.MFunction _ anno params result ->
            anno :: (List.concatMap arrowAnnos params ++ arrowAnnos result)

        Mono.MList _ elem ->
            arrowAnnos elem

        Mono.MTuple _ elems ->
            List.concatMap arrowAnnos elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldTy acc -> arrowAnnos fieldTy ++ acc) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap arrowAnnos args

        Mono.MVar _ _ ->
            [ Mono.topSynth ]

        _ ->
            []



-- THE MEMBER-VERDICT TABLE


{-| A member's verdict from its own scan, before `settle`, with the members it
depends on.
-}
type alias Entry =
    { verdict : Verdict
    , edges : Edges
    }


{-| Returns the settled verdict for every member in `info`.

A lambda member's instances are scanned with `deferHooks`. A member that is not
a lambda gets its verdict from what it stands for, and a blocked member is
`PoisonUnresolved UnresolvedBlocked`. `settle` then spreads poison along the
edges.

-}
buildVerdictTable : CsePurity.Oracle -> Dict Int LssFacts.MemberInfo -> Dict Int Verdict
buildVerdictTable purity info =
    settle
        (Dict.map
            (\_ mi ->
                case mi of
                    LssFacts.MemberInstances refs ->
                        combineInstances purity refs

                    LssFacts.MemberStandalone origin ->
                        { verdict = standaloneVerdict origin, edges = noEdges }

                    LssFacts.MemberBlocked ->
                        { verdict = PoisonUnresolved UnresolvedBlocked, edges = noEdges }
            )
            info
        )


{-| Returns the entry for a lambda member with instances `refs`: the first
poisoned instance's verdict, or `Clean`, with the edges of all of them.
-}
combineInstances : CsePurity.Oracle -> List LssFacts.LambdaRef -> Entry
combineInstances purity refs =
    List.foldl
        (\ref acc ->
            let
                ( v, e ) =
                    scanWith purity deferHooks ref.body
            in
            { verdict =
                if acc.verdict == Clean then
                    v

                else
                    acc.verdict
            , edges = unionEdges acc.edges e
            }
        )
        { verdict = Clean, edges = noEdges }
        refs


{-| Returns the verdict for a member that is not a lambda, from what it stands
for.

A `Debug` kernel is `PoisonDebug`; any other kernel, a constructor and a record
accessor are `Clean`. A global function, or a partial application of one, is
`PoisonUnresolved UnresolvedGlobal`: a global has a spec per type and the origin
carries no type to choose one by. `classifyBody` resolves such a member only
when it is a map spec's single callback.

-}
standaloneVerdict : Mono.MemberOrigin -> Verdict
standaloneVerdict origin =
    case origin of
        Mono.OriginKernel _ home _ ->
            if home == "Debug" then
                PoisonDebug

            else
                Clean

        Mono.OriginCtor _ ->
            Clean

        Mono.OriginAccessor _ ->
            Clean

        Mono.OriginGlobal _ ->
            PoisonUnresolved UnresolvedGlobal

        Mono.OriginPap _ _ ->
            PoisonUnresolved UnresolvedGlobal


{-| Returns the verdicts after spreading poison along the edges until nothing
changes.

A `Clean` member with an edge to a poisoned member takes that member's poison:
unchanged along a callee edge, and as `PoisonArgTaint ArgMemberPoison` along an
argument edge unless it is `PoisonDebug`. An edge to a member with no entry
counts as `PoisonUnresolved UnresolvedMissing`. When a member's edges lead to
several poisons in one pass, `PoisonDebug` is preferred, otherwise the first
found. A member already poisoned is never changed, so a later pass that finds
`PoisonDebug` behind it does not replace its verdict. Members in a cycle with no
poison reaching them stay `Clean`.

Each pass that changes anything poisons at least one more member, so the pass
count is bounded by the number of members.

-}
settle : Dict Int Entry -> Dict Int Verdict
settle entries =
    let
        worstEdge : (Verdict -> Verdict) -> Set Int -> Dict Int Verdict -> Maybe Verdict -> Maybe Verdict
        worstEdge attribute edges verdicts start =
            Set.foldl
                (\member acc ->
                    if acc == Just PoisonDebug then
                        acc

                    else
                        case Maybe.withDefault (PoisonUnresolved UnresolvedMissing) (Dict.get member verdicts) of
                            Clean ->
                                acc

                            v ->
                                let
                                    attributed =
                                        attribute v
                                in
                                if attributed == PoisonDebug || acc == Nothing then
                                    Just attributed

                                else
                                    acc
                )
                start
                edges

        asArgTaint : Verdict -> Verdict
        asArgTaint v =
            if v == PoisonDebug then
                PoisonDebug

            else
                PoisonArgTaint ArgMemberPoison

        step : Dict Int Verdict -> ( Dict Int Verdict, Bool )
        step verdicts =
            Dict.foldl
                (\member entry ( acc, changed ) ->
                    if Dict.get member acc == Just Clean then
                        case
                            worstEdge asArgTaint
                                entry.edges.arg
                                acc
                                (worstEdge identity entry.edges.callee acc Nothing)
                        of
                            Just p ->
                                ( Dict.insert member p acc, True )

                            Nothing ->
                                ( acc, changed )

                    else
                        ( acc, changed )
                )
                ( verdicts, False )
                entries

        loop : Dict Int Verdict -> Int -> Dict Int Verdict
        loop verdicts fuel =
            if fuel <= 0 then
                verdicts

            else
                case step verdicts of
                    ( next, True ) ->
                        loop next (fuel - 1)

                    ( next, False ) ->
                        next
    in
    loop (Dict.map (\_ entry -> entry.verdict) entries) (Dict.size entries + 1)


{-| Returns the settled verdict for `member`, or
`PoisonUnresolved UnresolvedMissing` when the table has none.
-}
debugFreedom : Env -> Int -> Verdict
debugFreedom env member =
    Maybe.withDefault (PoisonUnresolved UnresolvedMissing) (Dict.get member env.verdicts)



-- ALLOCATION-FREEDOM (census only)


{-| Returns whether `member` is a lambda member with at least one instance and
no instance body that `noAllocIn` finds allocating.

It is used only for the `allocFreeCallbacks` count. It is a syntactic
approximation: allocation inside a called function is not seen.

-}
allocationFree : Env -> Int -> Bool
allocationFree env member =
    case Dict.get member env.info of
        Just (LssFacts.MemberInstances (first :: rest)) ->
            List.all (\ref -> noAllocIn ref.body) (first :: rest)

        _ ->
            False


{-| Returns whether `root` contains no list literal, record creation or update,
tuple creation or closure.
-}
noAllocIn : MonoExpr -> Bool
noAllocIn root =
    let
        go expr ok =
            if not ok then
                False

            else
                case expr of
                    MonoList _ _ _ ->
                        False

                    MonoRecordCreate _ _ ->
                        False

                    MonoRecordUpdate _ _ _ ->
                        False

                    MonoTupleCreate _ _ _ ->
                        False

                    MonoClosure _ _ _ ->
                        False

                    _ ->
                        foldChildren go ok expr
    in
    go root True



-- KINDS


{-| Returns the slot kind of a value of type `ty`: 1 for Int, 2 for Float, 3 for
Char, and 0, boxed, for everything else, Bool included.
-}
kindOf : Mono.MonoType -> Int
kindOf ty =
    case ty of
        Mono.MInt ->
            1

        Mono.MFloat ->
            2

        Mono.MChar ->
            3

        _ ->
            0


{-| Returns the slot kind of the elements of a list type, or 0, boxed, when `ty`
is not a list.
-}
kindOfElement : Mono.MonoType -> Int
kindOfElement ty =
    case ty of
        Mono.MList _ elemType ->
            kindOf elemType

        _ ->
            0



-- TRAVERSAL


{-| Returns `acc` folded with `f` over the direct sub-expressions of `expr`,
except a closure's capture expressions, which are not visited.

The case has no wildcard, so a new `MonoExpr` constructor fails to compile here
rather than having its sub-expressions skipped, which would let a Debug kernel
inside them go unseen.

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


{-| Returns `acc` folded with `f` over the expressions inlined in the leaves of a
decision tree.
-}
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


{-| Returns the expression a `let` definition binds.
-}
defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
