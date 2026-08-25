module Compiler.GlobalOpt.MapTemplate exposing
    ( Info, Callee(..), Templates, Stats
    , derive, empty, lookup, report
    )

{-| Licence analysis for the forward `List.map` MLIR template
(`plans/list-map-mlir-template.md` Phase 1.2).

Decides, per `List.map` specialization, whether its body may be replaced by a
forward-iterating `eco.list.map` op instead of the elm/core foldr lowering, and
carries the devirtualization facts emission needs when it may.

**What licenses the replacement.** The template applies the callback
left-to-right where foldr applies it right-to-left, so it needs policy `D-4a`
(`design_docs/debug-log-ordering-policy.md`): the applied callback
specialization must be **transitively `Debug`-free**, and the template must
apply it exactly once per element (which it does). A callback that cannot be
PROVEN Debug-free keeps today's lowering — declining is always sound.

**Three components, and the third is the one `CsePurity` does not have.**

1.  `CsePurity.analyze` — the per-spec transitive fixpoint. Answers
    Debug-freedom for a callback that resolves to a global spec.
2.  A per-closure-INSTANCE extension. An inline lambda has no spec id, so its
    body is walked here and its global references are looked up in (1).
3.  **A higher-order poison arm, in TWO positions.** `CsePurity.scanBody`
    collects only `MonoVarGlobal` callees and treats `MonoVarLocal` as inert,
    so a function value reaching a call site contributes no poison at all.
    Both positions it can reach are covered here:

      - **Callee** — `\x -> g x` with `g` a captured `Debug`-wrapping
        function. `ListMapTemplateCapturedDebugTest.elm` is the canary.
      - **Argument** (F-4) — `\x -> List.sortWith g x`, where the callee is a
        trusted kernel and the poison rides in as an ARGUMENT for that kernel
        to apply. `ListMapTemplateLaunderedDebugTest.elm` is the canary.

    Both are decided by ONE walker (`scanWith`) over a settled member-verdict
    table, so the discipline cannot be present in one consumer and absent in
    another — the failure mode that made the two items inseparable.

**v1 scope: singleton-devirtualized sites only** (recorded per the plan's
"record the choice"). A licensed-but-multi-member set would still buy the
loop/chunk/root-range wins through a generic-apply arm, but it doubles the
expansion's callback surface for the tail of the pool and needs a meet over
every member's licence; the op supports it (callee attr is optional) and the
expansion has the arm, so v1 declining here is a policy choice, not a
capability limit.

**Devirtualization facts are not re-derived here.** `AbiCloning` has already
stamped the `f x` call inside the map body with `fastEvaluator` + `captureAbi`
if and only if that site is safely devirtualizable — including its self-capture
and args-array-convention declines. Reading that stamp reuses every guard the
pass makes instead of replicating (and drifting from) them.

@docs Info, Callee, Templates, Stats
@docs derive, empty, lookup, report

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


{-| Everything emission needs for one licensed `List.map` spec.

`callee` is the fast-clone symbol WITHOUT the `$cap` decision applied —
emission owns that, because it owns `lambdaIdToString`. `captureTypes` is the
instance's capture row in slot order; emission projects them out of the
closure parameter once, before the loop.

`inKind` / `outKind` are 2-bit slot kinds (REP_HEAP_002) for the input element
and the callback result.

-}
type alias Info =
    { callee : Callee
    , inKind : Int
    , outKind : Int
    }


{-| What the emitted `eco.list.map` calls per element.

`CalleeLambda` is the v1 shape: a devirtualized closure instance, whose
capture row emission projects out of the closure parameter once, before the
loop. `CalleeSpec` is a RESOLVED SPEC used directly as the callback — F-5B's bare
constructor (`List.map Just`) and G-3's bare global (`List.map untag`). Either
way there are no captures and no fast-clone symbol: the callback IS a spec, so
emission names it and skips the projection block. Constructors were first only
because their `g|` member resolves to exactly one spec by construction; a
global needs the same layout match plus a Debug-freedom proof.

`CalleeGeneric` is G-1's: a MULTI-MEMBER callback set, where no single symbol
can be named. Emission omits the `callee` attribute and passes no captures —
the shape `ListMapOp::verify` demands ("a generic-apply eco.list.map must have
none") and `EcoListTemplate`'s `emitCallback` falls back to, a saturated
indirect call through the closure value. It buys the loop / chunk / root-range
work, NOT the devirtualized dispatch.

-}
type Callee
    = CalleeLambda Mono.LambdaId (List Mono.MonoType)
    | CalleeSpec Int
    | CalleeGeneric


{-| Why each recognized map spec was or was not licensed. Reconciles as
`licensed + declined* == recognized` (plan Gate 3).
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

    -- Breakdown of `declinedArgTaint` by cause. NOT part of the Gate-3 sum
    -- (it re-partitions one term of it); printed as a second census line only
    -- when the term is non-zero, because the landing gate for the taint rule
    -- is a per-decline genuine/collateral classification.
    , argTaintCauses : ArgTaintCauses

    -- Breakdown of `declinedUnresolvedMember`, on the same footing as
    -- `argTaintCauses`: a re-partition of one Gate-3 term, never part of the
    -- sum. Only `global` is addressable (G-3).
    , unresolvedCauses : UnresolvedCauses

    }


type alias UnresolvedCauses =
    { blocked : Int
    , global : Int
    , missing : Int
    }


type alias ArgTaintCauses =
    { ltop : Int
    , opaqueGlobal : Int
    , memberPoison : Int
    , closurePoison : Int
    }


type alias Templates =
    { bySpec : Dict Int Info
    , stats : Stats
    }


empty : Templates
empty =
    { bySpec = Dict.empty
    , stats = emptyStats
    }


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


bumpUnresolved : UnresolvedCause -> UnresolvedCauses -> UnresolvedCauses
bumpUnresolved cause causes =
    case cause of
        UnresolvedBlocked ->
            { causes | blocked = causes.blocked + 1 }

        UnresolvedGlobal ->
            { causes | global = causes.global + 1 }

        UnresolvedMissing ->
            { causes | missing = causes.missing + 1 }


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


lookup : Int -> Templates -> Maybe Info
lookup specId templates =
    Dict.get specId templates.bySpec


{-| One-line census, greppable as `[map-template]`. Printed like the LSS stats
line; `licensed + declined* == recognized` is the Gate-3 reconciliation.
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


{-| Licence every `List.map` spec the flags and the oracle allow.

Returns `empty` (no work done) when either flag is off, so a flag-off compile
pays nothing and emits nothing — the byte-identity property Gate 2 certifies.

-}
derive : Config.EcoConfig -> Mono.MonoGraph -> Templates
derive cfg graph =
    if not cfg.list.mapTemplate then
        empty

    else if not cfg.list.chunks then
        -- The scratch/chunk machinery is the substrate the expansion builds
        -- on; without it the op has nothing to finish into.
        { bySpec = Dict.empty
        , stats = { emptyStats | declinedChunksOff = countMapSpecs graph }
        }

    else
        deriveLicensed graph


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


type alias Env =
    { purity : CsePurity.Oracle

    -- ONE table over the member universe (`LssFacts.MemberInfo`): blocked,
    -- instance-bearing and standalone members are disjoint arms of a sum, not
    -- three parallel dicts of the same key set.
    , info : Dict Int LssFacts.MemberInfo
    , verdicts : Dict Int Verdict
    , registry : Mono.SpecializationRegistry
    }


bump : (Stats -> Stats) -> Templates -> Templates
bump f t =
    { t | stats = f t.stats }


{-| The per-spec decision ladder. Every arm but the last declines, and every
decline leaves today's foldr lowering in place.
-}
classify : Env -> Int -> Mono.MonoNode -> Templates -> Templates
classify env specId node acc =
    case node of
        Mono.MonoDefine (MonoClosure closureInfo body _) specType ->
            case closureInfo.params of
                [ ( callbackName, callbackType ), ( _, listType ) ] ->
                    -- `resultKind` is the element kind of the spec's RESULT
                    -- list. The stamped path reads it off the callback's ABI
                    -- return type instead; the arms that have no stamp (a
                    -- ctor callee, and G-1's generic apply) need it from the
                    -- type, and G-0's census needs it to size the pool the
                    -- generic arm can actually take.
                    classifyBody env specId callbackName callbackType listType (resultElemKind specType) body acc

                _ ->
                    -- Not the two-parameter `map f xs` shape (a partially
                    -- applied or arity-raised specialization).
                    bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc

        _ ->
            bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc


{-| The element kind of a two-parameter map spec's result list.

`MFunction _ _ _ result` peels the spec's own arrow; `kindOfElement` then
answers the `List b` element kind, or 0 for anything that is not a list.

-}
resultElemKind : Mono.MonoType -> Int
resultElemKind specType =
    case specType of
        Mono.MFunction _ _ _ result ->
            kindOfElement result

        _ ->
            0


classifyBody : Env -> Int -> Name -> Mono.MonoType -> Mono.MonoType -> Int -> MonoExpr -> Templates -> Templates
classifyBody env specId callbackName callbackType listType resultKind body acc =
    let
        -- Shared by the LTop and LVar arms so the two can never drift.
        -- Unknown or widened set. Also the whole subst-engine population:
        -- `headAnno` is never `LSet` there, so subst compiles decline
        -- uniformly and the counter separates the two causes.
        declineTopLike () =
            if Dict.isEmpty env.info then
                bump (\s -> { s | declinedEngine = s.declinedEngine + 1 }) acc

            else
                bump (\s -> { s | declinedWidened = s.declinedWidened + 1 }) acc
    in
    case Mono.headAnno callbackType of
        Mono.LTop ->
            declineTopLike ()

        Mono.LVar _ ->
            -- A variable is as unlicensable as a widened set: the template
            -- needs a NAMED callback, and a variable names nothing yet.
            declineTopLike ()

        Mono.LSet [ member ] ->
            case debugFreedom env member of
                Clean ->
                    license env specId member callbackName callbackType listType body acc

                PoisonUnresolved UnresolvedGlobal ->
                    -- G-3: the table cannot answer a `g|` member (a Global is
                    -- one-to-many over SpecIds), but HERE the callback's own
                    -- type is in hand, which is exactly what the registry
                    -- layout match needs. Resolution has to happen at this
                    -- site rather than inside `standaloneVerdict`, which sees
                    -- only the origin.
                    licenseResolvedGlobal env specId member callbackType listType acc

                poisoned ->
                    countDecline poisoned acc

        Mono.LSet members ->
            licenseGeneric env specId members listType resultKind acc


{-| Record a decline under the cause the verdict names.

Shared by the singleton and multi-member paths so a decline reads the same
whichever set shape produced it — which is what let G-1 retire
`declinedMultiMember`: after it, the member COUNT is no longer a reason to
decline, only what the members are.

`Clean` is unreachable here (its callers license instead) and is total for
exhaustiveness only.

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

        PoisonHigherOrder HOLocalLSet ->
            bump (\s -> { s | declinedCalleeLocalLSet = s.declinedCalleeLocalLSet + 1 }) acc

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


{-| G-1: a multi-member callback set, licensed through the generic arm.

EVERY member must be `Clean` — the meet runs over all of them, and a member
the table cannot answer is `PoisonUnresolved`, never `Clean`. The first
poisoned member's verdict is what the census records.

The `out_kind == 0` precondition is not policy: the expansion derives the
callback's SSA result type from `out_kind` (`headTypeForKind(ctx,
op.getOutKind())`) AND stamps the result list's cells with it, while a
saturated indirect apply yields `!eco.value`. Licensing an unboxed result
would either mistype the call or build a list whose cells disagree with their
static element kind — the defect class the kernel `List.sortWith` fix closed.
Measured 2026-08-15: the restriction costs 1 site of 55.

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
                -- `allocFreeCallbacks` stays 0 for these: with no
                -- devirtualized callee there is no symbol for CGEN_072's
                -- gc-leaf stamp to propagate through.
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


{-| The callback is Debug-free; now emission needs a callee it can name.

Two routes, chosen by the member's ORIGIN:

  - A **constructor** member (F-5B) needs no stamp at all. Recognition is
    registry-origin — `ListCombinators.recognize` admits only elm/core's
    `List.map` — so the spec's denotation is `map` regardless of what
    mono-time devirtualization did to its body, and the stamp's ONLY role was
    ABI discovery. `CalleeCtorSpec` supplies that directly. (This matters
    because E9 devirt rewrites `f x` into a direct ctor call, destroying the
    stamp the other route reads: without this arm every bare-ctor callback
    dead-ends at `declinedNoStamp`.)
  - Anything else reads the stamp `AbiCloning` already annotated on the `f x`
    call. No stamp means that pass declined this instance for one of its own
    reasons (self-capture, args-array convention, non-representative
    instance) — decline with it.

-}
license : Env -> Int -> Int -> Name -> Mono.MonoType -> Mono.MonoType -> MonoExpr -> Templates -> Templates
license env specId member callbackName callbackType listType body acc =
    case Dict.get member env.info of
        Just (LssFacts.MemberStandalone (Mono.OriginCtor ctorGlobal)) ->
            case resolveSpecFor env ctorGlobal callbackType of
                Just ctorSpecId ->
                    -- `allocFreeCallbacks` is NOT incremented: constructing a
                    -- value allocates, by definition. `outKind` is 0 because a
                    -- constructor's result is always a heap value.
                    licenseWith specId
                        { callee = CalleeSpec ctorSpecId
                        , inKind = kindOfElement listType
                        , outKind = 0
                        }
                        0
                        acc

                Nothing ->
                    -- Zero or ambiguous layout matches. A separate counter
                    -- from `declinedNoStamp` on purpose: reusing that one
                    -- would re-create exactly the conflation F-5A abolished,
                    -- and a resolution regression would then hide inside a
                    -- counter with three other causes.
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


{-| G-3: a bare GLOBAL used as the callback (`List.map untag`).

Two conditions, and the second is what makes this a licence rather than a
guess: the registry layout match must be UNIQUE (`resolveSpecFor` declines
zero-or-ambiguous, copying `LssFacts.matchGlobal`'s discipline), and the
resolved spec must be one the purity oracle vouches for. A resolved-but-
unvouched spec is `PoisonOpaqueGlobal` — resolving a SpecId proves WHICH code
runs, never that it is `Debug`-free.

`allocFreeCallbacks` is not incremented: whether the resolved spec allocates
is `allocationFree`'s question and it has no instance index entry to answer
from.

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


{-| The element kind the callback RETURNS, read off its own arrow.

A constructor always yields a heap value, so F-5B pins `outKind = 0`; a global
spec may return an unboxed scalar, and `out_kind` drives both the callback's
SSA result type and the result list's cell kind in the expansion, so it must
be the truth.

-}
resultKindOfCallback : Mono.MonoType -> Int
resultKindOfCallback callbackType =
    case callbackType of
        Mono.MFunction _ _ _ result ->
            kindOf result

        _ ->
            0


{-| Which SpecId IS this global, at this callback's type?

Constructors are registered at their FULL function type
(`Translate.elm`'s ctor registration), so a layout match against the
callback parameter's own type zero-matches any non-unary ctor — **the unary
match IS the arity proof**, and no TOpt access is needed here (GlobalOpt has
none). The same match serves G-3's globals. The type compared is
`callbackType` itself, never a re-derived `elemType -> resultType`:
`callbackType` is what the body's devirtualization registered, so the two
cannot drift after a registry join rewrites the stored entry.

`eqLayout` is name-sensitive for `MCustom`, so an ambiguous match is
effectively impossible; it is still rejected rather than guessed.

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


{-| Find the saturated, exactly-stamped application of the callback parameter
inside the map body. Mirrors `Expr.fastDispatchStamp`'s admissibility test so
emission and licence cannot disagree about what "devirtualized" means.
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


{-| Why a member is not licensable, or `Clean`.

`PoisonOpaqueGlobal` **conflates two causes** and the boolean `CsePurity`
oracle cannot distinguish them: a global that genuinely reaches `Debug.*`
transitively, and a global starved out of `safeSpecs` by the bodiless-spec
hole (`CsePurity` cannot summarize a spec whose body it never sees, so ctor /
enum / accessor-backed specs are absent and every caller of one is poisoned).
On the current self-compile corpus the split is 100% starvation — the Stage-5
artifact contains zero `Elm_Kernel_Debug_log`/`_todo` symbols (measured
2026-08-14) — so no member here reaches `Debug` at all. The split becomes
exact only with `plans/effect-polymorphic-purity.md`'s cause tag; do NOT
"fix" `CsePurity` from this module, which is behaviour-changing and belongs
to that plan.

`PoisonArgTaint` is F-4's: a function VALUE of unprovable provenance reached
an argument position, where a callee this walk cannot see may apply it. It
carries its cause because the landing gate for that rule is a per-decline
classification — genuine (provenance really is unprovable) vs collateral (a
gap in the shape-dispatch rows) — and a bare counter cannot answer it.

-}
type Verdict
    = Clean
    | PoisonDebug
    | PoisonOpaqueGlobal
    | PoisonHigherOrder HOKind
    | PoisonArgTaint ArgCause
    | PoisonUnresolved UnresolvedCause


{-| Why an argument's provenance could not be proven.

  - `ArgLTop` — the value's arrow annotation is `LTop`: the set is unknown, so
    nothing can be proven about what it holds.
  - `ArgOpaqueGlobal` — a global VALUE outside `safeSpecs` (the `CsePurity`
    bodiless-spec starvation, mostly).
  - `ArgMemberPoison` — the annotation resolved to members, and one of them is
    poison; the recorded standalone limitation (`OriginGlobal` members are
    unresolvable here) lands in this bucket too.
  - `ArgClosurePoison` — an inline lambda argument whose own body is poison.

-}
type ArgCause
    = ArgLTop
    | ArgOpaqueGlobal
    | ArgMemberPoison
    | ArgClosurePoison


{-| Why a resolved singleton's member could not be answered.

`declinedUnresolvedMember` is a THREE-way funnel and only one slice is
addressable: `UnresolvedGlobal` names a `g|` member whose Global could be
layout-matched to a SpecId (G-3), whereas a blocked member has no scannable
instance and a miss has neither instance nor origin. Splitting them is what
decides whether that resolution work is worth building.

-}
type UnresolvedCause
    = UnresolvedBlocked
    | UnresolvedGlobal
    | UnresolvedMissing


{-| Which untrusted callee shape poisoned the member.

The distinction is a go/no-go instrument, not a decision input: `HOLocalLSet`
is the only kind lambda-set-directed callee resolution could ever recover
(the callee local's type names a resolvable member set), so its size decides
whether that resolution is worth building at all. Measured 2026-08-14 at
budget 64: LSet 1, LTop 3, Other 0 — ⊤-through-locals dominates, exactly as
the LSS census predicted.

-}
type HOKind
    = HOLocalLSet
    | HOLocalLTop
    | HOOther


{-| The two positions where a walk meets a lambda SET, hooked so that ONE
walker serves both consumers.

`scanDirect` (the member-table builder) cannot consult a table that is not
built yet, so its hooks record EDGES and let the settle pass resolve them.
The licence walk's hooks resolve against the settled table instead. The
argument-taint discipline lives in the walker itself, so it cannot be
present in one consumer and absent in the other — the failure mode the
F-3/F-4 joint-architecture section exists to prevent.

-}
type alias Hooks =
    { calleeSet : List Int -> ( Verdict, Edges )
    , argSet : List Int -> ( Verdict, Edges )
    }


{-| Deferred dependencies of a member, kept SEPARATE by position.

Callee edges propagate their verdict verbatim. Argument edges propagate as
`PoisonArgTaint` unless the edge is genuine `Debug` reachability, so the
counter that names F-4's new declines actually counts them — an
undifferentiated edge set would scatter them across whichever bucket the
depended-on member happened to land in, and the regression-enumeration gate
reads that counter.

-}
type alias Edges =
    { callee : Set Int
    , arg : Set Int
    }


noEdges : Edges
noEdges =
    { callee = Set.empty, arg = Set.empty }


unionEdges : Edges -> Edges -> Edges
unionEdges a b =
    { callee = Set.union a.callee b.callee, arg = Set.union a.arg b.arg }


{-| Table-building hooks: never resolve, always defer to edges.
-}
deferHooks : Hooks
deferHooks =
    { calleeSet = \ms -> ( Clean, { noEdges | callee = Set.fromList ms } )
    , argSet = \ms -> ( Clean, { noEdges | arg = Set.fromList ms } )
    }


clean : ( Verdict, Edges )
clean =
    ( Clean, noEdges )


poison : Verdict -> ( Verdict, Edges )
poison v =
    ( v, noEdges )


{-| First poison wins; edges always union (a poisoned member's edges are
simply never read).
-}
mergeInto : ( Verdict, Edges ) -> ( Verdict, Edges ) -> ( Verdict, Edges )
mergeInto ( v1, e1 ) ( v2, e2 ) =
    ( if v1 == Clean then
        v2

      else
        v1
    , unionEdges e1 e2
    )


{-| The shared walk over one lambda body.

Component 1 supplies the verdict for `MonoVarGlobal` edges (the transitive
`CsePurity` fixpoint). Component 3 is the `MonoCall` arm, which asks two
independent questions:

1.  **Callee position** — applying anything that is not a resolved global /
    kernel / ctor / accessor is poison, because the applied value could be a
    captured `Debug`-wrapping function.
2.  **Argument position** (F-4) — a call may also LAUNDER such a function by
    handing it to a callee that applies it. `List.sortWith` is the canonical
    case: the callee is a trusted kernel, and the poison rides in as an
    argument. Every argument whose type contains an arrow must therefore be
    provably `Debug`-free as a VALUE.

The order inside the arm is PINNED: the ordinary argument recursion runs
first and the taint check only if the fold is still `Clean`, so pre-existing
decline labels are unchanged and `declinedArgTaint` counts exactly the NEW
declines — which is what the regression-enumeration gate assumes.

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
                            -- NOT `PoisonDebug`: absence from `safeSpecs`
                            -- means the oracle could not PROVE freedom, which
                            -- on this corpus is entirely bodiless-spec
                            -- starvation. See `Verdict`.
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


{-| May this call's callee position be trusted, and with what verdict?

`MonoVarLocal` is a function-typed parameter or capture. Its TYPE names the
lambda set it can hold, so the hook decides: the table builder records the
set as edges, and the licence walk either resolves it through the settled
table or declines it as an untrusted higher-order callee.

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

                Mono.LTop ->
                    poison (PoisonHigherOrder HOLocalLTop)

                Mono.LVar _ ->
                    -- Same verdict as LTop: an unnamed higher-order local.
                    poison (PoisonHigherOrder HOLocalLTop)

        MonoClosure _ body _ ->
            -- An immediately-applied lambda: its captures resolve against the
            -- table through their own annotations, by the same walk.
            scanWith purity hooks body

        MonoCall _ inner _ _ _ ->
            -- Over-application of something already trusted stays trusted;
            -- the inner callee carries the real question.
            calleeVerdict purity hooks inner

        _ ->
            poison (PoisonHigherOrder HOOther)


{-| F-4: an argument whose type contains an arrow must be provably
`Debug`-free as a VALUE, or the call may launder it into an application this
walk never sees.
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


{-| Is this argument provably `Debug`-free as a value?

**Shape dispatch runs BEFORE the annotation route, and that order is
load-bearing**: `typeOf` on a statically known clean global can still carry
an `LTop` annotation, and LTop is ~89% of zonked arrows on this corpus, so
without the shape rows every callback that passes a named function to a HOF
would mass-decline. `ListMapTemplateCleanHofTest.elm` is that pin.

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
                            Mono.LTop ->
                                ( PoisonArgTaint ArgLTop, Tuple.second acc )

                            Mono.LVar _ ->
                                -- Same taint as LTop: the argument carries an
                                -- arrow whose inhabitants are not named yet.
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


{-| Every lambda-set annotation reachable through a type's ARROWS.

`MCustom` recurses its TYPE ARGUMENTS — which is NOT field coverage: a
function stored in a concrete field (`type Wrap = Wrap (Int -> Int)`) is
invisible here. That residual is recorded in the F-4 landing note; closing it
needs ctor-shape metadata (or the purity plan, which closes it structurally
for global callees).

`MVar` answers `LTop`: erased polymorphism can hide an arrow, so a type
variable must be treated as if it might be one.

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
            [ Mono.LTop ]

        _ ->
            []



-- THE MEMBER-VERDICT TABLE


type alias Entry =
    { verdict : Verdict
    , edges : Edges
    }


{-| Every lambda-set member's verdict, settled.

Instance members are scanned with the deferring hooks (their callee/argument
sets become EDGES); standalone members resolve immediately from their origin;
blocked members are unresolvable. The settle pass then propagates poison
along the edges to a fixed point.

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


{-| Every instance of a member must be clean: first-poison meet, edge union.
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


{-| Standalone member: global / kernel / ctor / accessor.

`OriginGlobal` is unresolvable HERE: a global member is one-to-many over
SpecIds and this module has no layout-matching index, so resolving it would
duplicate `LssFacts.matchGlobal`'s machinery. Recorded limitation — a
`let f = someGlobal in … f x` callback still declines.

-}
standaloneVerdict : Mono.MemberOrigin -> Verdict
standaloneVerdict origin =
    case origin of
        Mono.OriginKernel home _ ->
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


{-| Propagate poison along the edges to a fixed point.

A `Clean` member with an edge to a non-`Clean` member takes that member's
verdict; a `PoisonDebug` edge wins over any other poison, so `declinedDebug`
keeps naming genuine `Debug` reachability. Verdicts only ever move from
`Clean` to poison over a finite map, so this terminates structurally and
cycles need no special handling: mutually-recursive clean members correctly
stay clean unless poison actually reaches them.

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


        {- An ARGUMENT edge's poison is F-4's decline, whatever the
           depended-on member's own cause was — except genuine `Debug`
           reachability, which keeps its own name so `declinedDebug` stays
           honest (the F-1L rule).
        -}
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


{-| Is every reachable evaluation of this lambda-set member `Debug`-free?

A lookup in the settled table. A member absent from it has no instance index
entry and no origin, so it is unresolvable: the licence is a proof
obligation, and "cannot tell" is a decline.

-}
debugFreedom : Env -> Int -> Verdict
debugFreedom env member =
    Maybe.withDefault (PoisonUnresolved UnresolvedMissing) (Dict.get member env.verdicts)



-- ALLOCATION-FREEDOM (Phase 0.2 second axis; census only)


{-| Does every instance of this callback member avoid allocating?

The callback's body is NOT reachable from the map spec's own body — the lambda
lives at the call site — so this resolves it through the member index, the same
channel the licence walk uses.

Cheap syntactic approximation of the mono cost model's `CAlloc` oracle, used
ONLY to size the statepoint-free-loop pool (Goal 3) in the census. Nothing in
emission or expansion consults it — the gc-leaf stamp is CGEN_072's business
(clause (a)'s poison list is authoritative) and the template never queries it.
It is an under-approximation in both directions: it does not see allocation
inside called globals, and it counts an `eco.box` of a projected scalar as
allocation-free. The near-exact figure is the backend's `calleeGcLeaf` counter.

-}
allocationFree : Env -> Int -> Bool
allocationFree env member =
    case Dict.get member env.info of
        Just (LssFacts.MemberInstances (first :: rest)) ->
            List.all (\ref -> noAllocIn ref.body) (first :: rest)

        _ ->
            False


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



-- KINDS (REP_BOUNDARY_002/003)


{-| The 2-bit slot kind implied by a mono type. Int/Float/Char are the only
unboxed kinds; everything else — Bool included, per FORBID\_CLOSURE\_001 — is
the boxed kind 0. Never a boolean "is unboxed".
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


{-| The element kind of a `List a`, or boxed when the type is not a list.
-}
kindOfElement : Mono.MonoType -> Int
kindOfElement ty =
    case ty of
        Mono.MList _ elemType ->
            kindOf elemType

        _ ->
            0



-- TRAVERSAL


{-| Fold over DIRECT sub-expressions. Exhaustive on purpose: a new `MonoExpr`
constructor must break this compile rather than be silently skipped, which for
a Debug-freedom PROOF would be an unsound-optimistic answer.
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
