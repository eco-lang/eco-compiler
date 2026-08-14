module Compiler.GlobalOpt.MapTemplate exposing
    ( Info, Templates, Stats
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
3.  **A higher-order poison arm.** `CsePurity.scanBody` collects only
    `MonoVarGlobal` callees and treats `MonoVarLocal` as inert, so a
    `MonoCall` through a function-typed parameter or capture contributes no
    poison at all — `\x -> g x` with `g` a captured `Debug`-wrapping function
    would be wrongly licensed by (1) and (2) alone. Any application of a
    function value that does not resolve to a global/kernel/ctor/accessor
    poisons the member. `ListMapTemplateCapturedDebugTest.elm` is the canary.

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

@docs Info, Templates, Stats
@docs derive, empty, lookup, report

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
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
    { calleeLambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , inKind : Int
    , outKind : Int
    }


{-| Why each recognized map spec was or was not licensed. Reconciles as
`licensed + declined* == recognized` (plan Gate 3).
-}
type alias Stats =
    { recognized : Int
    , licensed : Int
    , declinedDebug : Int
    , declinedHigherOrder : Int
    , declinedWidened : Int
    , declinedMultiMember : Int
    , declinedEngine : Int
    , declinedChunksOff : Int
    , declinedShape : Int
    , declinedNoStamp : Int
    , allocFreeCallbacks : Int
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
    , declinedHigherOrder = 0
    , declinedWidened = 0
    , declinedMultiMember = 0
    , declinedEngine = 0
    , declinedChunksOff = 0
    , declinedShape = 0
    , declinedNoStamp = 0
    , allocFreeCallbacks = 0
    }


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
        ++ " declinedHigherOrder="
        ++ String.fromInt stats.declinedHigherOrder
        ++ " declinedWidened="
        ++ String.fromInt stats.declinedWidened
        ++ " declinedMultiMember="
        ++ String.fromInt stats.declinedMultiMember
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

        ( byMember, blocked ) =
            LssFacts.buildInstances g.nodes

        env : Env
        env =
            { purity = purity
            , byMember = byMember
            , blocked = blocked
            , origins = g.lssMemberOrigins
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
    , byMember : Dict Int (List LssFacts.LambdaRef)
    , blocked : Set Int
    , origins : Dict Int Mono.MemberOrigin
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
        Mono.MonoDefine (MonoClosure closureInfo body _) _ ->
            case closureInfo.params of
                [ ( callbackName, callbackType ), ( _, listType ) ] ->
                    classifyBody env specId callbackName callbackType listType body acc

                _ ->
                    -- Not the two-parameter `map f xs` shape (a partially
                    -- applied or arity-raised specialization).
                    bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc

        _ ->
            bump (\s -> { s | declinedShape = s.declinedShape + 1 }) acc


classifyBody : Env -> Int -> Name -> Mono.MonoType -> Mono.MonoType -> MonoExpr -> Templates -> Templates
classifyBody env specId callbackName callbackType listType body acc =
    case Mono.headAnno callbackType of
        Mono.LTop ->
            -- Unknown or widened set. Also the whole subst-engine population:
            -- `headAnno` is never `LSet` there, so subst compiles decline
            -- uniformly and the counter separates the two causes.
            if Dict.isEmpty env.origins && Dict.isEmpty env.byMember then
                bump (\s -> { s | declinedEngine = s.declinedEngine + 1 }) acc

            else
                bump (\s -> { s | declinedWidened = s.declinedWidened + 1 }) acc

        Mono.LSet [ member ] ->
            case debugFreedom env member of
                PoisonDebug ->
                    bump (\s -> { s | declinedDebug = s.declinedDebug + 1 }) acc

                PoisonHigherOrder ->
                    bump (\s -> { s | declinedHigherOrder = s.declinedHigherOrder + 1 }) acc

                PoisonUnresolved ->
                    bump (\s -> { s | declinedWidened = s.declinedWidened + 1 }) acc

                Clean ->
                    licenseWithStamp env specId member callbackName listType body acc

        Mono.LSet _ ->
            -- v1: singleton-devirtualized sites only (see the module header).
            -- Counted SEPARATELY from declinedWidened on purpose: an unknown
            -- (LTop) set is unlicensable in principle, whereas a multi-member
            -- set is a v1 POLICY decline -- the op's callee attr is optional
            -- and the expansion already has a generic-apply arm, so this
            -- number is the size of the pool a v2 could recover. Conflating
            -- the two would hide that.
            bump (\s -> { s | declinedMultiMember = s.declinedMultiMember + 1 }) acc


{-| The callback is Debug-free; now the site must also be devirtualized.

The stamp is read off the `f x` call `AbiCloning` already annotated. No stamp
means the pass declined this instance for one of its own reasons (self-capture,
args-array convention, non-representative instance) — decline with it.

-}
licenseWithStamp : Env -> Int -> Int -> Name -> Mono.MonoType -> MonoExpr -> Templates -> Templates
licenseWithStamp env specId member callbackName listType body acc =
    case findCallbackStamp callbackName body of
        Nothing ->
            bump (\s -> { s | declinedNoStamp = s.declinedNoStamp + 1 }) acc

        Just ( lambdaId, abi ) ->
            let
                info =
                    { calleeLambdaId = lambdaId
                    , captureTypes = abi.captureTypes
                    , inKind = kindOfElement listType
                    , outKind = kindOf abi.returnType
                    }

                allocFreeInc =
                    if allocationFree env member then
                        1

                    else
                        0
            in
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



-- DEBUG-FREEDOM (the three-component oracle)


type Verdict
    = Clean
    | PoisonDebug
    | PoisonHigherOrder
    | PoisonUnresolved


{-| Is every reachable evaluation of this lambda-set member Debug-free?

Blocked members and members with no resolvable origin are `PoisonUnresolved`:
the licence is a proof obligation, so "cannot tell" is a decline.

-}
debugFreedom : Env -> Int -> Verdict
debugFreedom env member =
    if Set.member member env.blocked then
        PoisonUnresolved

    else
        case Dict.get member env.byMember of
            Just refs ->
                -- Component 2: closure instances have no spec id; walk each
                -- body directly. Every instance of the member must be clean.
                List.foldl
                    (\ref v ->
                        case v of
                            Clean ->
                                scanLambdaBody env ref.body

                            _ ->
                                v
                    )
                    Clean
                    refs

            Nothing ->
                -- Standalone member: global / kernel / ctor / accessor.
                case Dict.get member env.origins of
                    Just (Mono.OriginKernel home _) ->
                        if home == "Debug" then
                            PoisonDebug

                        else
                            Clean

                    Just (Mono.OriginCtor _) ->
                        Clean

                    Just (Mono.OriginAccessor _) ->
                        Clean

                    Just (Mono.OriginGlobal _) ->
                        -- A global member is one-to-many over SpecIds and this
                        -- module has no layout-matching index; resolving it
                        -- would duplicate `LssFacts.matchGlobal`'s machinery
                        -- for a case the stamp already covers (the stamped
                        -- instance is a lambda). Decline rather than guess.
                        PoisonUnresolved

                    Nothing ->
                        PoisonUnresolved


{-| Walk one lambda body for Debug reachability.

Component 1 supplies the verdict for `MonoVarGlobal` edges (the transitive
fixpoint). Component 3 is the `MonoCall` arm: applying anything that is not a
resolved global / kernel / ctor / accessor is poison, because the applied value
could be a captured `Debug`-wrapping function and nothing in the spec graph
records that edge.

-}
scanLambdaBody : Env -> MonoExpr -> Verdict
scanLambdaBody env root =
    let
        go expr v =
            case v of
                Clean ->
                    case expr of
                        MonoVarKernel _ _ home _ _ ->
                            if home == "Debug" then
                                PoisonDebug

                            else
                                Clean

                        MonoVarGlobal _ specId _ ->
                            if Set.member specId env.purity.safeSpecs then
                                Clean

                            else
                                PoisonDebug

                        MonoCall _ func args _ _ ->
                            case applyTargetOk func of
                                False ->
                                    PoisonHigherOrder

                                True ->
                                    List.foldl go (go func Clean) args

                        _ ->
                            foldChildren go Clean expr

                _ ->
                    v
    in
    go root Clean


{-| Component 3's predicate: may this call's callee position be trusted?

`MonoVarLocal` in callee position is a function-typed parameter or capture —
an edge the spec graph does not model, so it is poison. Everything the graph
DOES model (globals, kernels, ctors via `MonoVarGlobal`, accessors) is handled
by the ordinary walk.

-}
applyTargetOk : MonoExpr -> Bool
applyTargetOk func =
    case func of
        MonoVarGlobal _ _ _ ->
            True

        MonoVarKernel _ _ _ _ _ ->
            True

        MonoAccessorValue _ _ _ ->
            True

        MonoCall _ inner _ _ _ ->
            -- Over-application of something already trusted stays trusted;
            -- the inner callee carries the real question.
            applyTargetOk inner

        _ ->
            False



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
    case Dict.get member env.byMember of
        Just (first :: rest) ->
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
