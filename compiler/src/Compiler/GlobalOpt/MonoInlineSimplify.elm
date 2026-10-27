module Compiler.GlobalOpt.MonoInlineSimplify exposing
    ( Metrics, emptyMetrics, optimize, buildBodyLookup, countClosures
    , functionResultCensus, reshapeCensus, reshapeReturnedUids, residualTaxonomy
    )

{-| Removes higher-order plumbing from a monomorphized program, so that less of
it becomes closures and indirect calls at run time.

After monomorphization every function exists as _specializations_, one per
combination of concrete types it is used at, each a node of the `MonoGraph`
numbered by a `SpecId`. A typical program is full of small helpers, lambdas
applied on the spot, partial applications applied once, and lambdas passed to
loops. Left alone, they cost calls and closure objects at run time. This
module rewrites the body of each specialization to remove as many of them as
it can.

A few terms. A call is _exact_ when it passes as many arguments as the callee
takes, _partial_ when it passes fewer, and _over-applied_ when it passes more.
_Beta reduction_ applies a closure literal to arguments: each parameter is bound
by a `let` to its argument under a fresh name, and the closure's body takes the
call's place. _Inlining_ does the same with the body of another
specialization. A partial beta reduction or partial inline cannot remove the
closure: it builds a _residual closure_ over the parameters not yet given. A
residual closure is a new function, not a copy of a source lambda, so its
`srcLambda`, `lssMember`, `closureKind` and `captureAbi` are cleared and it
belongs to no lambda set; building one is a _reshape_.

`optimize` takes each specialization with a body in turn and rewrites it in
rounds, until a round changes nothing or the configured number of rounds has
run. A round is `rewriteExpr` followed by `simplifyLets`. `rewriteExpr` makes
these rewrites:

  - beta reduction of a call whose callee is a closure literal;
  - inlining of a call to an _inline candidate_: a non-recursive `MonoDefine`
    that is within the cost budget or whitelisted, and not blacklisted;
  - _loopification_ of a call that passes a lambda literal to a tail-recursive
    specialization: the call becomes a local loop, a copy of the
    specialization with the lambda in place of the parameter;
  - _application merging_, `(f a) b` to `f a b`, when `f`'s arity is known and
    covers every argument;
  - moving the `let`s out of a callee, `(let d in f) a` to `let d in f a`;
  - _let-callee forwarding_: a `let`-bound closure literal, or partial call,
    used exactly once as the callee of a call, is moved into that call;
  - folding an `if` whose one condition is the literal `True` or `False`.

`simplifyLets` drops unused `let` definitions whose evaluation can be left
out (closures, pure values or, with `kernelFactsDce`, calls of droppable
kernels); it never drops a local tail function.

Which candidates, arities and loopifiable specializations exist is computed
once, after the arity-raising pre-pass (when on) and before the rounds start.
So the body copied into a caller is the callee's body before any round of
rewriting.

Two rules run through the whole module. First, every body copied into a
caller with its parameters bound has its parameters, `let` names and
destructuring names replaced by fresh `mono_inline_<n>` names and its closures
given fresh lambda ids. Closure and local tail-function parameters keep their
names, and the renames stop at them. A callee with no parameters called with
arguments is copied with fresh lambda ids only. Second, a chain of `let`s is
handled as a whole, because the definitions of one chain can refer to each
other in both directions.

With `arityRaise` on, a pre-pass first merges the two stages of a curried
specialization whose body is a closure literal or a call returning a function.
The settings are those of
`Compiler.Eco.Config.InlineConfig`, whose docstring states what each one does.

The module also exposes the censuses the inline report prints:
`countClosures`, `residualTaxonomy`, `functionResultCensus`, `reshapeCensus` and
`reshapeReturnedUids`, and `buildBodyLookup`, a table of inlinable bodies.

@docs Metrics, emptyMetrics, optimize, buildBodyLookup, countClosures
@docs functionResultCensus, reshapeCensus, reshapeReturnedUids, residualTaxonomy

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), MonoGraph(..), MonoNode(..), SpecId)
import Compiler.Data.BitSet as BitSet
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.GlobalOpt.KernelIntrinsics as KernelIntrinsics
import Compiler.Graph as Graph
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Reporting.Annotation as A exposing (Region)
import Dict exposing (Dict)
import Set



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| What `optimize` did, counted over the whole graph, for the inline report.

`inlineCount` counts direct-call inlines, once in each specialization the call
is in, and `inlinedByCallee` splits that count by callee, keyed by its qualified
name (`Module.name`), or `spec:<id>` when the registry gives none.
`inlineSourceSites` counts inlines by source call site, keyed
`<callee>|<row:col-row:col>`, so that the specializations of one source call
share a key; partial inlines are not counted there.

`betaReductions` counts closure literals applied to at least one argument,
those applied by forwarding included, and `betaForwards` counts the let-bound
closures forwarded. `partialMerges` counts application merges and forwarded
partial calls. `loopifiable` is the number of specializations that could be
loopified, and `hofLoopified` the number of calls that were.

`letEliminations` counts dead non-closure definitions dropped, of which
`kernelLetDCE` are calls of a kernel, and `closureDCE` counts dead closure
definitions dropped. `deadLets`, `deadBareKernelVar` and
`deadDroppableKernelLets` are a census of dead `let` definitions, taken each
time a chain is simplified, before anything is dropped: all of them, those
bound to a bare kernel reference, and those bound to a call of a kernel whose
`KernelFacts` row is droppable, whatever the call's arguments. A definition
that stays dead is counted again every round.

`arityRaised` counts specializations raised, and `arityRaiseSkipped` those that
had a raisable shape but were refused. `declinedPreserveSets` counts partial
inlines and partial beta reductions refused under `preserveSets`, and
`declinedArityCap` those refused because the residual closure could exceed
`HeapLimits.maxStageArity`.

`clearedMembers` is filled only with `report` on. A key `RESHAPES|<site>`
counts the residual closures built at `site` (`tryInline` or `beta`), and a key
`<lambda uid>|<member id>|<site>` counts those whose source closure had a
lambda-set member.

-}
type alias Metrics =
    { inlineCount : Int
    , betaReductions : Int
    , betaForwards : Int
    , partialMerges : Int
    , hofLoopified : Int
    , loopifiable : Int
    , letEliminations : Int
    , kernelLetDCE : Int
    , deadLets : Int
    , deadBareKernelVar : Int
    , deadDroppableKernelLets : Int
    , closureDCE : Int
    , arityRaised : Int
    , arityRaiseSkipped : Int
    , inlinedByCallee : Dict String Int
    , inlineSourceSites : Dict String Int
    , declinedPreserveSets : Int
    , declinedArityCap : Int
    , clearedMembers : Dict String Int
    }


{-| Returns the parameters and body of each specialization of the graph that can
be inlined, as they are in the graph, keyed by `SpecId`.

A specialization is included when its node is a `MonoDefine`, it is not
recursive, and its body, or the body of its closure, is not a `MonoCase`. A
`MonoDefine` that is not a closure is included with no parameters. No cost
limit, whitelist or blacklist applies.

A specialization is recursive when it lies on a cycle of the graph's
`callEdges`, a self-edge included. A graph whose `callEdges` is empty, as
`optimize` returns it, has no recursive specialization, so every `MonoDefine`
that is not a case is included.

-}
buildBodyLookup : MonoGraph -> Dict SpecId ( List ( Name, Mono.MonoType ), MonoExpr )
buildBodyLookup (MonoGraph { nodes, callEdges }) =
    let
        callGraph =
            buildCallGraph nodes callEdges
    in
    Array.foldl
        (\maybeNode ( accDict, specId ) ->
            case maybeNode of
                Nothing ->
                    ( accDict, specId + 1 )

                Just node ->
                    let
                        isRecursive =
                            Dict.get specId callGraph.isRecursive
                                |> Maybe.withDefault False
                    in
                    if isRecursive then
                        ( accDict, specId + 1 )

                    else
                        case getInlinableBody node of
                            Nothing ->
                                ( accDict, specId + 1 )

                            Just ( params, body, _ ) ->
                                -- The inliner accepts case bodies; this table does not.
                                if isCase body then
                                    ( accDict, specId + 1 )

                                else
                                    ( Dict.insert specId ( params, body ) accDict, specId + 1 )
        )
        ( Dict.empty, 0 )
        nodes
        |> Tuple.first


{-| Returns the number of closure expressions in the bodies of the graph's
`MonoDefine`, `MonoTailFunc` and port nodes, closures nested in other closures
included. A closure that is a `MonoDefine`'s whole body is the function itself
and is not counted, and neither are the expressions it captures.
-}
countClosures : MonoGraph -> Int
countClosures (MonoGraph { nodes }) =
    let
        countInExpr : MonoExpr -> Int
        countInExpr e =
            Traverse.foldExpr
                (\sub acc ->
                    case sub of
                        MonoClosure _ _ _ ->
                            acc + 1

                        _ ->
                            acc
                )
                0
                e

        countInNode : MonoNode -> Int
        countInNode node =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    countInExpr body

                MonoDefine expr _ ->
                    countInExpr expr

                MonoTailFunc _ expr _ ->
                    countInExpr expr

                MonoPortIncoming expr _ ->
                    countInExpr expr

                MonoPortOutgoing expr _ ->
                    countInExpr expr

                _ ->
                    0
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    acc + countInNode node

                Nothing ->
                    acc
        )
        0
        nodes


{-| Returns the closure expressions left in the graph, counted by where each is
used, largest count first.

The closures counted are those `countClosures` counts, except closures under a
record access. Each is put in a bucket by its position:

  - an argument of a call to a specialization: `arg-to-loopifiable` when the
    callee is a tail function that `inlineConfig` would let loopification copy,
    `arg-to-tailfunc` for any other tail function, `arg-to-ctor` for a
    constructor, `arg-to-global` for a `MonoDefine`, and `arg-to-other-spec`
    otherwise;
  - `arg-to-kernel` for an argument of a kernel, and `arg-to-local` for an
    argument of any other callee;
  - `stored-data` for an element of a list or tuple, or a field of a record or
    a record update;
  - `let-bound` for the bound expression of a `let` definition;
  - `captured` for a value another closure captures;
  - `callee` for the callee of a call;
  - `tailcall-arg` for an argument of a tail call;
  - `value` for the body of a node or of a closure, or the bound expression of
    a local tail function;
  - `other` for an `if` condition, or the record of a record update.

The body of a `let` or a destructuring, and the branches of an `if` or a case,
are counted in the bucket of the expression they belong to. The inside of a
record access is not walked.

-}
residualTaxonomy : Config.InlineConfig -> MonoGraph -> List ( String, Int )
residualTaxonomy inlineConfig (MonoGraph { nodes }) =
    let
        loopifiables =
            buildLoopifiables inlineConfig nodes

        specKind : Int -> String
        specKind specId =
            case Array.get specId nodes of
                Just (Just (MonoTailFunc _ _ _)) ->
                    if Dict.member specId loopifiables then
                        "arg-to-loopifiable"

                    else
                        "arg-to-tailfunc"

                Just (Just (MonoCtor _ _)) ->
                    "arg-to-ctor"

                Just (Just (MonoDefine _ _)) ->
                    "arg-to-global"

                _ ->
                    "arg-to-other-spec"

        bump bucket acc =
            Dict.insert bucket (1 + Maybe.withDefault 0 (Dict.get bucket acc)) acc

        -- `here` is the bucket a closure at this position is counted in.
        taxExpr : String -> MonoExpr -> Dict String Int -> Dict String Int
        taxExpr here expr acc =
            case expr of
                MonoClosure info body _ ->
                    let
                        acc1 =
                            bump here acc

                        acc2 =
                            List.foldl (\( _, ce, _ ) a -> taxExpr "captured" ce a) acc1 info.captures
                    in
                    taxExpr "value" body acc2

                MonoCall _ func args _ _ ->
                    let
                        argBucket =
                            case func of
                                MonoVarGlobal _ specId _ ->
                                    specKind specId

                                MonoVarKernel _ _ _ _ _ ->
                                    "arg-to-kernel"

                                _ ->
                                    "arg-to-local"

                        acc1 =
                            taxExpr "callee" func acc
                    in
                    List.foldl (taxExpr argBucket) acc1 args

                MonoLet def body _ ->
                    let
                        acc1 =
                            case def of
                                Mono.MonoDef _ bound ->
                                    taxExpr "let-bound" bound acc

                                Mono.MonoTailDef _ _ bound ->
                                    taxExpr "value" bound acc
                    in
                    taxExpr here body acc1

                MonoIf branches final _ ->
                    let
                        acc1 =
                            List.foldl (\( c, t ) a -> taxExpr "other" c (taxExpr here t a)) acc branches
                    in
                    taxExpr here final acc1

                MonoCase _ _ decider branches _ ->
                    let
                        acc1 =
                            taxDecider here decider acc
                    in
                    List.foldl (\( _, e ) a -> taxExpr here e a) acc1 branches

                MonoDestruct _ inner _ ->
                    taxExpr here inner acc

                MonoList _ items _ ->
                    List.foldl (taxExpr "stored-data") acc items

                MonoRecordCreate fields _ ->
                    List.foldl (\( _, e ) a -> taxExpr "stored-data" e a) acc fields

                MonoRecordUpdate inner updates _ ->
                    List.foldl (\( _, e ) a -> taxExpr "stored-data" e a) (taxExpr "other" inner acc) updates

                MonoTupleCreate _ items _ ->
                    List.foldl (taxExpr "stored-data") acc items

                MonoTailCall _ entries _ ->
                    List.foldl (\( _, e ) a -> taxExpr "tailcall-arg" e a) acc entries

                _ ->
                    acc

        taxDecider here decider acc =
            case decider of
                Mono.Leaf (Mono.Inline e) ->
                    taxExpr here e acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ success failure ->
                    taxDecider here failure (taxDecider here success acc)

                Mono.FanOut _ tests fallback ->
                    taxDecider here fallback (List.foldl (\( _, d ) a -> taxDecider here d a) acc tests)

        taxNode node acc =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    taxExpr "value" body acc

                MonoDefine expr _ ->
                    taxExpr "value" expr acc

                MonoTailFunc _ expr _ ->
                    taxExpr "value" expr acc

                MonoPortIncoming expr _ ->
                    taxExpr "value" expr acc

                MonoPortOutgoing expr _ ->
                    taxExpr "value" expr acc

                _ ->
                    acc
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    taxNode node acc

                Nothing ->
                    acc
        )
        Dict.empty
        nodes
        |> Dict.toList
        |> List.sortBy (\( _, n ) -> negate n)


{-| Returns, for each function-result specialization of `nodes`, how its
calls are used, as the bucket counts `functionResultCensus` describes. Every
function-result specialization has an entry, an empty one when it has no
counted calls.
-}
fnResultSiteCensus : Array (Maybe MonoNode) -> Dict Int (Dict String Int)
fnResultSiteCensus nodes =
    let
        fnResultSpecs : Dict Int Int
        fnResultSpecs =
            Array.foldl
                (\maybeNode ( acc, specId ) ->
                    case maybeNode of
                        Just (MonoDefine (MonoClosure info body _) _) ->
                            case Mono.typeOf body of
                                Mono.MFunction _ _ _ _ ->
                                    ( Dict.insert specId (List.length info.params) acc, specId + 1 )

                                _ ->
                                    ( acc, specId + 1 )

                        _ ->
                            ( acc, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first

        -- Every function-result spec gets an entry, possibly empty, so that the
        -- report can count them.
        emptyCensus : Dict Int (Dict String Int)
        emptyCensus =
            Dict.map (\_ _ -> Dict.empty) fnResultSpecs

        bump specId bucket acc =
            Dict.update specId
                (Maybe.map
                    (\d -> Dict.insert bucket (1 + Maybe.withDefault 0 (Dict.get bucket d)) d)
                )
                acc

        siteBucket here =
            case here of
                "callee" ->
                    "fnres-applied"

                "let-bound" ->
                    "fnres-let-bound"

                "arg" ->
                    "fnres-arg"

                "stored" ->
                    "fnres-stored"

                "value" ->
                    "fnres-returned"

                _ ->
                    "fnres-other"

        cenExpr : String -> MonoExpr -> Dict Int (Dict String Int) -> Dict Int (Dict String Int)
        cenExpr here expr acc =
            case expr of
                MonoCall _ func args _ _ ->
                    let
                        acc1 =
                            case func of
                                MonoVarGlobal _ specId _ ->
                                    case Dict.get specId fnResultSpecs of
                                        Just nParams ->
                                            if List.length args == nParams then
                                                bump specId (siteBucket here) acc

                                            else
                                                acc

                                        Nothing ->
                                            acc

                                _ ->
                                    acc

                        acc2 =
                            cenExpr "callee" func acc1
                    in
                    List.foldl (cenExpr "arg") acc2 args

                MonoClosure _ body _ ->
                    cenExpr "value" body acc

                MonoLet def body _ ->
                    let
                        acc1 =
                            case def of
                                Mono.MonoDef _ bound ->
                                    cenExpr "let-bound" bound acc

                                Mono.MonoTailDef _ _ bound ->
                                    cenExpr "value" bound acc
                    in
                    cenExpr here body acc1

                MonoIf branches final _ ->
                    let
                        acc1 =
                            List.foldl (\( c, t ) a -> cenExpr "other" c (cenExpr here t a)) acc branches
                    in
                    cenExpr here final acc1

                MonoCase _ _ decider branches _ ->
                    let
                        acc1 =
                            cenDecider here decider acc
                    in
                    List.foldl (\( _, e ) a -> cenExpr here e a) acc1 branches

                MonoDestruct _ inner _ ->
                    cenExpr here inner acc

                MonoList _ items _ ->
                    List.foldl (cenExpr "stored") acc items

                MonoRecordCreate fields _ ->
                    List.foldl (\( _, e ) a -> cenExpr "stored" e a) acc fields

                MonoRecordUpdate inner updates _ ->
                    List.foldl (\( _, e ) a -> cenExpr "stored" e a) (cenExpr "other" inner acc) updates

                MonoTupleCreate _ items _ ->
                    List.foldl (cenExpr "stored") acc items

                MonoTailCall _ entries _ ->
                    List.foldl (\( _, e ) a -> cenExpr "arg" e a) acc entries

                _ ->
                    acc

        cenDecider here decider acc =
            case decider of
                Mono.Leaf (Mono.Inline e) ->
                    cenExpr here e acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ success failure ->
                    cenDecider here failure (cenDecider here success acc)

                Mono.FanOut _ tests fallback ->
                    cenDecider here fallback (List.foldl (\( _, d ) a -> cenDecider here d a) acc tests)

        cenNode node acc =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    cenExpr "value" body acc

                MonoDefine expr _ ->
                    cenExpr "value" expr acc

                MonoTailFunc _ expr _ ->
                    cenExpr "value" expr acc

                _ ->
                    acc
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    cenNode node acc

                Nothing ->
                    acc
        )
        emptyCensus
        nodes


{-| Returns how the results of calls to function-result specializations are
used, counted over the whole graph, largest count first.

A _function-result specialization_ is a `MonoDefine` closure whose body has a
function type, `f : a -> (s -> r)`. A call to one counts when it passes exactly
as many arguments as the closure has parameters. Its result is counted in
`fnres-applied` when the call is itself called, `fnres-let-bound` when it is
bound by a `let`, `fnres-arg` when it is an argument of a call or tail call,
`fnres-stored` when it is an element of a list, tuple or record, or a field of
a record update, `fnres-returned` when it is the body of a node, a closure or a
local tail function, or in tail position of one, and `fnres-other` anywhere
else. `fnres-specs` is the number of function-result specializations.

Only the bodies of `MonoDefine` and `MonoTailFunc` nodes are walked, and not
the inside of a record access, nor the expressions a closure captures.

-}
functionResultCensus : MonoGraph -> List ( String, Int )
functionResultCensus (MonoGraph { nodes }) =
    let
        perSpec =
            fnResultSiteCensus nodes
    in
    Dict.foldl
        (\_ buckets acc ->
            Dict.foldl
                (\bucket n a -> Dict.insert bucket (n + Maybe.withDefault 0 (Dict.get bucket a)) a)
                acc
                buckets
        )
        (Dict.singleton "fnres-specs" (Dict.size perSpec))
        perSpec
        |> Dict.toList
        |> List.sortBy (\( _, n ) -> negate n)


{-| Returns whether specialization `specId` has enough applied calls in
`census` to be raised: at least one `fnres-applied` call, and `fnres-applied`
at least `minPercent` percent of its counted calls. A specialization with no
entry in `census` is refused.
-}
raiseAllowedBySites : Int -> Dict Int (Dict String Int) -> Int -> Bool
raiseAllowedBySites minPercent census specId =
    case Dict.get specId census of
        Nothing ->
            False

        Just buckets ->
            let
                applied =
                    Maybe.withDefault 0 (Dict.get "fnres-applied" buckets)

                total =
                    Dict.foldl (\_ n s -> s + n) 0 buckets
            in
            applied > 0 && applied * 100 >= total * minPercent


{-| Returns the arity of specialization `specId`, following an alias of
another global at most `fuel` times.

A closure `MonoDefine` or a `MonoTailFunc` gives its parameter count. A
`MonoDefine` whose body is a kernel reference gives the flat arity of the
kernel's type (`flatArrowArity`), when that is above zero. A `MonoDefine` whose
body is a global reference gives the arity of that global. Anything else, or
running out of fuel, gives `Nothing`.

-}
aliasArity : Array (Maybe MonoNode) -> Int -> Int -> Maybe Int
aliasArity nodes fuel specId =
    if fuel <= 0 then
        Nothing

    else
        case Array.get specId nodes of
            Just (Just (MonoDefine (MonoClosure info _ _) _)) ->
                Just (List.length info.params)

            Just (Just (MonoTailFunc params _ _)) ->
                Just (List.length params)

            Just (Just (MonoDefine (MonoVarKernel _ _ _ _ kernelType) _)) ->
                let
                    n =
                        flatArrowArity kernelType
                in
                if n > 0 then
                    Just n

                else
                    Nothing

            Just (Just (MonoDefine (MonoVarGlobal _ target _) _)) ->
                aliasArity nodes (fuel - 1) target

            _ ->
                Nothing


{-| Returns `nodes` with every specialization that `raiseOne` can raise
replaced by its raised form, and the counts of specializations raised and of
those refused.

A specialization with a raisable shape is refused, and left as it is, when
`allowSpec` refuses it or when its raised closure would have more parameters
plus captures than `HeapLimits.maxStageArity` allows. The order of `nodes`, and
so every `SpecId`, is unchanged.

-}
raiseStagedSpecs : (Int -> Bool) -> Array (Maybe MonoNode) -> ( Array (Maybe MonoNode), ( Int, Int ) )
raiseStagedSpecs allowSpec nodes =
    Array.foldl
        (\maybeNode ( acc, specId, ( nRaised, nSkipped ) ) ->
            case maybeNode of
                Just (MonoDefine (MonoClosure info body cty) defTy) ->
                    case raiseOne specId info body cty defTy of
                        Just raised ->
                            if allowSpec specId && not (raisedExceedsStageArity raised) then
                                ( Array.push (Just raised) acc, specId + 1, ( nRaised + 1, nSkipped ) )

                            else
                                ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped + 1 ) )

                        Nothing ->
                            ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped ) )

                _ ->
                    ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped ) )
        )
        ( Array.empty, 0, ( 0, 0 ) )
        nodes
        |> (\( acc, _, counters ) -> ( acc, counters ))


{-| Returns whether a raised node's closure has more parameters plus captures
than `HeapLimits.maxStageArity` allows.
-}
raisedExceedsStageArity : MonoNode -> Bool
raisedExceedsStageArity node =
    case node of
        MonoDefine (MonoClosure info _ _) _ ->
            exceedsStageArity info.params info.captures

        _ ->
            False


{-| Returns the raised form of specialization `specId`, the `MonoDefine` of
the closure with `info`, `body` and type `cty` whose node has type `defTy`, or
`Nothing` when it cannot be raised.

_Arity raising_ turns a closure whose body returns a function, `\p -> \s -> e`,
into one closure taking both stages' parameters, `\p s -> e`. `cty` and `defTy`
lose a stage the same way (`flattenArrowOnce`). Two shapes of body qualify:

  - A closure literal. Its parameters are appended, and its body becomes the
    body.
  - A call whose callee is not a local variable and whose type is a function.
    Fresh parameters `_h62ar<specId>_<i>` are appended for the first stage of
    the call's result, and the body becomes the call applied to them.

Any other body, and a type without two stages, does not qualify. The raised
closure is a new function: its `srcLambda`, `lssMember`, `closureKind` and
`captureAbi` are cleared.

-}
raiseOne : Int -> Mono.ClosureInfo -> MonoExpr -> Mono.MonoType -> Mono.MonoType -> Maybe MonoNode
raiseOne specId info body cty defTy =
    case ( flattenArrowOnce cty, flattenArrowOnce defTy ) of
        ( Just ctyFlat, Just defTyFlat ) ->
            case body of
                MonoClosure innerInfo innerBody _ ->
                    -- The inner params come from the same source function as
                    -- the outer ones, and Elm forbids shadowing, so they need
                    -- no renaming.
                    Just
                        (MonoDefine
                            (MonoClosure
                                { info
                                    | params = info.params ++ innerInfo.params
                                    , srcLambda = Nothing
                                    , lssMember = Nothing
                                    , closureKind = Nothing
                                    , captureAbi = Nothing
                                }
                                innerBody
                                ctyFlat
                            )
                            defTyFlat
                        )

                MonoCall _ (MonoVarLocal _ _) _ _ _ ->
                    -- A body that calls a local (`apR x f = f x`) stays staged:
                    -- raised, each call at the old arity would be a partial
                    -- application of it.
                    Nothing

                MonoCall region _ _ _ _ ->
                    -- No cost limit applies to this shape. A raised value that
                    -- is applied more than once runs the old first stage at
                    -- each application.
                    case Mono.typeOf body of
                        Mono.MFunction _ _ stageTys retTy ->
                            let
                                freshParams =
                                    List.indexedMap
                                        (\i ty -> ( "_h62ar" ++ String.fromInt specId ++ "_" ++ String.fromInt i, ty ))
                                        stageTys

                                argRefs =
                                    List.map (\( n, ty ) -> MonoVarLocal n ty) freshParams
                            in
                            Just
                                (MonoDefine
                                    (MonoClosure
                                        { info
                                            | params = info.params ++ freshParams
                                            , srcLambda = Nothing
                                            , lssMember = Nothing
                                            , closureKind = Nothing
                                            , captureAbi = Nothing
                                        }
                                        (MonoCall region body argRefs retTy Mono.defaultCallInfo)
                                        ctyFlat
                                    )
                                    defTyFlat
                                )

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns function type `ty` with its first two stages merged into one, or
`Nothing` when `ty` does not have two stages. The merged stage keeps the outer
arrow's lambda-set annotation; the inner arrow's is dropped.
-}
flattenArrowOnce : Mono.MonoType -> Maybe Mono.MonoType
flattenArrowOnce ty =
    case ty of
        Mono.MFunction _ anno stage1 (Mono.MFunction _ _ stage2 ret) ->
            Just (Mono.mFunction anno (stage1 ++ stage2) ret)

        _ ->
            Nothing


{-| Returns `graph` with the body of every specialization rewritten under
`inlineConfig`, and the counts of what was done.

Each `MonoDefine`, `MonoTailFunc` and port node is rewritten on its own, in
rounds of rewriting and `let` simplification, until a round leaves its body
unchanged (`==`) or `postMonoFixpointIterations` rounds have run. Other nodes
are kept as they are.

With `arityRaise` on, staged specializations are raised first, and then every
lambda-set annotation in the graph is widened to ⊤ (`Mono.widenSets`), because
raising removes closures that annotations elsewhere can still name.

The result's `callEdges` is empty, and so are its `specHasEffects` and
`specValueUsed`. Its `nextLambdaIndex` is past every lambda id given to a
copied closure. Every other field of the graph is passed through.

-}
optimize : Config.InlineConfig -> MonoGraph -> ( MonoGraph, Metrics )
optimize inlineConfig graph =
    let
        (MonoGraph { nodes, main, registry, ctorShapes, nextLambdaIndex, callEdges, ports, flagsDecoder, lssMemberOrigins, lssMemberKinds, lssBlockedMembers }) =
            graph

        ( raisedNodes, raiseCounters ) =
            if inlineConfig.arityRaise then
                let
                    allowSpec =
                        if inlineConfig.raiseAppliedShareMin <= 0 then
                            \_ -> True

                        else
                            raiseAllowedBySites inlineConfig.raiseAppliedShareMin
                                (fnResultSiteCensus nodes)
                in
                raiseStagedSpecs allowSpec nodes

            else
                ( nodes, ( 0, 0 ) )

        rNodes =
            if inlineConfig.arityRaise then
                -- Raising removes inner closures that annotations on other
                -- types can still name as lambda-set members.
                Array.map
                    (Maybe.map (Traverse.mapNodeTypes Mono.widenSets))
                    raisedNodes

            else
                raisedNodes

        callGraph =
            buildCallGraph rNodes callEdges

        ctx =
            initRewriteCtx inlineConfig rNodes registry callGraph nextLambdaIndex

        -- A list, so that the part of the input already folded over can be
        -- freed while the output is built.
        nodesList =
            Array.toList rNodes
    in
    -- A separate function, so that the input array is out of scope while the
    -- nodes are rewritten.
    optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder lssMemberOrigins lssMemberKinds lssBlockedMembers
        |> Tuple.mapSecond
            (\m ->
                { m
                    | arityRaised = Tuple.first raiseCounters
                    , arityRaiseSkipped = Tuple.second raiseCounters
                }
            )


{-| Returns the graph built from `nodesList`, each node rewritten under `ctx`,
and the passed-through fields, with the metrics of the context after the last
node. Node order, and so every `SpecId`, is kept.
-}
optimizeNodes :
    List (Maybe MonoNode)
    -> RewriteCtx
    -> Maybe Mono.MainInfo
    -> Mono.SpecializationRegistry
    -> Mono.LayoutMap (List Mono.CtorShape)
    -> List Mono.PortRegistration
    -> Maybe Mono.SpecId
    -> Dict Int Mono.MemberOrigin
    -> Dict Int String
    -> Dict Int ()
    -> ( MonoGraph, Metrics )
optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder lssMemberOrigins lssMemberKinds lssBlockedMembers =
    let
        ( optimizedNodesList, finalCtx, _ ) =
            List.foldl
                (\maybeNode ( accList, accCtx, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( Nothing :: accList, accCtx, specId + 1 )

                        Just node ->
                            let
                                ( optimizedNode, newCtx ) =
                                    optimizeNode accCtx node
                            in
                            ( Just optimizedNode :: accList, newCtx, specId + 1 )
                )
                ( [], ctx, 0 )
                nodesList

        optimizedNodes =
            Array.fromList (List.reverse optimizedNodesList)

        metrics =
            finalCtx.metrics
    in
    ( MonoGraph
        { nodes = optimizedNodes
        , main = main
        , registry = registry
        , ctorShapes = ctorShapes
        , nextLambdaIndex = finalCtx.lambdaCounter
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = ports
        , flagsDecoder = flagsDecoder
        , lssMemberOrigins = lssMemberOrigins
        , lssMemberKinds = lssMemberKinds
        , lssBlockedMembers = lssBlockedMembers
        }
    , metrics
    )



-- ============================================================================
-- ====== WHITELIST ======
-- ============================================================================


{-| Qualified names, `Module.Path.name`, of functions inlined whatever their
cost. This is a name for `List String`: nothing checks that a name is
well formed or names a function.
-}
type alias InlineWhitelist =
    List String


{-| The built-in whitelist: the functions inlined whatever their cost, as long
as they are not recursive and not blacklisted.

The `Bytes.Encode` and `Bytes.Decode` entries are thin wrappers around
elm/bytes' encoder constructors and decoder primitives, and its small
combinators. The `Utils.Bytes.Encode`, `Utils.Bytes.Decode` and `Mlir.Bytecode`
entries are compositions of those. Inlining them leaves the elm/bytes
primitives themselves at each call site. `Bytes.Encode.encode` and
`Bytes.Decode.decode` are not listed.

A recursive function on the list is never inlined, because no recursive
specialization is an inline candidate.

-}
defaultWhitelist : InlineWhitelist
defaultWhitelist =
    [ -- elm/bytes encoder primitives (constructor wrappers + small helpers)
      "Bytes.Encode.signedInt8"
    , "Bytes.Encode.signedInt16"
    , "Bytes.Encode.signedInt32"
    , "Bytes.Encode.unsignedInt8"
    , "Bytes.Encode.unsignedInt16"
    , "Bytes.Encode.unsignedInt32"
    , "Bytes.Encode.float32"
    , "Bytes.Encode.float64"
    , "Bytes.Encode.bytes"
    , "Bytes.Encode.string"
    , "Bytes.Encode.sequence"
    , "Bytes.Encode.getStringWidth"

    -- elm/bytes decoder primitives + combinators
    , "Bytes.Decode.signedInt8"
    , "Bytes.Decode.signedInt16"
    , "Bytes.Decode.signedInt32"
    , "Bytes.Decode.unsignedInt8"
    , "Bytes.Decode.unsignedInt16"
    , "Bytes.Decode.unsignedInt32"
    , "Bytes.Decode.float32"
    , "Bytes.Decode.float64"
    , "Bytes.Decode.bytes"
    , "Bytes.Decode.string"
    , "Bytes.Decode.succeed"
    , "Bytes.Decode.fail"
    , "Bytes.Decode.map"
    , "Bytes.Decode.map2"
    , "Bytes.Decode.map3"
    , "Bytes.Decode.map4"
    , "Bytes.Decode.map5"
    , "Bytes.Decode.andThen"

    -- Eco-internal encoder helpers
    , "Utils.Bytes.Encode.unit"
    , "Utils.Bytes.Encode.bool"
    , "Utils.Bytes.Encode.int"
    , "Utils.Bytes.Encode.float"
    , "Utils.Bytes.Encode.string"
    , "Utils.Bytes.Encode.maybe"
    , "Utils.Bytes.Encode.result"
    , "Utils.Bytes.Encode.list"
    , "Utils.Bytes.Encode.nonempty"
    , "Utils.Bytes.Encode.stdDict"
    , "Utils.Bytes.Encode.assocListDict"
    , "Utils.Bytes.Encode.everySet"
    , "Utils.Bytes.Encode.jsonPair"
    , "Utils.Bytes.Encode.oneOrMore"

    -- Eco-internal decoder helpers
    , "Utils.Bytes.Decode.unit"
    , "Utils.Bytes.Decode.bool"
    , "Utils.Bytes.Decode.int"
    , "Utils.Bytes.Decode.float"
    , "Utils.Bytes.Decode.string"
    , "Utils.Bytes.Decode.maybe"
    , "Utils.Bytes.Decode.result"
    , "Utils.Bytes.Decode.list"
    , "Utils.Bytes.Decode.nonempty"
    , "Utils.Bytes.Decode.stdDict"
    , "Utils.Bytes.Decode.assocListDict"
    , "Utils.Bytes.Decode.everySet"
    , "Utils.Bytes.Decode.jsonPair"
    , "Utils.Bytes.Decode.oneOrMore"

    -- MLIR bytecode encoder helpers used in the compiler's own .mlir output
    , "Mlir.Bytecode.VarInt.encodeVarInt"
    , "Mlir.Bytecode.VarInt.encodeSignedVarInt"
    , "Mlir.Bytecode.Section.encodeSection"
    ]


{-| Returns a global's qualified name, `Module.name`, or `Nothing` for a record
accessor.
-}
globalToQualifiedName : Mono.Global -> Maybe String
globalToQualifiedName global =
    case global of
        Mono.Global (ModuleName.Canonical _ moduleName) name ->
            Just (moduleName ++ "." ++ name)

        Mono.Accessor _ ->
            Nothing


{-| Returns whether `global`'s qualified name is in `whitelist`. The blacklist
is checked with it too.
-}
isWhitelisted : InlineWhitelist -> Mono.Global -> Bool
isWhitelisted whitelist global =
    case globalToQualifiedName global of
        Just qualifiedName ->
            List.member qualifiedName whitelist

        Nothing ->
            False



-- ============================================================================
-- ====== CALL GRAPH ======
-- ============================================================================


{-| The call edges between specializations, with which of them are recursive.

A specialization is recursive when it lies on a cycle of the edges, a self-edge
included. `isRecursive` holds only the recursive ones, so a missing entry means
not recursive.

-}
type alias CallGraph =
    { edges : Array (Maybe (List SpecId))
    , isRecursive : Dict SpecId Bool
    }


{-| Returns the call graph of `nodes` with `edges` kept as given. Recursion is
decided on the edges between live specializations, those whose node is not
`Nothing`; an edge to any other is ignored.
-}
buildCallGraph : Array (Maybe MonoNode) -> Array (Maybe (List SpecId)) -> CallGraph
buildCallGraph nodes edges =
    let
        specIds : List SpecId
        specIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( specId + 1, specId :: acc )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second
                |> List.reverse

        n : Int
        n =
            List.length specIds

        indexToSpecId : Array SpecId
        indexToSpecId =
            Array.fromList specIds

        idToIndex : Dict SpecId Int
        idToIndex =
            List.foldl
                (\( idx, specId ) acc -> Dict.insert specId idx acc)
                Dict.empty
                (List.indexedMap Tuple.pair specIds)

        buildResult =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just _ ->
                            let
                                idx =
                                    Dict.get specId idToIndex
                                        |> Maybe.withDefault -1

                                neighborSpecIds =
                                    Array.get specId edges
                                        |> Maybe.andThen identity
                                        |> Maybe.withDefault []

                                neighborIdxs =
                                    List.filterMap
                                        (\sid -> Dict.get sid idToIndex)
                                        neighborSpecIds

                                hasSelfLoop =
                                    List.member idx neighborIdxs

                                newFwd =
                                    if idx >= 0 then
                                        Dict.insert idx neighborIdxs acc.fwd

                                    else
                                        acc.fwd

                                newTrans =
                                    List.foldl
                                        (\target t ->
                                            let
                                                existing =
                                                    Dict.get target t |> Maybe.withDefault []
                                            in
                                            Dict.insert target (idx :: existing) t
                                        )
                                        acc.trans
                                        neighborIdxs

                                newSelfLoops =
                                    if hasSelfLoop && idx >= 0 then
                                        BitSet.insert idx acc.selfLoops

                                    else
                                        acc.selfLoops
                            in
                            ( specId + 1, { fwd = newFwd, trans = newTrans, selfLoops = newSelfLoops } )
                )
                ( 0, { fwd = Dict.empty, trans = Dict.empty, selfLoops = BitSet.emptyWithSize n } )
                nodes
                |> Tuple.second

        fwdArray : Array (List Int)
        fwdArray =
            Array.initialize n (\i -> Dict.get i buildResult.fwd |> Maybe.withDefault [])

        transArray : Array (List Int)
        transArray =
            Array.initialize n (\i -> Dict.get i buildResult.trans |> Maybe.withDefault [])

        sccsInt : List (Graph.SCC Int)
        sccsInt =
            Graph.stronglyConnCompInt
                { fwd = fwdArray
                , trans = transArray
                , selfLoops = buildResult.selfLoops
                , size = n
                }

        isRecursiveFromSCC =
            List.foldl
                (\scc acc ->
                    case scc of
                        Graph.AcyclicSCC _ ->
                            acc

                        Graph.CyclicSCC idxs ->
                            List.foldl
                                (\idx innerAcc ->
                                    case Array.get idx indexToSpecId of
                                        Just sid ->
                                            Dict.insert sid True innerAcc

                                        Nothing ->
                                            innerAcc
                                )
                                acc
                                idxs
                )
                Dict.empty
                sccsInt
    in
    { edges = edges
    , isRecursive = isRecursiveFromSCC
    }



-- ============================================================================
-- ====== COST MODEL ======
-- ============================================================================


{-| Returns the sum of `f` over `list`.
-}
sumBy : (a -> Int) -> List a -> Int
sumBy f list =
    List.foldl (\x acc -> acc + f x) 0 list


{-| Returns the size of `expr` in the inliner's cost model, the number the
inline budgets are compared with.

Each node costs a fixed amount plus the cost of its parts: 1 for a variable,
literal, unit, accessor or record access; 2 for a `let`, a destructuring or an
`if`; 3 for a list, tuple, record, record update or case; and 5 for a closure,
call or tail call. A case's decision tree is counted with it. With
`kernelCostClasses` on, a call of a kernel costs what `kernelCallCost` gives
instead of 5 plus 1 for the callee.

-}
computeCost : Config.InlineConfig -> MonoExpr -> Int
computeCost cfg expr =
    case expr of
        MonoLiteral _ _ ->
            1

        MonoVarLocal _ _ ->
            1

        MonoVarGlobal _ _ _ ->
            1

        MonoVarKernel _ _ _ _ _ ->
            1

        MonoUnit ->
            1

        MonoAccessorValue _ _ _ ->
            1

        MonoList _ items _ ->
            3 + sumBy (computeCost cfg) items

        MonoClosure _ body _ ->
            5 + computeCost cfg body

        MonoCall _ ((MonoVarKernel _ prefix home name _) as func) args resultTy _ ->
            -- With the flag off, the same arithmetic as the general arm below.
            if cfg.kernelCostClasses then
                kernelCallCost cfg prefix home name args resultTy
                    + sumBy (computeCost cfg) args

            else
                5 + computeCost cfg func + sumBy (computeCost cfg) args

        MonoCall _ func args _ _ ->
            5 + computeCost cfg func + sumBy (computeCost cfg) args

        MonoTailCall _ args _ ->
            5 + sumBy (\( _, e ) -> computeCost cfg e) args

        MonoIf branches final _ ->
            2 + sumBy (\( c, t ) -> computeCost cfg c + computeCost cfg t) branches + computeCost cfg final

        MonoLet def body _ ->
            2 + computeCostDef cfg def + computeCost cfg body

        MonoDestruct _ inner _ ->
            2 + computeCost cfg inner

        MonoCase _ _ decider branches _ ->
            -- The decision tree's Inline leaves hold branch bodies too.
            3 + computeCostDecider cfg decider + sumBy (\( _, e ) -> computeCost cfg e) branches

        MonoRecordCreate fields _ ->
            3 + sumBy (\( _, e ) -> computeCost cfg e) fields

        MonoRecordAccess inner _ _ ->
            1 + computeCost cfg inner

        MonoRecordUpdate inner updates _ ->
            3 + computeCost cfg inner + sumBy (\( _, e ) -> computeCost cfg e) updates

        MonoTupleCreate _ items _ ->
            3 + sumBy (computeCost cfg) items


{-| Returns the cost of a `let` definition's bound expression.
-}
computeCostDef : Config.InlineConfig -> Mono.MonoDef -> Int
computeCostDef cfg def =
    case def of
        Mono.MonoDef _ bound ->
            computeCost cfg bound

        Mono.MonoTailDef _ _ bound ->
            computeCost cfg bound


{-| Returns the cost of a case's decision tree: 1 for each test node, plus the
cost of each `Inline` leaf. A `Jump` leaf costs nothing here, since its branch
is in the case's jump list.
-}
computeCostDecider : Config.InlineConfig -> Mono.Decider Mono.MonoChoice -> Int
computeCostDecider cfg decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            computeCost cfg e

        Mono.Leaf (Mono.Jump _) ->
            0

        Mono.Chain _ success failure ->
            1 + computeCostDecider cfg success + computeCostDecider cfg failure

        Mono.FanOut _ tests fallback ->
            1
                + sumBy (\( _, d ) -> computeCostDecider cfg d) tests
                + computeCostDecider cfg fallback


{-| Returns the cost of a call of the kernel `prefix`, `home`, `name` with
`args` and result type `resultTy`, not counting the arguments themselves, for
use with `kernelCostClasses` on.

A call that `KernelIntrinsics.kernelIntrinsic` lowers to an inline operation,
given its argument and result types, costs `kernelCostInline`. Otherwise the
kernel's `KernelFacts` cost class decides: `kernelCostGcLeaf`,
`kernelCostAlloc` or `kernelCostHof`, and 6 for an unknown class or a kernel
with no row, which is what every kernel call costs with the flag off.

-}
kernelCallCost : Config.InlineConfig -> Name -> Name -> Name -> List MonoExpr -> Mono.MonoType -> Int
kernelCallCost cfg prefix home name args resultTy =
    case KernelIntrinsics.kernelIntrinsic home name (List.map Mono.typeOf args) resultTy of
        Just _ ->
            cfg.kernelCostInline

        Nothing ->
            let
                -- What any kernel call costs with the flag off: 5 for the call
                -- and 1 for the callee. An unlisted kernel and one of unknown
                -- cost class are equally unknown, so they cost the same.
                unknownCost : Int
                unknownCost =
                    6
            in
            case KernelFacts.lookup ( prefix, home, name ) of
                Nothing ->
                    unknownCost

                Just facts ->
                    case KernelFacts.costClass facts of
                        KernelFacts.CGcLeaf ->
                            cfg.kernelCostGcLeaf

                        KernelFacts.CAlloc ->
                            cfg.kernelCostAlloc

                        KernelFacts.CHof ->
                            cfg.kernelCostHof

                        KernelFacts.CUnknown ->
                            unknownCost



-- ============================================================================
-- ====== REWRITE CONTEXT ======
-- ============================================================================


{-| What the rewrite carries from call to call: the facts computed from the
graph, the settings, the inline budget of the node being rewritten, the
counters for fresh names and lambda ids, and the metrics.

`inlineCandidates` maps each inline candidate to its parameters, its body, and
a pair: whether it is _exact-only_, and the lambda-set member of its closure. An
exact-only candidate is never inlined at a call passing fewer arguments than it
has parameters; such a call keeps the callee's own partial application.
`specArities` maps a specialization to the number of arguments it takes in one
call, and is what application merging and forwarding compare argument counts
with. `loopifiables` holds what `buildLoopifiables` accepted.

`varCounter` numbers the fresh `mono_inline_<n>` names and is never reset
during a run, so no two names it makes are equal. `lambdaCounter` numbers fresh
lambda ids, starting from the graph's `nextLambdaIndex`.
`inlineCountThisFunction` counts the inlines and loopifications made in the
current node, against `maxInlinesPerFunction`.

-}
type alias RewriteCtx =
    { inlineCandidates : Dict Int ( List ( Name, Mono.MonoType ), MonoExpr, ( Bool, Maybe Int ) )
    , specArities : Dict Int Int -- recursive specs included
    , loopifiables : Dict Int LoopifyInfo
    , loopifyEnabled : Bool
    , reshapeCensusOn : Bool -- `report`: fill `clearedMembers`
    , kernelFactsDce : Bool
    , preserveSets : Bool
    , registry : Mono.SpecializationRegistry
    , whitelist : InlineWhitelist
    , maxInlinesPerFunction : Int
    , maxIterations : Int
    , inlineCountThisFunction : Int
    , varCounter : Int
    , lambdaCounter : Int
    , metrics : InternalMetrics
    }


{-| The counts the rewrite context accumulates. It is the same record type as
`Metrics`, field for field, and `optimize` returns it as it is.
-}
type alias InternalMetrics =
    { inlineCount : Int
    , betaReductions : Int
    , betaForwards : Int
    , partialMerges : Int
    , hofLoopified : Int
    , loopifiable : Int
    , letEliminations : Int
    , kernelLetDCE : Int
    , deadLets : Int
    , deadBareKernelVar : Int
    , deadDroppableKernelLets : Int
    , closureDCE : Int
    , arityRaised : Int
    , arityRaiseSkipped : Int
    , inlinedByCallee : Dict String Int
    , declinedPreserveSets : Int
    , declinedArityCap : Int
    , clearedMembers : Dict String Int
    , inlineSourceSites : Dict String Int
    }


{-| Returns `ctx` with `hofLoopified` raised by one.
-}
bumpHofLoopified : RewriteCtx -> RewriteCtx
bumpHofLoopified ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | hofLoopified = m.hofLoopified + 1 } }


{-| Returns `ctx` with `partialMerges` raised by one.
-}
bumpPartialMerges : RewriteCtx -> RewriteCtx
bumpPartialMerges ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | partialMerges = m.partialMerges + 1 } }


{-| Returns `ctx` with `betaReductions` raised by one.
-}
bumpBetaReductions : RewriteCtx -> RewriteCtx
bumpBetaReductions ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | betaReductions = m.betaReductions + 1 } }


{-| Metrics with every count zero and every table empty, for reporting a
build in which `optimize` did not run.
-}
emptyMetrics : Metrics
emptyMetrics =
    { inlineCount = 0
    , betaReductions = 0
    , betaForwards = 0
    , partialMerges = 0
    , hofLoopified = 0
    , loopifiable = 0
    , letEliminations = 0
    , kernelLetDCE = 0
    , deadLets = 0
    , deadBareKernelVar = 0
    , deadDroppableKernelLets = 0
    , closureDCE = 0
    , arityRaised = 0
    , arityRaiseSkipped = 0
    , inlinedByCallee = Dict.empty
    , declinedPreserveSets = 0
    , declinedArityCap = 0
    , clearedMembers = Dict.empty
    , inlineSourceSites = Dict.empty
    }


{-| Returns the number inside a lambda id.
-}
lambdaUid : Mono.LambdaId -> Int
lambdaUid lid =
    case lid of
        Mono.AnonymousLambda _ uid ->
            uid


{-| Returns `ctx` with `declinedPreserveSets` raised by one.
-}
bumpDeclinedPreserveSets : RewriteCtx -> RewriteCtx
bumpDeclinedPreserveSets ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | declinedPreserveSets = m.declinedPreserveSets + 1 } }


{-| Returns `ctx` with `declinedArityCap` raised by one.
-}
bumpDeclinedArityCap : RewriteCtx -> RewriteCtx
bumpDeclinedArityCap ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | declinedArityCap = m.declinedArityCap + 1 } }


{-| Returns whether a closure with `params` and `captures` would have more
parameters plus captured values than `HeapLimits.maxStageArity` allows. Partial
inlining, partial beta reduction and arity raising are declined when it holds.
-}
exceedsStageArity : List a -> List b -> Bool
exceedsStageArity params captures =
    List.length params + List.length captures > HeapLimits.maxStageArity


{-| Returns `ctx0` with one reshape recorded in `clearedMembers` when `report`
is on, and `ctx0` unchanged otherwise. The reshape built a residual closure
with lambda uid `newUid` at `site`, from a closure whose lambda-set member was
`maybeMid`.
-}
bumpClearedMember : Int -> Maybe Int -> String -> RewriteCtx -> RewriteCtx
bumpClearedMember newUid maybeMid site ctx0 =
    if not ctx0.reshapeCensusOn then
        ctx0

    else
        bumpClearedMemberGo newUid maybeMid site ctx0


{-| Returns `ctx0` with `RESHAPES|<site>` raised by one in `clearedMembers`
and, when there is a member, `<newUid>|<member>|<site>` raised by one too.
-}
bumpClearedMemberGo : Int -> Maybe Int -> String -> RewriteCtx -> RewriteCtx
bumpClearedMemberGo newUid maybeMid site ctx0 =
    let
        -- Every reshape is counted, member or not, so that a report can tell
        -- reshapes with no member apart from no reshapes.
        mTot =
            ctx0.metrics

        ctx =
            { ctx0
                | metrics =
                    { mTot
                        | clearedMembers =
                            Dict.update ("RESHAPES|" ++ site)
                                (\v -> Just (1 + Maybe.withDefault 0 v))
                                mTot.clearedMembers
                    }
            }
    in
    case maybeMid of
        Nothing ->
            ctx

        Just mid ->
            let
                m =
                    ctx.metrics

                key =
                    String.fromInt newUid ++ "|" ++ String.fromInt mid ++ "|" ++ site
            in
            { ctx
                | metrics =
                    { m
                        | clearedMembers =
                            Dict.update key (\v -> Just (1 + Maybe.withDefault 0 v)) m.clearedMembers
                    }
            }


{-| Returns `ctx` with `betaForwards` raised by one.
-}
bumpBetaForwards : RewriteCtx -> RewriteCtx
bumpBetaForwards ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | betaForwards = m.betaForwards + 1 } }


{-| Returns `ctx` with one dropped dead binding of `bound` counted: in
`letEliminations` always, and in `kernelLetDCE` too when `bound` is a call
whose callee is a kernel.
-}
bumpKernelDCE : RewriteCtx -> MonoExpr -> RewriteCtx
bumpKernelDCE ctx bound =
    let
        m =
            ctx.metrics

        isKernelCall =
            case bound of
                MonoCall _ (MonoVarKernel _ _ _ _ _) _ _ _ ->
                    True

                _ ->
                    False
    in
    { ctx
        | metrics =
            { m
                | letEliminations = m.letEliminations + 1
                , kernelLetDCE =
                    if isKernelCall then
                        m.kernelLetDCE + 1

                    else
                        m.kernelLetDCE
            }
    }


{-| Returns `ctx` with `closureDCE` raised by one.
-}
bumpClosureDCE : RewriteCtx -> RewriteCtx
bumpClosureDCE ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | closureDCE = m.closureDCE + 1 } }


{-| Returns a region as text, `row:col-row:col`. The specializations of one
source call carry the same region, so they give the same text.
-}
regionKey : A.Region -> String
regionKey (A.Region (A.Position r1 c1) (A.Position r2 c2)) =
    String.fromInt r1 ++ ":" ++ String.fromInt c1 ++ "-" ++ String.fromInt r2 ++ ":" ++ String.fromInt c2


{-| Returns `ctx0` with an inline of `specId` recorded as `recordInline`
records it, and also counted in `inlineSourceSites` under the callee's name
and `region`.
-}
recordInlineAt : A.Region -> SpecId -> RewriteCtx -> RewriteCtx
recordInlineAt region specId ctx0 =
    let
        ctx =
            recordInline specId ctx0

        m =
            ctx.metrics

        calleeKey =
            Array.get specId ctx.registry.reverseMapping
                |> Maybe.andThen identity
                |> Maybe.andThen (\( g, _ ) -> globalToQualifiedName g)
                |> Maybe.withDefault ("spec:" ++ String.fromInt specId)
    in
    { ctx
        | metrics =
            { m
                | inlineSourceSites =
                    Dict.update (calleeKey ++ "|" ++ regionKey region)
                        (\v -> Just (1 + Maybe.withDefault 0 v))
                        m.inlineSourceSites
            }
    }


{-| Returns `ctx` with an inline of `specId` counted: in `inlineCount`, in
`inlinedByCallee` under the callee's qualified name (`spec:<id>` when the
registry gives none), and against the current node's inline budget.
-}
recordInline : SpecId -> RewriteCtx -> RewriteCtx
recordInline specId ctx =
    let
        m =
            ctx.metrics

        calleeKey =
            Array.get specId ctx.registry.reverseMapping
                |> Maybe.andThen identity
                |> Maybe.andThen (\( g, _ ) -> globalToQualifiedName g)
                |> Maybe.withDefault ("spec:" ++ String.fromInt specId)
    in
    { ctx
        | metrics =
            { m
                | inlineCount = m.inlineCount + 1
                , inlinedByCallee =
                    Dict.insert calleeKey
                        (1 + Maybe.withDefault 0 (Dict.get calleeKey m.inlinedByCallee))
                        m.inlinedByCallee
            }
        , inlineCountThisFunction = ctx.inlineCountThisFunction + 1
    }


{-| Returns whether some parameter of function type is the callee of a call in
`body`. A function for which this holds gets the wider `hofThreshold` budget,
since inlining it lets a lambda passed for that parameter be beta-reduced at
the call site. A function parameter that is only stored or passed on does not
count.

Names are compared without regard to scope, so a call of another local of the
same name counts too. Elm forbids shadowing.

-}
hasCalledFunctionParam : List ( Name, Mono.MonoType ) -> MonoExpr -> Bool
hasCalledFunctionParam params body =
    let
        funcParams =
            List.filterMap
                (\( n, pt ) ->
                    case pt of
                        Mono.MFunction _ _ _ _ ->
                            Just n

                        _ ->
                            Nothing
                )
                params
    in
    not (List.isEmpty funcParams)
        && Traverse.foldExpr
            (\e acc ->
                acc
                    || (case e of
                            MonoCall _ (MonoVarLocal n _) _ _ _ ->
                                List.member n funcParams

                            _ ->
                                False
                       )
            )
            False
            body



-- ============================================================================
-- ====== RECURSIVE-HOF LOOPIFICATION ======
-- ============================================================================


{-| A tail-recursive specialization that loopification can copy, with the
function parameters it can eliminate.

`params` and `body` are the specialization's own. `flatParams` maps the
position of each eliminable parameter to its flat arity (`flatArrowArity`). A
function parameter is eliminable when the body only calls it, once, with its
full flat arity, and otherwise only passes it on unchanged as the same
parameter of its own tail calls (`paramLoopifiable`).

_Loopification_ rewrites a call of such a specialization that passes a lambda
literal for an eliminable parameter. The call becomes a local tail-recursive
definition (`MonoTailDef`), a copy of the body without that parameter in which
the one call of the parameter calls the literal instead, applied to the other
arguments. A later round, if one runs, beta-reduces the literal.

-}
type alias LoopifyInfo =
    { params : List ( Name, Mono.MonoType )
    , body : MonoExpr
    , flatParams : Dict Int Int
    }


{-| Returns the specializations of `nodes` that loopification can copy, keyed
by `SpecId`, or none when `loopify` is off.

A `MonoTailFunc` qualifies when its body costs at most twice the larger of
`postMonoThreshold` and `hofThreshold`, does not name its own specialization
(`referencesSpec`), and has at least one eliminable function parameter.

-}
buildLoopifiables : Config.InlineConfig -> Array (Maybe MonoNode) -> Dict Int LoopifyInfo
buildLoopifiables inlineConfig nodes =
    if not inlineConfig.loopify then
        Dict.empty

    else
        let
            -- Loopification copies the body into each call site, as inlining
            -- does, with twice the larger inline budget.
            budget =
                2 * max inlineConfig.postMonoThreshold inlineConfig.hofThreshold
        in
        Array.foldl
            (\maybeNode ( acc, specId ) ->
                case maybeNode of
                    Just (MonoTailFunc params body _) ->
                        if computeCost inlineConfig body > budget || referencesSpec specId body then
                            ( acc, specId + 1 )

                        else
                            let
                                flatParams =
                                    params
                                        |> List.indexedMap Tuple.pair
                                        |> List.filterMap
                                            (\( i, ( pName, pType ) ) ->
                                                case pType of
                                                    Mono.MFunction _ _ _ _ ->
                                                        let
                                                            arity =
                                                                flatArrowArity pType
                                                        in
                                                        if paramLoopifiable pName arity body then
                                                            Just ( i, arity )

                                                        else
                                                            Nothing

                                                    _ ->
                                                        Nothing
                                            )
                                        |> Dict.fromList
                            in
                            if Dict.isEmpty flatParams then
                                ( acc, specId + 1 )

                            else
                                ( Dict.insert specId (LoopifyInfo params body flatParams) acc, specId + 1 )

                    _ ->
                        ( acc, specId + 1 )
            )
            ( Dict.empty, 0 )
            nodes
            |> Tuple.first


{-| Returns how many arguments a function type takes over all its stages: 2
for both `MFunction [a, b] r` and `MFunction [a] (MFunction [b] r)`, and 0 for
a type that is not a function.
-}
flatArrowArity : Mono.MonoType -> Int
flatArrowArity t =
    case t of
        Mono.MFunction _ _ argTys ret ->
            List.length argTys + flatArrowArity ret

        _ ->
            0


{-| Returns whether `body` names specialization `specId` anywhere. A copy of
such a body would call back into the original function.
-}
referencesSpec : Int -> MonoExpr -> Bool
referencesSpec specId body =
    Traverse.foldExpr
        (\e acc ->
            acc
                || (case e of
                        MonoVarGlobal _ sid _ ->
                            sid == specId

                        _ ->
                            False
                   )
        )
        False
        body


{-| Returns whether parameter `p`, a function taking `arity` arguments over all
its stages, can be eliminated from `body`.

It can when `p` is never rebound (by a `let`, a destructuring, or a closure or
tail definition parameter), is not used inside any closure or any local tail
function's body, is the callee of exactly one call passing `arity` arguments,
and is otherwise used only as the value `p` of the entry `p` of a tail call.

The last condition is checked by counting: every use of `p` that
`countUsages` finds must be that one call or one such tail-call entry.

-}
paramLoopifiable : Name -> Int -> MonoExpr -> Bool
paramLoopifiable p arity body =
    let
        totalUses =
            countUsages p body

        rebinds =
            Traverse.foldExpr
                (\e acc ->
                    acc
                        || (case e of
                                MonoLet def _ _ ->
                                    getDefName def
                                        == p
                                        || (case def of
                                                Mono.MonoTailDef _ ps _ ->
                                                    List.any (\( n, _ ) -> n == p) ps

                                                _ ->
                                                    False
                                           )

                                MonoClosure info _ _ ->
                                    List.any (\( n, _ ) -> n == p) info.params

                                MonoDestruct (Mono.MonoDestructor dn _ _) _ _ ->
                                    dn == p

                                _ ->
                                    False
                           )
                )
                False
                body

        usesInsideClosures =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoClosure info b _ ->
                            acc
                                + List.foldl (\( _, ce, _ ) n -> n + countUsages p ce) 0 info.captures
                                + countUsages p b

                        _ ->
                            acc
                )
                0
                body

        usesInsideInnerTailDefs =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoLet (Mono.MonoTailDef _ _ b) _ _ ->
                            acc + countUsages p b

                        _ ->
                            acc
                )
                0
                body

        calleeSites =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoCall _ (MonoVarLocal n _) args _ _ ->
                            if n == p && List.length args == arity then
                                acc + 1

                            else
                                acc

                        _ ->
                            acc
                )
                0
                body

        threadEntries =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoTailCall _ entries _ ->
                            acc
                                + List.length
                                    (List.filter
                                        (\( an, ae ) ->
                                            an
                                                == p
                                                && (case ae of
                                                        MonoVarLocal n _ ->
                                                            n == p

                                                        _ ->
                                                            False
                                                   )
                                        )
                                        entries
                                    )

                        _ ->
                            acc
                )
                0
                body
    in
    not rebinds
        && usesInsideClosures
        == 0
        && usesInsideInnerTailDefs
        == 0
        && calleeSites
        == 1
        && totalUses
        == calleeSites
        + threadEntries


{-| Returns the loopified form of the call of `specId` with `args`, or
`Nothing` when the call does not qualify.

It does not when loopification is off, the current node's inline budget is
spent, `specId` is not loopifiable, `args` does not match its parameters in
number, or no eliminable position holds a closure literal whose parameter count
is that position's flat arity and whose captures are all local variables. A
loopification counts against the node's inline budget.

-}
tryLoopify : RewriteCtx -> Region -> Int -> List MonoExpr -> Mono.MonoType -> Maybe ( MonoExpr, RewriteCtx )
tryLoopify ctx region specId args resultType =
    if not ctx.loopifyEnabled || ctx.inlineCountThisFunction >= ctx.maxInlinesPerFunction then
        Nothing

    else
        case Dict.get specId ctx.loopifiables of
            Nothing ->
                Nothing

            Just info ->
                if List.length args /= List.length info.params then
                    Nothing

                else
                    let
                        qualifying =
                            args
                                |> List.indexedMap Tuple.pair
                                |> List.filterMap
                                    (\( i, arg ) ->
                                        case ( Dict.get i info.flatParams, arg ) of
                                            ( Just lamArity, MonoClosure cinfo cbody ctype ) ->
                                                if
                                                    List.length cinfo.params
                                                        == lamArity
                                                        && List.all
                                                            (\( _, ce, _ ) ->
                                                                case ce of
                                                                    MonoVarLocal _ _ ->
                                                                        True

                                                                    _ ->
                                                                        False
                                                            )
                                                            cinfo.captures
                                                then
                                                    Just ( i, MonoClosure cinfo cbody ctype )

                                                else
                                                    Nothing

                                            _ ->
                                                Nothing
                                    )
                    in
                    if List.isEmpty qualifying then
                        Nothing

                    else
                        Just (loopifyCall ctx region info qualifying args resultType)


{-| Returns the call of `info`'s specialization with `args` loopified: a local
tail definition, a copy of the specialization without the `qualifying`
parameters, applied to the other arguments, under `let`s binding the values the
qualifying literals capture.

The copy gets fresh lambda ids, fresh `let` names and a fresh name for every
parameter. Each qualifying literal captures fresh names instead of its own, and
replaces the callee of the one call of its parameter.

-}
loopifyCall : RewriteCtx -> Region -> LoopifyInfo -> List ( Int, MonoExpr ) -> List MonoExpr -> Mono.MonoType -> ( MonoExpr, RewriteCtx )
loopifyCall ctx region info qualifying args resultType =
    let
        qualifyingIdxs =
            List.map Tuple.first qualifying

        ( sF, ctx1 ) =
            freshVar ctx

        -- Fresh names for every spec param: the copied body enters the
        -- caller's scope, where its names could collide with the caller's.
        ( renamesRev, ctx2 ) =
            List.foldl
                (\( old, _ ) ( acc, c ) ->
                    let
                        ( fresh, c1 ) =
                            freshVar c
                    in
                    ( ( old, fresh ) :: acc, c1 )
                )
                ( [], ctx1 )
                info.params

        renames =
            List.reverse renamesRev

        renameOf old =
            List.filterMap
                (\( o, n ) ->
                    if o == old then
                        Just n

                    else
                        Nothing
                )
                renames
                |> List.head
                |> Maybe.withDefault old

        -- Each capture of a literal is renamed to a fresh name, bound to the
        -- captured value in a `let` outside the loop. Keeping the caller's
        -- name would not do: the copied body's binders come from another
        -- function and could rebind it inside the loop.
        ( lambdaPairs, preludeRev, ctxCaps ) =
            List.foldl
                (\( i, lamExpr ) ( accPairs, accPrelude, c ) ->
                    case lamExpr of
                        MonoClosure cinfo cbody ctype ->
                            let
                                ( ( cbody1, capsRev ), accPrelude1, c1 ) =
                                    List.foldl
                                        (\(( capName, capExpr, unboxed ) as cap) ( ( e, caps ), pre, cc ) ->
                                            case capExpr of
                                                MonoVarLocal _ vt ->
                                                    let
                                                        ( freshCap, cc1 ) =
                                                            freshVar cc
                                                    in
                                                    ( ( substitute capName freshCap vt e
                                                      , ( freshCap, MonoVarLocal freshCap vt, unboxed ) :: caps
                                                      )
                                                    , ( freshCap, capExpr ) :: pre
                                                    , cc1
                                                    )

                                                _ ->
                                                    ( ( e, cap :: caps ), pre, cc )
                                        )
                                        ( ( cbody, [] ), accPrelude, c )
                                        cinfo.captures
                            in
                            -- The literal captures the fresh names, so it stays well
                            -- scoped if the round limit is reached before it is reduced.
                            ( ( i, MonoClosure { cinfo | captures = List.reverse capsRev } cbody1 ctype ) :: accPairs
                            , accPrelude1
                            , c1
                            )

                        _ ->
                            ( ( i, lamExpr ) :: accPairs, accPrelude, c )
                )
                ( [], [], ctx2 )
                qualifying

        lambdasByOldName =
            lambdaPairs
                |> List.filterMap
                    (\( i, lam ) ->
                        info.params
                            |> List.indexedMap Tuple.pair
                            |> List.filterMap
                                (\( j, ( pn, _ ) ) ->
                                    if j == i then
                                        Just pn

                                    else
                                        Nothing
                                )
                            |> List.head
                            |> Maybe.map (\pn -> ( renameOf pn, lam ))
                    )
                |> Dict.fromList

        flatOldNames =
            info.params
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, ( pn, _ ) ) ->
                        if List.member j qualifyingIdxs then
                            Just pn

                        else
                            Nothing
                    )

        -- Copy the spec body: fresh lambda ids, fresh internal lets, then
        -- rename every param reference (variables only; tail-call entry
        -- names and callees are handled by loopifyBody).
        ( bodyA, ctx3 ) =
            remapLambdaIds ctxCaps info.body

        ( bodyB, ctx4 ) =
            freshenLetBoundNames ctx3 bodyA

        bodyC =
            List.foldl
                (\( ( old, pt ), ( _, fresh ) ) e -> substitute old fresh pt e)
                bodyB
                (List.map2 Tuple.pair info.params renames)

        bodyD =
            loopifyBody sF renames flatOldNames lambdasByOldName [] bodyC

        newParams =
            info.params
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, ( pn, pt ) ) ->
                        if List.member j qualifyingIdxs then
                            Nothing

                        else
                            Just ( renameOf pn, pt )
                    )

        remainingArgs =
            args
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, a ) ->
                        if List.member j qualifyingIdxs then
                            Nothing

                        else
                            Just a
                    )

        loopFnType =
            Mono.mFunction Mono.topSynth (List.map Tuple.second newParams) resultType

        invocation =
            MonoCall region (MonoVarLocal sF loopFnType) remainingArgs resultType Mono.defaultCallInfo

        result =
            List.foldl
                (\( freshCap, capExpr ) acc ->
                    MonoLet (Mono.MonoDef freshCap capExpr) acc resultType
                )
                (MonoLet (Mono.MonoTailDef sF newParams bodyD) invocation resultType)
                preludeRev

        ctx5 =
            bumpHofLoopified { ctx4 | inlineCountThisFunction = ctx4.inlineCountThisFunction + 1 }
    in
    ( result, ctx5 )


{-| Returns the copied body `expr` with each tail call to the original
function retargeted to the local loop `sF`, and each call of an eliminated
parameter calling its literal instead.

A tail call whose callee is not in `innerNames`, the local tail functions
entered so far, is a call of the original function. Its entries are renamed by
`renames`, and the entries of the eliminated parameters, `flatOldNames`, are
dropped. A call whose callee is a local named in `lambdas` gets that literal as
callee. Closures are not entered: the eliminated parameters do not occur in
them.

-}
loopifyBody : Name -> List ( Name, Name ) -> List Name -> Dict Name MonoExpr -> List Name -> MonoExpr -> MonoExpr
loopifyBody sF renames flatOldNames lambdas innerNames expr =
    let
        go =
            loopifyBody sF renames flatOldNames lambdas innerNames

        renameOf old =
            List.filterMap
                (\( o, n ) ->
                    if o == old then
                        Just n

                    else
                        Nothing
                )
                renames
                |> List.head
                |> Maybe.withDefault old
    in
    case expr of
        MonoTailCall callee entries t ->
            if List.member callee innerNames then
                MonoTailCall callee (List.map (\( an, ae ) -> ( an, go ae )) entries) t

            else
                MonoTailCall sF
                    (entries
                        |> List.filterMap
                            (\( an, ae ) ->
                                if List.member an flatOldNames then
                                    Nothing

                                else
                                    Just ( renameOf an, go ae )
                            )
                    )
                    t

        MonoCall r ((MonoVarLocal n _) as callee) cargs t ci ->
            case Dict.get n lambdas of
                Just lam ->
                    MonoCall r lam (List.map go cargs) t ci

                Nothing ->
                    MonoCall r callee (List.map go cargs) t ci

        MonoCall r f cargs t ci ->
            MonoCall r (go f) (List.map go cargs) t ci

        MonoClosure _ _ _ ->
            expr

        MonoLet (Mono.MonoTailDef tn tps tb) b t ->
            let
                inner1 =
                    tn :: innerNames
            in
            MonoLet (Mono.MonoTailDef tn tps (loopifyBody sF renames flatOldNames lambdas inner1 tb))
                (loopifyBody sF renames flatOldNames lambdas inner1 b)
                t

        MonoLet (Mono.MonoDef dn db) b t ->
            MonoLet (Mono.MonoDef dn (go db)) (go b) t

        MonoIf branches final t ->
            MonoIf (List.map (\( c, th ) -> ( go c, go th )) branches) (go final) t

        MonoDestruct d inner t ->
            MonoDestruct d (go inner) t

        MonoCase s r0 decider branches t ->
            MonoCase s r0 (loopifyDecider sF renames flatOldNames lambdas innerNames decider) (List.map (\( i, e ) -> ( i, go e )) branches) t

        MonoList r items t ->
            MonoList r (List.map go items) t

        MonoRecordCreate fields t ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, go e )) fields) t

        MonoRecordAccess inner f t ->
            MonoRecordAccess (go inner) f t

        MonoRecordUpdate inner updates t ->
            MonoRecordUpdate (go inner) (List.map (\( n, e ) -> ( n, go e )) updates) t

        MonoTupleCreate r items t ->
            MonoTupleCreate r (List.map go items) t

        MonoLiteral _ _ ->
            expr

        MonoVarLocal _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr


{-| Returns a decision tree with `loopifyBody` applied to every `Inline` leaf.
-}
loopifyDecider : Name -> List ( Name, Name ) -> List Name -> Dict Name MonoExpr -> List Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
loopifyDecider sF renames flatOldNames lambdas innerNames decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (loopifyBody sF renames flatOldNames lambdas innerNames e))

        Mono.Leaf (Mono.Jump _) ->
            decider

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (loopifyDecider sF renames flatOldNames lambdas innerNames success)
                (loopifyDecider sF renames flatOldNames lambdas innerNames failure)

        Mono.FanOut path tests fallback ->
            Mono.FanOut path
                (List.map (\( k, d ) -> ( k, loopifyDecider sF renames flatOldNames lambdas innerNames d )) tests)
                (loopifyDecider sF renames flatOldNames lambdas innerNames fallback)


{-| Returns the context to start rewriting `nodes` with: the inline
candidates, spec arities and loopifiable specializations computed once from
`nodes`, the settings of `inlineConfig`, zeroed counts, and lambda ids
numbered from `nextLambdaIndex`.

A specialization is an inline candidate when it is not recursive, its node is
a `MonoDefine`, it is not blacklisted, and its body costs at most
`postMonoThreshold`, or it is whitelisted, or it is _hof-admitted_: it costs
more than `postMonoThreshold` but no more than the larger of that and
`hofThreshold`, and calls one of its function parameters. A candidate over
`postMonoThreshold` and not whitelisted is exact-only, unless it is
hof-admitted and `partialHof` is on. The whitelist is `defaultWhitelist` and
the configured names, less the blacklisted ones.

-}
initRewriteCtx : Config.InlineConfig -> Array (Maybe MonoNode) -> Mono.SpecializationRegistry -> CallGraph -> Int -> RewriteCtx
initRewriteCtx inlineConfig nodes registry callGraph nextLambdaIndex =
    let
        -- Effective whitelist: built-in defaults plus config additions, minus
        -- the config blacklist (see Compiler.Eco.Config.InlineConfig).
        effectiveWhitelist =
            List.filter
                (\name -> not (List.member name inlineConfig.blacklist))
                (defaultWhitelist ++ inlineConfig.whitelist)

        -- The budget of a candidate that calls a function parameter. `max`,
        -- so that it is never below the general budget.
        hofBudget =
            max inlineConfig.postMonoThreshold inlineConfig.hofThreshold

        candidates =
            Array.foldl
                (\maybeNode ( accDict, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( accDict, specId + 1 )

                        Just node ->
                            let
                                isRecursive =
                                    Dict.get specId callGraph.isRecursive
                                        |> Maybe.withDefault False
                            in
                            if isRecursive then
                                ( accDict, specId + 1 )

                            else
                                case getInlinableBody node of
                                    Nothing ->
                                        ( accDict, specId + 1 )

                                    Just ( params, body, calleeMember ) ->
                                        let
                                            cost =
                                                computeCost inlineConfig body

                                            maybeGlobal =
                                                Array.get specId registry.reverseMapping
                                                    |> Maybe.andThen identity
                                                    |> Maybe.map (\( g, _ ) -> g)

                                            whitelisted =
                                                maybeGlobal
                                                    |> Maybe.map (isWhitelisted effectiveWhitelist)
                                                    |> Maybe.withDefault False

                                            -- A blacklisted global is no
                                            -- candidate at all, not merely
                                            -- off the whitelist.
                                            blacklisted =
                                                maybeGlobal
                                                    |> Maybe.map (isWhitelisted inlineConfig.blacklist)
                                                    |> Maybe.withDefault False

                                            -- Admitted only by the hof
                                            -- budget. Ordered so that the
                                            -- body scan runs only for a
                                            -- candidate over the general
                                            -- budget.
                                            hofAdmitted =
                                                cost
                                                    > inlineConfig.postMonoThreshold
                                                    && cost
                                                    <= hofBudget
                                                    && hasCalledFunctionParam params body

                                            withinBudget =
                                                cost <= inlineConfig.postMonoThreshold || hofAdmitted

                                            exactOnly =
                                                cost
                                                    > inlineConfig.postMonoThreshold
                                                    && not whitelisted
                                                    && not (inlineConfig.partialHof && hofAdmitted)
                                        in
                                        if blacklisted || (not withinBudget && not whitelisted) then
                                            ( accDict, specId + 1 )

                                        else
                                            ( Dict.insert specId ( params, body, ( exactOnly, calleeMember ) ) accDict, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first

        specArities =
            Array.foldl
                (\maybeNode ( acc, specId ) ->
                    case maybeNode of
                        Just (MonoDefine (MonoClosure info _ _) _) ->
                            ( Dict.insert specId (List.length info.params) acc, specId + 1 )

                        Just (MonoTailFunc params _ _) ->
                            ( Dict.insert specId (List.length params) acc, specId + 1 )

                        -- A kernel alias (`and = Elm.Kernel.Bitwise.and`) or a
                        -- global alias (`userAnd = Bitwise.and`) has no closure
                        -- literal. Its arity is the kernel's flat arity, or the
                        -- arity of the global it names, followed at most 4 links.
                        Just (MonoDefine (MonoVarKernel _ _ _ _ kernelType) _) ->
                            let
                                n =
                                    flatArrowArity kernelType
                            in
                            if n > 0 then
                                ( Dict.insert specId n acc, specId + 1 )

                            else
                                ( acc, specId + 1 )

                        Just (MonoDefine (MonoVarGlobal _ target _) _) ->
                            case aliasArity nodes 4 target of
                                Just n ->
                                    ( Dict.insert specId n acc, specId + 1 )

                                Nothing ->
                                    ( acc, specId + 1 )

                        _ ->
                            ( acc, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first

        loopifiables =
            buildLoopifiables inlineConfig nodes
    in
    { inlineCandidates = candidates
    , specArities = specArities
    , loopifiables = loopifiables
    , loopifyEnabled = inlineConfig.loopify
    , reshapeCensusOn = inlineConfig.report
    , kernelFactsDce = inlineConfig.kernelFactsDce
    , preserveSets = inlineConfig.preserveSets
    , registry = registry
    , whitelist = effectiveWhitelist
    , maxInlinesPerFunction = inlineConfig.maxPerFunction
    , maxIterations = inlineConfig.postMonoFixpointIterations
    , inlineCountThisFunction = 0
    , varCounter = 0
    , lambdaCounter = nextLambdaIndex
    , metrics =
        { inlineCount = 0
        , betaReductions = 0
        , betaForwards = 0
        , partialMerges = 0
        , hofLoopified = 0
        , loopifiable = Dict.size loopifiables
        , letEliminations = 0
        , kernelLetDCE = 0
        , deadLets = 0
        , deadBareKernelVar = 0
        , deadDroppableKernelLets = 0
        , closureDCE = 0

        -- Overwritten by `optimize` from the raise pre-pass counters.
        , arityRaised = 0
        , arityRaiseSkipped = 0
        , inlinedByCallee = Dict.empty
        , declinedPreserveSets = 0
        , declinedArityCap = 0
        , clearedMembers = Dict.empty
        , inlineSourceSites = Dict.empty
        }
    }


{-| Returns a fresh local name, `mono_inline_<n>`, and the context with the
counter advanced.
-}
freshVar : RewriteCtx -> ( Name, RewriteCtx )
freshVar ctx =
    ( "mono_inline_" ++ String.fromInt ctx.varCounter
    , { ctx | varCounter = ctx.varCounter + 1 }
    )


{-| Returns a fresh anonymous lambda id in module `home`, and the context with
the counter advanced.
-}
freshLambdaId : RewriteCtx -> ModuleName.Canonical -> ( Mono.LambdaId, RewriteCtx )
freshLambdaId ctx home =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )


{-| Returns a fresh lambda id in the home module of specialization `specId`,
or in a module with empty names when it has none: a record accessor, or a
specialization the registry does not know.
-}
freshLambdaIdForSpec : RewriteCtx -> Mono.SpecId -> ( Mono.LambdaId, RewriteCtx )
freshLambdaIdForSpec ctx specId =
    let
        home =
            case Array.get specId ctx.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global h _, _ ) ->
                    h

                Just ( Mono.Accessor _, _ ) ->
                    ModuleName.Canonical ( "", "" ) ""

                Nothing ->
                    ModuleName.Canonical ( "", "" ) ""
    in
    freshLambdaId ctx home


{-| Returns `expr` with a fresh lambda id in the same module when it is a
closure, and `Nothing` for any other expression.
-}
remapClosureLambdaId : RewriteCtx -> MonoExpr -> ( Maybe MonoExpr, RewriteCtx )
remapClosureLambdaId ctx expr =
    case expr of
        MonoClosure info body closureType ->
            let
                home =
                    case info.lambdaId of
                        Mono.AnonymousLambda h _ ->
                            h

                ( newLambdaId, ctx1 ) =
                    freshLambdaId ctx home

                newInfo =
                    { info | lambdaId = newLambdaId }
            in
            ( Just (MonoClosure newInfo body closureType), ctx1 )

        _ ->
            ( Nothing, ctx )


{-| Returns `expr` with every closure in it given a fresh lambda id. Every
copy of a body gets this, so that no lambda id is used by two closures.
-}
remapLambdaIds : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
remapLambdaIds ctx expr =
    -- Written with its parameters: written point-free, every call of it would
    -- build a partial application instead of making a saturated call.
    Traverse.traverseExpr remapClosureLambdaId ctx expr


{-| A parameter bound to an argument by beta reduction or inlining: the
parameter's name, the fresh name that replaces it, and the argument with its
type.
-}
type alias Binding =
    { origName : Name
    , freshName : Name
    , arg : MonoExpr
    , argType : Mono.MonoType
    }



-- ============================================================================
-- ====== NODE OPTIMIZATION ======
-- ============================================================================


{-| Returns `node` with its body rewritten to a fixpoint (`fixpoint`), and the
context. The inline budget starts again at zero for each node. A node with no
body to rewrite is returned as it is.
-}
optimizeNode : RewriteCtx -> MonoNode -> ( MonoNode, RewriteCtx )
optimizeNode ctx node =
    let
        ctxForNode =
            { ctx | inlineCountThisFunction = 0 }
    in
    case node of
        MonoDefine expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoDefine optimized tipe, newCtx )

        MonoTailFunc params expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoTailFunc params optimized tipe, newCtx )

        MonoPortIncoming expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortIncoming optimized tipe, newCtx )

        MonoPortOutgoing expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortOutgoing optimized tipe, newCtx )

        -- MonoCtor, MonoEnum, MonoExtern, MonoManagerLeaf pass through unchanged
        _ ->
            ( node, ctx )



-- ============================================================================
-- ====== FIXPOINT LOOP ======
-- ============================================================================


{-| Returns `expr` after rounds of `rewriteExpr` followed by `simplifyLets`,
stopping after the first round that leaves it unchanged, or after
`maxIterations` rounds.
-}
fixpoint : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
fixpoint ctx expr =
    iterate 0 expr ctx


{-| Returns the result of round `n` and the rounds after it, as `fixpoint`
describes; `current` is the expression before round `n`.
-}
iterate : Int -> MonoExpr -> RewriteCtx -> ( MonoExpr, RewriteCtx )
iterate n current ctx =
    if n >= ctx.maxIterations then
        ( current, ctx )

    else
        let
            ( rewritten, ctx1 ) =
                rewriteExpr ctx current

            ( simplified, ctx2 ) =
                simplifyLets ctx1 rewritten
        in
        if exprEqual simplified current then
            ( simplified, ctx2 )

        else
            iterate (n + 1) simplified ctx2


{-| Returns whether two expressions are equal under Elm's structural `==`.
-}
exprEqual : MonoExpr -> MonoExpr -> Bool
exprEqual e1 e2 =
    e1 == e2



-- ============================================================================
-- ====== EXPRESSION REWRITING ======
-- ============================================================================


{-| Returns `expr` rewritten once, with the context. An inlined call, a merged
call and a call whose callee's `let`s were moved out are rewritten again; a
beta-reduced or loopified call is not.

A call is rewritten according to its callee:

  - A closure literal is beta-reduced (`betaReduce`). A call passing some but
    not all of its parameters is left as it is when `preserveSets` is on, or
    when the closure's parameters plus captures exceed
    `HeapLimits.maxStageArity`.
  - A global is loopified when `tryLoopify` accepts the call, and otherwise
    inlined when `tryInlineCall` does.
  - A call `(f a) b` is merged into `f a b` when `calleeArity` knows `f`'s
    arity and the total number of arguments does not exceed it. The merged
    call has a default `CallInfo`.
  - A `let` chain has its definitions moved out: `(let d in f) a` becomes
    `let d in f a`.

An `if` with one condition that is the literal `True` or `False` is replaced by
the branch it chooses. A `let` chain is rewritten as a whole
(`rewriteLetChain`). A tail call is never inlined. Anything else has its parts
rewritten.

-}
rewriteExpr : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteExpr ctx expr =
    case expr of
        MonoCall region ((MonoClosure info closureBody _) as closureExpr) args resultType callInfo ->
            if ctx.preserveSets && not (List.isEmpty args) && List.length args < List.length info.params then
                -- Declined here, not inside `betaReduce`, because `betaReduce`
                -- has neither the closure's type nor the call's CallInfo to
                -- rebuild the call with. Its other callers never pass fewer
                -- arguments than params.
                let
                    ( rewrittenFunc, ctx1 ) =
                        rewriteExpr (bumpDeclinedPreserveSets ctx) closureExpr

                    ( rewrittenArgs, ctx2 ) =
                        rewriteExprs ctx1 args
                in
                ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

            else if
                not (List.isEmpty args)
                    && (List.length args < List.length info.params)
                    && exceedsStageArity info.params info.captures
            then
                -- The residual closure has the remaining params and at most
                -- one capture per bound argument on top of the original ones,
                -- so the original closure's count bounds it.
                let
                    ( rewrittenFunc, ctx1 ) =
                        rewriteExpr (bumpDeclinedArityCap ctx) closureExpr

                    ( rewrittenArgs, ctx2 ) =
                        rewriteExprs ctx1 args
                in
                ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

            else
                betaReduce ctx region info closureBody args resultType

        MonoCall region (MonoVarGlobal varRegion specId funcType) args resultType callInfo ->
            -- Loopification first. Tail functions are never inline
            -- candidates, so the two cannot both apply. The loopified call is
            -- returned as it is; a later round, if one runs, reduces the
            -- literal in it.
            case tryLoopify ctx region specId args resultType of
                Just ( loopified, ctxL ) ->
                    ( loopified, ctxL )

                Nothing ->
                    let
                        ( maybeInlined, ctx1 ) =
                            tryInlineCall region ctx specId args resultType
                    in
                    case maybeInlined of
                        Just inlinedExpr ->
                            rewriteExpr ctx1 inlinedExpr

                        Nothing ->
                            let
                                ( rewrittenArgs, ctx2 ) =
                                    rewriteExprs ctx1 args
                            in
                            ( MonoCall region (MonoVarGlobal varRegion specId funcType) rewrittenArgs resultType callInfo, ctx2 )

        -- Application merging: `(f a1s) a2s` becomes `f (a1s ++ a2s)`. A
        -- partial inner application runs no code, so evaluation order is kept.
        MonoCall region ((MonoCall _ innerFunc innerArgs _ _) as innerCall) outerArgs resultType callInfo ->
            let
                mergeable =
                    case calleeArity ctx innerFunc of
                        Just arity ->
                            List.length innerArgs + List.length outerArgs <= arity

                        Nothing ->
                            False
            in
            if mergeable then
                rewriteExpr (bumpPartialMerges ctx)
                    (MonoCall region innerFunc (innerArgs ++ outerArgs) resultType Mono.defaultCallInfo)

            else
                let
                    ( rewrittenFunc, ctx1 ) =
                        rewriteExpr ctx innerCall

                    ( rewrittenArgs, ctx2 ) =
                        rewriteExprs ctx1 outerArgs
                in
                ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

        -- Let-callee hoisting: `(let d in f) a` becomes `let d in (f a)`, so
        -- that a closure literal under the lets meets its arguments. The hoist
        -- assumes the let names do not occur free in the arguments. The
        -- hoisted lets take the call's result type, as every let of a chain
        -- carries its final body's type.
        MonoCall region ((MonoLet _ _ _) as callee) args resultType callInfo ->
            let
                ( calleeSpine, calleeInner ) =
                    splitLetSpine callee

                rebuilt =
                    List.foldr
                        (\( d, _ ) acc -> MonoLet d acc resultType)
                        (MonoCall region calleeInner args resultType callInfo)
                        calleeSpine
            in
            rewriteExpr ctx rebuilt

        MonoCall region func args resultType callInfo ->
            let
                ( rewrittenFunc, ctx1 ) =
                    rewriteExpr ctx func

                ( rewrittenArgs, ctx2 ) =
                    rewriteExprs ctx1 args
            in
            ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( rewrittenCaptures, ctx1 ) =
                    rewriteCaptures ctx info.captures

                ( rewrittenBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( MonoClosure { info | captures = rewrittenCaptures } rewrittenBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoList region rewrittenItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( rewrittenBranches, ctx1 ) =
                    rewriteBranches ctx branches

                ( rewrittenFinal, ctx2 ) =
                    rewriteExpr ctx1 final
            in
            case rewrittenBranches of
                [ ( MonoLiteral (Mono.LBool True) _, thenBranch ) ] ->
                    ( thenBranch, ctx2 )

                [ ( MonoLiteral (Mono.LBool False) _, _ ) ] ->
                    ( rewrittenFinal, ctx2 )

                _ ->
                    ( MonoIf rewrittenBranches rewrittenFinal resultType, ctx2 )

        MonoLet _ _ _ ->
            -- A let chain is rewritten as a whole: forwarding must see the
            -- uses of a name in every sibling definition, earlier ones
            -- included, and from an inner let an earlier sibling is an
            -- ancestor, out of sight of a count over the subtree.
            rewriteLetChain ctx expr

        MonoDestruct destructor inner resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoDestruct destructor rewrittenInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( rewrittenDecider, ctx1 ) =
                    rewriteDecider ctx decider

                ( rewrittenBranches, ctx2 ) =
                    rewriteCaseBranches ctx1 branches
            in
            ( MonoCase scrutName scrutType rewrittenDecider rewrittenBranches resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( rewrittenFields, ctx1 ) =
                    rewriteNamedFields ctx fields
            in
            ( MonoRecordCreate rewrittenFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoRecordAccess rewrittenInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner

                ( rewrittenUpdates, ctx2 ) =
                    rewriteNamedFields ctx1 updates
            in
            ( MonoRecordUpdate rewrittenInner rewrittenUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoTupleCreate region rewrittenItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            -- A tail call is never inlined; only its arguments are rewritten.
            let
                ( rewrittenArgs, ctx1 ) =
                    rewriteTailCallArgs ctx args
            in
            ( MonoTailCall name rewrittenArgs resultType, ctx1 )

        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )

        MonoAccessorValue _ _ _ ->
            ( expr, ctx )


{-| Returns each expression of a list rewritten by `rewriteExpr`, in order,
threading the context.
-}
rewriteExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
rewriteExprs ctx exprs =
    let
        ( revExprs, finalCtx ) =
            List.foldl
                (\expr ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( rewritten :: acc, newCtx )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, finalCtx )


{-| Returns each captured value of a closure rewritten by `rewriteExpr`,
threading the context.
-}
rewriteCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
rewriteCaptures ctx captures =
    let
        ( revCaptures, finalCtx ) =
            List.foldl
                (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten, isUnboxed ) :: acc, newCtx )
                )
                ( [], ctx )
                captures
    in
    ( List.reverse revCaptures, finalCtx )


{-| Returns each condition and branch of an `if` rewritten by `rewriteExpr`, in
order, threading the context.
-}
rewriteBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
rewriteBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( cond, body ) ( acc, accCtx ) ->
                    let
                        ( rewrittenCond, ctx1 ) =
                            rewriteExpr accCtx cond

                        ( rewrittenBody, ctx2 ) =
                            rewriteExpr ctx1 body
                    in
                    ( ( rewrittenCond, rewrittenBody ) :: acc, ctx2 )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


{-| Returns a `let` definition with its bound expression rewritten.
-}
rewriteDef : RewriteCtx -> Mono.MonoDef -> ( Mono.MonoDef, RewriteCtx )
rewriteDef ctx def =
    case def of
        Mono.MonoDef name bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoDef name rewritten, newCtx )

        Mono.MonoTailDef name params bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoTailDef name params rewritten, newCtx )


{-| Returns each jump branch of a case rewritten by `rewriteExpr`, threading
the context.
-}
rewriteCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
rewriteCaseBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( idx, body ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx body
                    in
                    ( ( idx, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


{-| Returns a decision tree with every `Inline` leaf rewritten by
`rewriteExpr`, threading the context.
-}
rewriteDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
rewriteDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( rewritten, ctx1 ) =
                            rewriteExpr ctx expr
                    in
                    ( Mono.Leaf (Mono.Inline rewritten), ctx1 )

                Mono.Jump _ ->
                    ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( rewrittenSuccess, ctx1 ) =
                    rewriteDecider ctx success

                ( rewrittenFailure, ctx2 ) =
                    rewriteDecider ctx1 failure
            in
            ( Mono.Chain testChain rewrittenSuccess rewrittenFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( revEdges, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( rewritten, newCtx ) =
                                    rewriteDecider accCtx d
                            in
                            ( ( test, rewritten ) :: acc, newCtx )
                        )
                        ( [], ctx )
                        edges

                rewrittenEdges =
                    List.reverse revEdges

                ( rewrittenFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( Mono.FanOut path rewrittenEdges rewrittenFallback, ctx2 )


{-| Returns each field value rewritten by `rewriteExpr`, threading the
context.
-}
rewriteNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteNamedFields ctx fields =
    let
        ( revFields, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                fields
    in
    ( List.reverse revFields, finalCtx )


{-| Returns each argument of a tail call rewritten by `rewriteExpr`, threading
the context.
-}
rewriteTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteTailCallArgs ctx args =
    let
        ( revArgs, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                args
    in
    ( List.reverse revArgs, finalCtx )



-- ============================================================================
-- ====== BETA REDUCTION ======
-- ============================================================================


{-| Returns the closure literal with `info` and `closureBody` applied to
`args`, where `resultType` is the type of the call.

Each parameter that gets an argument is bound to it by a `let` under a fresh
name, and the body, with those parameters renamed and its own `let` names
freshened, goes under the `let`s.

  - With no arguments, the result is the closure itself, typed `resultType`.
  - With exactly as many arguments as parameters, it is the body under the
    `let`s.
  - With fewer, it is a residual closure over the remaining parameters, under
    the `let`s. Its captures are computed again from the new body, its type is
    `residualClosureType`, and its `srcLambda`, `lssMember`, `closureKind` and
    `captureAbi` are cleared, since it is a new function and not the source
    lambda.
  - With more, it is the body under the `let`s, called with the rest of the
    arguments.

The closure's capture list is dropped, and the body's references to captured
names are left as they are. That is right only when each capture is a local
variable of the capture's own name, which is how
`Closure.computeClosureCaptures` builds them.

-}
betaReduce : RewriteCtx -> Region -> Mono.ClosureInfo -> MonoExpr -> List MonoExpr -> Mono.MonoType -> ( MonoExpr, RewriteCtx )
betaReduce ctx region info closureBody args resultType =
    let
        params =
            info.params

        numParams =
            List.length params

        numArgs =
            List.length args
    in
    if numArgs == 0 then
        ( MonoClosure info closureBody (Mono.typeOf (MonoClosure info closureBody resultType)), ctx )

    else if numArgs == numParams then
        let
            ( bindings, ctx1 ) =
                createBindings ctx params args

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)
        in
        ( wrapInLets bindings substituted resultType, bumpBetaReductions ctx2 )

    else if numArgs < numParams then
        let
            ( usedParams, remainingParams ) =
                ( List.take numArgs params, List.drop numArgs params )

            ( bindings, ctx1 ) =
                createBindings ctx usedParams args

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)

            newClosureType =
                residualClosureType remainingParams resultType

            -- Recompute captures for the new closure body.
            -- The substitution may have introduced new free variables (the fresh names
            -- bound in the surrounding lets) that need to be captured.
            newCaptures =
                Closure.computeClosureCaptures remainingParams substituted

            newInfo =
                { info
                    | params = remainingParams
                    , captures = newCaptures
                    , srcLambda = Nothing
                    , lssMember = Nothing
                    , closureKind = Nothing
                    , captureAbi = Nothing
                }
        in
        ( wrapInLets bindings (MonoClosure newInfo substituted newClosureType) newClosureType
        , bumpBetaReductions
            (bumpClearedMember (lambdaUid newInfo.lambdaId) info.lssMember "beta" ctx2)
        )

    else
        let
            ( usedArgs, extraArgs ) =
                ( List.take numParams args, List.drop numParams args )

            ( bindings, ctx1 ) =
                createBindings ctx params usedArgs

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)

            innerExpr =
                wrapInLets bindings substituted resultType
        in
        ( MonoCall region innerExpr extraArgs resultType Mono.defaultCallInfo
        , bumpBetaReductions ctx2
        )


{-| Returns a binding of each parameter to the argument in the same position,
each with a fresh name. Parameters or arguments beyond the shorter list are
ignored.
-}
createBindings : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindings ctx params args =
    let
        ( revBindings, finalCtx ) =
            List.foldl
                (\( ( paramName, _ ), arg ) ( acc, accCtx ) ->
                    let
                        ( freshName, newCtx ) =
                            freshVar accCtx

                        binding =
                            { origName = paramName
                            , freshName = freshName
                            , arg = arg
                            , argType = Mono.typeOf arg
                            }
                    in
                    ( binding :: acc, newCtx )
                )
                ( [], ctx )
                (List.map2 Tuple.pair params args)
    in
    ( List.reverse revBindings, finalCtx )


{-| Returns the type of a residual closure taking `remainingParams`, built by a
partial call whose type is `resultType`.

When `resultType` is a function whose first stage takes as many arguments as
there are remaining parameters, it is the closure's type as it is: a partial
call is typed as the function still to be applied, and wrapping that again
would declare one application more than the closure takes. Otherwise the type
is a function from the remaining parameters' types to `resultType`, annotated ⊤
(`Mono.topSynth`).

-}
residualClosureType : List ( Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoType
residualClosureType remainingParams resultType =
    case resultType of
        Mono.MFunction _ _ paramTypes _ ->
            if List.length paramTypes == List.length remainingParams then
                resultType

            else
                Mono.mFunction Mono.topSynth (List.map Tuple.second remainingParams) resultType

        _ ->
            Mono.mFunction Mono.topSynth (List.map Tuple.second remainingParams) resultType


{-| Returns `body` under one `let` per binding, the first binding outermost,
each binding its fresh name to its argument. Every `let` gets type
`resultType`.
-}
wrapInLets : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLets bindings body resultType =
    List.foldr
        (\binding acc ->
            MonoLet (Mono.MonoDef binding.freshName binding.arg) acc resultType
        )
        body
        bindings


{-| Returns `expr` with each binding's parameter renamed to the binding's fresh
name, the references taking the argument's type (`substitute`).
-}
substituteAll : List Binding -> MonoExpr -> MonoExpr
substituteAll bindings expr =
    List.foldl
        (\binding acc ->
            substitute binding.origName binding.freshName binding.argType acc
        )
        expr
        bindings


{-| Returns `expr` with every reference to the local `oldName` renamed to
`newName` and given type `varType`.

A reference is a variable, a case's root, the root of a destructuring or
decision-tree path, or the name of a capture. Tail-call callees are not
renamed. Below a binding of `oldName` nothing is renamed: inside a closure that
has it as a parameter (whose captures are then left as they are too), in the
body of a `let` that defines it, inside a local tail function that has it as a
parameter, and inside a destructuring that binds it.

-}
substitute : Name -> Name -> Mono.MonoType -> MonoExpr -> MonoExpr
substitute oldName newName varType expr =
    case expr of
        MonoVarLocal name _ ->
            if name == oldName then
                MonoVarLocal newName varType

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (substitute oldName newName varType) items) itemType

        MonoClosure info body closureType ->
            -- Don't substitute if the name is shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) info.params then
                expr

            else
                let
                    -- When substituting, also rename capture names that match oldName.
                    -- This ensures that if the body now references newName (due to substitution),
                    -- the capture binding also uses newName.
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) ->
                                ( if n == oldName then
                                    newName

                                  else
                                    n
                                , substitute oldName newName varType e
                                , isUnboxed
                                )
                            )
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (substitute oldName newName varType body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (substitute oldName newName varType func)
                (List.map (substitute oldName newName varType) args)
                resultType
                callInfo

        MonoTailCall name args resultType ->
            MonoTailCall name
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( substitute oldName newName varType c, substitute oldName newName varType t )) branches)
                (substitute oldName newName varType final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == oldName then
                -- Name is shadowed, only substitute in the def's bound expression
                MonoLet (substituteDef oldName newName varType def) body resultType

            else
                MonoLet (substituteDef oldName newName varType def) (substitute oldName newName varType body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                -- The path refers to the source variable, so substitute there
                newPath =
                    substitutePath oldName newName path

                -- The destructName is a NEW binding, don't rename it.
                -- If destructName == oldName, it shadows the param, so don't substitute in inner
                newInner =
                    if destructName == oldName then
                        inner

                    else
                        substitute oldName newName varType inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase unused rootName decider branches resultType ->
            -- The first Name is the case's label, the second its root variable.
            let
                newRootName =
                    if rootName == oldName then
                        newName

                    else
                        rootName

                newDecider =
                    substituteDecider oldName newName varType decider
            in
            MonoCase unused
                newRootName
                newDecider
                (List.map (\( idx, e ) -> ( idx, substitute oldName newName varType e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (substitute oldName newName varType inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (substitute oldName newName varType inner)
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (substitute oldName newName varType) items) tupleType


{-| Returns a `let` definition with `substitute` applied to its bound
expression, unless it is a local tail function with a parameter named
`oldName`.
-}
substituteDef : Name -> Name -> Mono.MonoType -> Mono.MonoDef -> Mono.MonoDef
substituteDef oldName newName varType def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (substitute oldName newName varType bound)

        Mono.MonoTailDef name params bound ->
            -- Don't substitute if shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) params then
                def

            else
                Mono.MonoTailDef name params (substitute oldName newName varType bound)


{-| Returns a destructuring path with its root renamed to `newName` when the
root is `oldName`.
-}
substitutePath : Name -> Name -> Mono.MonoPath -> Mono.MonoPath
substitutePath oldName newName path =
    case path of
        Mono.MonoRoot rootName rootType ->
            if rootName == oldName then
                Mono.MonoRoot newName rootType

            else
                path

        Mono.MonoIndex idx container resultType innerPath ->
            Mono.MonoIndex idx container resultType (substitutePath oldName newName innerPath)

        Mono.MonoField fieldIdx resultType innerPath ->
            Mono.MonoField fieldIdx resultType (substitutePath oldName newName innerPath)

        Mono.MonoUnbox resultType innerPath ->
            Mono.MonoUnbox resultType (substitutePath oldName newName innerPath)


{-| Returns a decision-tree path with its root renamed to `newName` when the
root is `oldName`.
-}
substituteDtPath : Name -> Name -> Mono.MonoDtPath -> Mono.MonoDtPath
substituteDtPath oldName newName dtPath =
    case dtPath of
        Mono.DtRoot name ty ->
            if name == oldName then
                Mono.DtRoot newName ty

            else
                dtPath

        Mono.DtIndex idx kind resultTy inner ->
            Mono.DtIndex idx kind resultTy (substituteDtPath oldName newName inner)

        Mono.DtUnbox resultTy inner ->
            Mono.DtUnbox resultTy (substituteDtPath oldName newName inner)


{-| Returns a decision tree with `substitute` applied to every `Inline` leaf,
and every test path's root renamed.
-}
substituteDecider : Name -> Name -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
substituteDecider oldName newName varType decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    Mono.Leaf (Mono.Inline (substitute oldName newName varType expr))

                Mono.Jump _ ->
                    decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( substituteDtPath oldName newName dtPath, test )
                    )
                    testChain
                )
                (substituteDecider oldName newName varType success)
                (substituteDecider oldName newName varType failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (substituteDtPath oldName newName path)
                (List.map (\( test, d ) -> ( test, substituteDecider oldName newName varType d )) edges)
                (substituteDecider oldName newName varType fallback)


{-| Returns the name a `let` definition binds.
-}
getDefName : Mono.MonoDef -> Name
getDefName def =
    case def of
        Mono.MonoDef name _ ->
            name

        Mono.MonoTailDef name _ _ ->
            name


{-| Returns a `let` definition with the name it binds replaced.
-}
setDefName : Name -> Mono.MonoDef -> Mono.MonoDef
setDefName newName def =
    case def of
        Mono.MonoDef _ bound ->
            Mono.MonoDef newName bound

        Mono.MonoTailDef _ params bound ->
            Mono.MonoTailDef newName params bound



-- ============================================================================
-- ====== LET-CALLEE FORWARDING ======
-- ============================================================================


{-| What a `let` definition hands to the one call that uses it as callee, when
let-callee forwarding moves it there.

`ForwardClosure` carries a closure literal's info and body, which are
beta-reduced against the call's arguments. A call passing exactly the closure's
parameters is reduced in full; one passing more is reduced for the first stage
and the result applied to the rest; one passing fewer is not forwarded to.

`ForwardPartialCall` carries a partial call of a global or kernel: the callee,
the arguments it was given, and its arity. The use becomes one call of the
callee with both argument lists, provided the total does not exceed the arity.

-}
type ForwardPayload
    = ForwardClosure Mono.ClosureInfo MonoExpr
    | ForwardPartialCall MonoExpr (List MonoExpr) Int


{-| Returns a `let` chain with every bound expression and the final body
rewritten, then each definition that binds a `let` chain ending in a closure
split up (`flattenClosureDef`), and let-callee forwarding applied over the
whole chain (`forwardInChain`).
-}
rewriteLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spine0, finalBody0 ) =
            splitSpine chainExpr []

        ( spineRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( d1, c1 ) =
                            rewriteDef c d
                    in
                    ( ( d1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spine0

        ( finalBody1, ctx2 ) =
            rewriteExpr ctx1 finalBody0

        spineFlattened =
            List.concatMap flattenClosureDef (List.reverse spineRev)

        ( spine2, finalBody2, ctx3 ) =
            forwardInChain ctx2 spineFlattened finalBody1
    in
    ( List.foldr (\( d, t ) acc -> MonoLet d acc t) finalBody2 spine2, ctx3 )


{-| Returns a chain entry split in two when its bound expression is a `let`
chain ending in a closure literal: `f = (let a = e in \x -> b)` becomes `a = e`
followed by `f = \x -> b`. Any other entry is returned alone.

A partial inline leaves this shape, the residual closure under the argument
`let`s, and splitting it lets forwarding see the literal. The order of
evaluation is kept. Each moved definition takes the outer entry's type, since
every `let` of a chain carries the type of the chain's final body.

-}
flattenClosureDef : ( Mono.MonoDef, Mono.MonoType ) -> List ( Mono.MonoDef, Mono.MonoType )
flattenClosureDef (( d, t ) as entry) =
    case d of
        Mono.MonoDef name ((MonoLet _ _ _) as bound) ->
            let
                ( innerSpine, innerFinal ) =
                    splitLetSpine bound
            in
            case innerFinal of
                MonoClosure _ _ _ ->
                    List.map (\( d2, _ ) -> ( d2, t )) innerSpine
                        ++ [ ( Mono.MonoDef name innerFinal, t ) ]

                _ ->
                    [ entry ]

        _ ->
            [ entry ]


{-| Returns the definitions of a `let` chain, outermost first, each with its
`let`'s type, and the first expression below them that is not a `let`.
-}
splitLetSpine : MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
splitLetSpine expr =
    let
        go e acc =
            case e of
                MonoLet d b t ->
                    go b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )
    in
    go expr []


{-| Returns the chain `spine` with body `finalBody` after let-callee forwarding,
repeated until nothing more is forwarded. A forwarded definition is removed,
and its value is moved into the one call that uses it as callee.

A definition is forwarded when all of these hold:

  - It binds a closure literal, or a call of a global or kernel whose arity
    `calleeArity` knows, with fewer arguments than that arity, every argument
    pure (`isPureExpr`).
  - Its bound expression does not refer to its own name.
  - No earlier definition of the chain refers to it. Sibling definitions can
    refer to each other in both directions, and removing the definition would
    leave such a reference unbound.
  - The later definitions and the final body refer to it exactly once, and
    `forwardGo` accepts that reference.

The value moves to a later point, where everything it refers to is still
bound. A partial call runs no code when it is bound, and its arguments are
pure, so moving it changes nothing else. Forwarding a partial call removes a
definition and adds none; forwarding a closure removes it and beta-reduces it
at its use.

-}
forwardInChain : RewriteCtx -> List ( Mono.MonoDef, Mono.MonoType ) -> MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr, RewriteCtx )
forwardInChain ctx spine finalBody =
    let
        usesInDefsOf : Name -> List ( Mono.MonoDef, Mono.MonoType ) -> Int
        usesInDefsOf name defs =
            List.foldl (\( d, _ ) n -> n + countUsagesInDef name d) 0 defs

        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        tryAt :
            List ( Mono.MonoDef, Mono.MonoType )
            -> List ( Mono.MonoDef, Mono.MonoType )
            -> MonoExpr
            -> RewriteCtx
            -> Maybe ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr, RewriteCtx )
        tryAt beforeRev after fb c =
            case after of
                [] ->
                    Nothing

                (( d, _ ) as entry) :: rest ->
                    let
                        skip () =
                            tryAt (entry :: beforeRev) rest fb c

                        -- The later definitions and the final body are rebuilt
                        -- as one expression, so that `forwardGo` can find the
                        -- use in either, and split again afterwards.
                        attempt name boundExpr payload bumper =
                            if
                                countUsages name boundExpr
                                    == 0
                                    && usesInDefsOf name beforeRev
                                    == 0
                                    && (usesInDefsOf name rest + countUsages name fb)
                                    == 1
                            then
                                let
                                    tailExpr =
                                        List.foldr (\( d2, t2 ) acc -> MonoLet d2 acc t2) fb rest
                                in
                                case forwardGo c name payload tailExpr of
                                    Just ( tail1, c1 ) ->
                                        let
                                            ( rest1, fb1 ) =
                                                splitSpine tail1 []
                                        in
                                        Just ( List.reverse beforeRev ++ rest1, fb1, bumper c1 )

                                    Nothing ->
                                        skip ()

                            else
                                skip ()
                    in
                    case d of
                        Mono.MonoDef name ((MonoClosure cinfo cbody _) as closureExpr) ->
                            attempt name closureExpr (ForwardClosure cinfo cbody) bumpBetaForwards

                        Mono.MonoDef name ((MonoCall _ ((MonoVarGlobal _ _ _) as funcExpr) boundArgs _ _) as boundCall) ->
                            -- A partial application runs no code when bound, and
                            -- pure arguments can be moved.
                            case calleeArity c funcExpr of
                                Just arity ->
                                    if
                                        List.length boundArgs
                                            < arity
                                            && List.all isPureExpr boundArgs
                                    then
                                        attempt name boundCall (ForwardPartialCall funcExpr boundArgs arity) bumpPartialMerges

                                    else
                                        skip ()

                                Nothing ->
                                    skip ()

                        Mono.MonoDef name ((MonoCall _ ((MonoVarKernel _ _ _ _ _) as funcExpr) boundArgs _ _) as boundCall) ->
                            -- The same rule for a partial call of a kernel.
                            case calleeArity c funcExpr of
                                Just arity ->
                                    if
                                        List.length boundArgs
                                            < arity
                                            && List.all isPureExpr boundArgs
                                    then
                                        attempt name boundCall (ForwardPartialCall funcExpr boundArgs arity) bumpPartialMerges

                                    else
                                        skip ()

                                Nothing ->
                                    skip ()

                        _ ->
                            skip ()

        loop sp fb c =
            case tryAt [] sp fb c of
                Just ( sp1, fb1, c1 ) ->
                    loop sp1 fb1 c1

                Nothing ->
                    ( sp, fb, c )
    in
    loop spine finalBody ctx


{-| Returns `expr` with the call whose callee is the local `name` replaced by
`payload` applied to that call's arguments, as `ForwardPayload` describes, or
`Nothing` when no call can take it, in which case the definition is kept.

`name` must occur exactly once in `expr`: the walk takes the first call it
finds.

The walk does not enter a closure, neither its captures nor its body, nor the
body of a local tail function. Moving the value there would build it at every
call or every loop iteration, and a closure's captures are already fixed, so a
new free variable in its body would not be captured. The walk stops at a
definition or destructuring that binds `name`, at a case whose root or label is
`name`, and at a tail call to `name`. A use that is not the callee of a call is
not taken. Branches of an `if` or a case are entered: a branch runs at most once
each time the body is evaluated.

-}
forwardGo : RewriteCtx -> Name -> ForwardPayload -> MonoExpr -> Maybe ( MonoExpr, RewriteCtx )
forwardGo ctx name payload expr =
    case expr of
        MonoCall region func args t ci ->
            case func of
                MonoVarLocal n _ ->
                    if n == name then
                        case payload of
                            ForwardClosure cinfo cbody ->
                                -- A use with fewer arguments than params is not
                                -- taken: it would build a residual closure.
                                if List.length args == List.length cinfo.params then
                                    Just (betaReduce ctx region cinfo cbody args t)

                                else if
                                    (List.length args > List.length cinfo.params)
                                        && not (List.isEmpty cinfo.params)
                                then
                                    -- One call node can carry the arguments of
                                    -- several stages (`f a s1`). Reduce the
                                    -- first stage exactly and apply the result
                                    -- to the rest; later rounds reduce that.
                                    let
                                        nParams =
                                            List.length cinfo.params

                                        ( inner, ctx1 ) =
                                            betaReduce ctx region cinfo cbody (List.take nParams args) (Mono.typeOf cbody)
                                    in
                                    Just
                                        ( MonoCall region inner (List.drop nParams args) t Mono.defaultCallInfo
                                        , ctx1
                                        )

                                else
                                    Nothing

                            ForwardPartialCall funcExpr boundArgs arity ->
                                -- A total over the arity is refused: the
                                -- result would be applied again.
                                if List.length boundArgs + List.length args <= arity then
                                    Just
                                        ( MonoCall region funcExpr (boundArgs ++ args) t Mono.defaultCallInfo
                                        , ctx
                                        )

                                else
                                    Nothing

                    else
                        forwardGoList ctx name payload args
                            |> Maybe.map (\( args1, c ) -> ( MonoCall region func args1 t ci, c ))

                _ ->
                    case forwardGo ctx name payload func of
                        Just ( func1, c ) ->
                            Just ( MonoCall region func1 args t ci, c )

                        Nothing ->
                            forwardGoList ctx name payload args
                                |> Maybe.map (\( args1, c ) -> ( MonoCall region func args1 t ci, c ))

        MonoClosure _ _ _ ->
            -- Sinking guard: never move an allocation into a closure body,
            -- and a capture-position use is not a callee anyway.
            Nothing

        MonoLet d b t ->
            if getDefName d == name then
                -- `name` is rebound here, so the uses below are not ours.
                Nothing

            else
                case d of
                    Mono.MonoDef dn bound ->
                        case forwardGo ctx name payload bound of
                            Just ( bound1, c ) ->
                                Just ( MonoLet (Mono.MonoDef dn bound1) b t, c )

                            Nothing ->
                                forwardGo ctx name payload b
                                    |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

                    Mono.MonoTailDef _ _ _ ->
                        -- Sinking guard: a tail-def bound expr is a loop body.
                        forwardGo ctx name payload b
                            |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

        MonoDestruct ((Mono.MonoDestructor dn _ _) as dtor) inner t ->
            if dn == name then
                Nothing

            else
                forwardGo ctx name payload inner
                    |> Maybe.map (\( inner1, c ) -> ( MonoDestruct dtor inner1 t, c ))

        MonoIf branches final t ->
            case forwardGoIfBranches ctx name payload branches of
                Just ( branches1, c ) ->
                    Just ( MonoIf branches1 final t, c )

                Nothing ->
                    forwardGo ctx name payload final
                        |> Maybe.map (\( final1, c ) -> ( MonoIf branches final1 t, c ))

        MonoCase s r decider branches t ->
            if s == name || r == name then
                -- `name` is the case's root or label: not a callee use.
                Nothing

            else
                case forwardGoDecider ctx name payload decider of
                    Just ( decider1, c ) ->
                        Just ( MonoCase s r decider1 branches t, c )

                    Nothing ->
                        forwardGoSndList ctx name payload branches
                            |> Maybe.map (\( branches1, c ) -> ( MonoCase s r decider branches1 t, c ))

        MonoList region items t ->
            forwardGoList ctx name payload items
                |> Maybe.map (\( items1, c ) -> ( MonoList region items1 t, c ))

        MonoTailCall n args t ->
            if n == name then
                Nothing

            else
                forwardGoSndList ctx name payload args
                    |> Maybe.map (\( args1, c ) -> ( MonoTailCall n args1 t, c ))

        MonoRecordCreate fields t ->
            forwardGoSndList ctx name payload fields
                |> Maybe.map (\( fields1, c ) -> ( MonoRecordCreate fields1 t, c ))

        MonoRecordAccess inner f t ->
            forwardGo ctx name payload inner
                |> Maybe.map (\( inner1, c ) -> ( MonoRecordAccess inner1 f t, c ))

        MonoRecordUpdate inner updates t ->
            case forwardGo ctx name payload inner of
                Just ( inner1, c ) ->
                    Just ( MonoRecordUpdate inner1 updates t, c )

                Nothing ->
                    forwardGoSndList ctx name payload updates
                        |> Maybe.map (\( updates1, c ) -> ( MonoRecordUpdate inner updates1 t, c ))

        MonoTupleCreate region items t ->
            forwardGoList ctx name payload items
                |> Maybe.map (\( items1, c ) -> ( MonoTupleCreate region items1 t, c ))

        MonoLiteral _ _ ->
            Nothing

        MonoVarLocal _ _ ->
            Nothing

        MonoVarGlobal _ _ _ ->
            Nothing

        MonoVarKernel _ _ _ _ _ ->
            Nothing

        MonoUnit ->
            Nothing

        MonoAccessorValue _ _ _ ->
            Nothing


{-| Returns how many arguments a callee takes in one call, when that is known
statically: a closure literal's parameter count, a global's entry in
`specArities`, or a kernel's flat arity (`flatArrowArity`) when above zero.
Any other callee gives `Nothing`.
-}
calleeArity : RewriteCtx -> MonoExpr -> Maybe Int
calleeArity ctx funcExpr =
    case funcExpr of
        MonoClosure info _ _ ->
            Just (List.length info.params)

        MonoVarGlobal _ specId _ ->
            Dict.get specId ctx.specArities

        MonoVarKernel _ _ _ _ kernelType ->
            -- A kernel's type is staged (`Int -> (Int -> Int)`), but its
            -- arity here is the flat one, over every stage.
            let
                n =
                    flatArrowArity kernelType
            in
            if n > 0 then
                Just n

            else
                Nothing

        _ ->
            Nothing


{-| Returns the list with `forwardGo` applied to the first element where it
succeeds, or `Nothing` when it succeeds on none.
-}
forwardGoList : RewriteCtx -> Name -> ForwardPayload -> List MonoExpr -> Maybe ( List MonoExpr, RewriteCtx )
forwardGoList ctx name payload exprs =
    case exprs of
        [] ->
            Nothing

        e :: rest ->
            case forwardGo ctx name payload e of
                Just ( e1, c ) ->
                    Just ( e1 :: rest, c )

                Nothing ->
                    forwardGoList ctx name payload rest
                        |> Maybe.map (\( rest1, c ) -> ( e :: rest1, c ))


{-| Returns the pairs with `forwardGo` applied to the second part of the first
pair where it succeeds, or `Nothing` when it succeeds on none.
-}
forwardGoSndList : RewriteCtx -> Name -> ForwardPayload -> List ( a, MonoExpr ) -> Maybe ( List ( a, MonoExpr ), RewriteCtx )
forwardGoSndList ctx name payload pairs =
    case pairs of
        [] ->
            Nothing

        ( k, e ) :: rest ->
            case forwardGo ctx name payload e of
                Just ( e1, c ) ->
                    Just ( ( k, e1 ) :: rest, c )

                Nothing ->
                    forwardGoSndList ctx name payload rest
                        |> Maybe.map (\( rest1, c ) -> ( ( k, e ) :: rest1, c ))


{-| Returns the conditions and branches of an `if` with `forwardGo` applied to
the first of them, in order, where it succeeds, or `Nothing` when it succeeds
on none. The final `else` is not included.
-}
forwardGoIfBranches : RewriteCtx -> Name -> ForwardPayload -> List ( MonoExpr, MonoExpr ) -> Maybe ( List ( MonoExpr, MonoExpr ), RewriteCtx )
forwardGoIfBranches ctx name payload branches =
    case branches of
        [] ->
            Nothing

        ( cond, then_ ) :: rest ->
            case forwardGo ctx name payload cond of
                Just ( cond1, c ) ->
                    Just ( ( cond1, then_ ) :: rest, c )

                Nothing ->
                    case forwardGo ctx name payload then_ of
                        Just ( then1, c ) ->
                            Just ( ( cond, then1 ) :: rest, c )

                        Nothing ->
                            forwardGoIfBranches ctx name payload rest
                                |> Maybe.map (\( rest1, c ) -> ( ( cond, then_ ) :: rest1, c ))


{-| Returns a decision tree with `forwardGo` applied to the first `Inline` leaf
where it succeeds, or `Nothing` when it succeeds on none.
-}
forwardGoDecider : RewriteCtx -> Name -> ForwardPayload -> Mono.Decider Mono.MonoChoice -> Maybe ( Mono.Decider Mono.MonoChoice, RewriteCtx )
forwardGoDecider ctx name payload decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            forwardGo ctx name payload e
                |> Maybe.map (\( e1, c ) -> ( Mono.Leaf (Mono.Inline e1), c ))

        Mono.Leaf (Mono.Jump _) ->
            Nothing

        Mono.Chain tests success failure ->
            case forwardGoDecider ctx name payload success of
                Just ( s1, c ) ->
                    Just ( Mono.Chain tests s1 failure, c )

                Nothing ->
                    forwardGoDecider ctx name payload failure
                        |> Maybe.map (\( f1, c ) -> ( Mono.Chain tests success f1, c ))

        Mono.FanOut path tests fallback ->
            case forwardGoDeciderSndList ctx name payload tests of
                Just ( tests1, c ) ->
                    Just ( Mono.FanOut path tests1 fallback, c )

                Nothing ->
                    forwardGoDecider ctx name payload fallback
                        |> Maybe.map (\( fb1, c ) -> ( Mono.FanOut path tests fb1, c ))


{-| Returns the edges of a decision tree with `forwardGoDecider` applied to the
first subtree where it succeeds, or `Nothing` when it succeeds on none.
-}
forwardGoDeciderSndList : RewriteCtx -> Name -> ForwardPayload -> List ( a, Mono.Decider Mono.MonoChoice ) -> Maybe ( List ( a, Mono.Decider Mono.MonoChoice ), RewriteCtx )
forwardGoDeciderSndList ctx name payload pairs =
    case pairs of
        [] ->
            Nothing

        ( k, d ) :: rest ->
            case forwardGoDecider ctx name payload d of
                Just ( d1, c ) ->
                    Just ( ( k, d1 ) :: rest, c )

                Nothing ->
                    forwardGoDeciderSndList ctx name payload rest
                        |> Maybe.map (\( rest1, c ) -> ( ( k, d ) :: rest1, c ))



-- ============================================================================
-- ====== ALPHA-RENAMING OF INSTANTIATED BODIES ======
-- ============================================================================


{-| Returns `expr` with every name bound in it by a `let` definition, a local
tail function or a destructuring replaced by a fresh name, and every reference
renamed to match.

A copied body keeps the binder names of the function it came from, so two
copies in one function would otherwise bind the same names twice. Inner
binders are renamed before outer ones, so no rename can be captured by an inner
binding of the same name. Closure parameters and tail-function parameters keep
their names.

-}
freshenLetBoundNames : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
freshenLetBoundNames ctx expr =
    case expr of
        MonoLet _ _ _ ->
            -- A chain is renamed as a whole: sibling definitions can refer to
            -- each other in both directions.
            freshenLetChain ctx expr

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )

        MonoAccessorValue _ _ _ ->
            ( expr, ctx )

        MonoList region items itemType ->
            let
                ( items1, ctx1 ) =
                    freshenLetBoundNamesList ctx items
            in
            ( MonoList region items1 itemType, ctx1 )

        MonoClosure info body closureType ->
            let
                ( capturesRev, ctx1 ) =
                    List.foldl
                        (\( n, e, isUnboxed ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1, isUnboxed ) :: acc, c1 )
                        )
                        ( [], ctx )
                        info.captures

                ( body1, ctx2 ) =
                    freshenLetBoundNames ctx1 body
            in
            ( MonoClosure { info | captures = List.reverse capturesRev } body1 closureType, ctx2 )

        MonoCall region func args resultType callInfo ->
            let
                ( func1, ctx1 ) =
                    freshenLetBoundNames ctx func

                ( args1, ctx2 ) =
                    freshenLetBoundNamesList ctx1 args
            in
            ( MonoCall region func1 args1 resultType callInfo, ctx2 )

        MonoTailCall name args resultType ->
            let
                ( argsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
            in
            ( MonoTailCall name (List.reverse argsRev) resultType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( branchesRev, ctx1 ) =
                    List.foldl
                        (\( c, t ) ( acc, cx ) ->
                            let
                                ( c1, cx1 ) =
                                    freshenLetBoundNames cx c

                                ( t1, cx2 ) =
                                    freshenLetBoundNames cx1 t
                            in
                            ( ( c1, t1 ) :: acc, cx2 )
                        )
                        ( [], ctx )
                        branches

                ( final1, ctx2 ) =
                    freshenLetBoundNames ctx1 final
            in
            ( MonoIf (List.reverse branchesRev) final1 resultType, ctx2 )

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            -- A destructuring binder left as it is could capture a caller's
            -- variable of the same name used after the inlined code. The inner
            -- expression is freshened first, as for let definitions.
            let
                ( inner0, ctx1 ) =
                    freshenLetBoundNames ctx inner

                ( newName, ctx2 ) =
                    freshVar ctx1
            in
            ( MonoDestruct (Mono.MonoDestructor newName path destructType)
                (renameLocal destructName newName inner0)
                resultType
            , ctx2
            )

        MonoCase unused rootName decider jumps resultType ->
            let
                ( decider1, ctx1 ) =
                    freshenLetBoundNamesInDecider ctx decider

                ( jumpsRev, ctx2 ) =
                    List.foldl
                        (\( idx, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( idx, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        jumps
            in
            ( MonoCase unused rootName decider1 (List.reverse jumpsRev) resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( fieldsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( MonoRecordCreate (List.reverse fieldsRev) recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( inner1, ctx1 ) =
                    freshenLetBoundNames ctx inner
            in
            ( MonoRecordAccess inner1 fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( inner1, ctx1 ) =
                    freshenLetBoundNames ctx inner

                ( updatesRev, ctx2 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( MonoRecordUpdate inner1 (List.reverse updatesRev) recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( items1, ctx1 ) =
                    freshenLetBoundNamesList ctx items
            in
            ( MonoTupleCreate region items1 tupleType, ctx1 )


{-| Returns a `let` chain with its names freshened as a whole:

1.  Split the chain into its definitions and the final body that is not a
    `let`.
2.  Freshen inside each definition's bound expression and the final body.
    After this no binder below carries one of the chain's own names, so the
    renames of step 4 cannot be captured.
3.  Give each definition of the chain a fresh name.
4.  Apply every rename across the whole rebuilt chain, so that references in
    both directions follow their definition.

-}
freshenLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
freshenLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spineRev, finalBody0 ) =
            splitSpine chainExpr []

        -- Step 2: freshen inside each def's bound expr, and the final body
        ( spineFreshenedRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( d1, c1 ) =
                            freshenInDef c d
                    in
                    ( ( d1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spineRev

        spineFreshened =
            List.reverse spineFreshenedRev

        ( finalBody1, ctx2 ) =
            freshenLetBoundNames ctx1 finalBody0

        -- Step 3: fresh name per def
        ( renamesRev, spineRenamedRev, ctx3 ) =
            List.foldl
                (\( d, t ) ( rens, defs, c ) ->
                    let
                        ( newName, c1 ) =
                            freshVar c
                    in
                    ( ( getDefName d, newName ) :: rens
                    , ( setDefName newName d, t ) :: defs
                    , c1
                    )
                )
                ( [], [], ctx2 )
                spineFreshened

        rebuilt =
            List.foldl
                (\( d, t ) acc -> MonoLet d acc t)
                finalBody1
                spineRenamedRev

        -- Step 4: apply all renames over the whole chain
        renamed =
            List.foldl
                (\( old, new ) e -> renameLocal old new e)
                rebuilt
                renamesRev
    in
    ( renamed, ctx3 )


{-| Returns each expression of a list with `freshenLetBoundNames` applied, in
order, threading the context.
-}
freshenLetBoundNamesList : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
freshenLetBoundNamesList ctx exprs =
    let
        ( revExprs, ctx1 ) =
            List.foldl
                (\e ( acc, c ) ->
                    let
                        ( e1, c1 ) =
                            freshenLetBoundNames c e
                    in
                    ( e1 :: acc, c1 )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, ctx1 )


{-| Returns a definition with the names bound inside its bound expression
freshened. The definition's own name is left to the caller.
-}
freshenInDef : RewriteCtx -> Mono.MonoDef -> ( Mono.MonoDef, RewriteCtx )
freshenInDef ctx def =
    case def of
        Mono.MonoDef name bound ->
            let
                ( bound1, ctx1 ) =
                    freshenLetBoundNames ctx bound
            in
            ( Mono.MonoDef name bound1, ctx1 )

        Mono.MonoTailDef name params bound ->
            let
                ( bound1, ctx1 ) =
                    freshenLetBoundNames ctx bound
            in
            ( Mono.MonoTailDef name params bound1, ctx1 )


{-| Returns a decision tree with `freshenLetBoundNames` applied to every
`Inline` leaf.
-}
freshenLetBoundNamesInDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
freshenLetBoundNamesInDecider ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            let
                ( expr1, ctx1 ) =
                    freshenLetBoundNames ctx expr
            in
            ( Mono.Leaf (Mono.Inline expr1), ctx1 )

        Mono.Leaf (Mono.Jump _) ->
            ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( success1, ctx1 ) =
                    freshenLetBoundNamesInDecider ctx success

                ( failure1, ctx2 ) =
                    freshenLetBoundNamesInDecider ctx1 failure
            in
            ( Mono.Chain testChain success1 failure1, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( edgesRev, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, c ) ->
                            let
                                ( d1, c1 ) =
                                    freshenLetBoundNamesInDecider c d
                            in
                            ( ( test, d1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        edges

                ( fallback1, ctx2 ) =
                    freshenLetBoundNamesInDecider ctx1 fallback
            in
            ( Mono.FanOut path (List.reverse edgesRev) fallback1, ctx2 )


{-| Returns `expr` with every reference to the local `oldName` renamed to
`newName`, each keeping its own type, unlike `substitute`, which gives every
reference one type and would be wrong for a local tail function, whose
references carry function types.

It also renames tail-call callees, which a tail function's rename needs.
Otherwise it renames what `substitute` renames and stops where it stops.

-}
renameLocal : Name -> Name -> MonoExpr -> MonoExpr
renameLocal oldName newName expr =
    case expr of
        MonoVarLocal name varType ->
            if name == oldName then
                MonoVarLocal newName varType

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (renameLocal oldName newName) items) itemType

        MonoClosure info body closureType ->
            if List.any (\( n, _ ) -> n == oldName) info.params then
                expr

            else
                let
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) ->
                                ( if n == oldName then
                                    newName

                                  else
                                    n
                                , renameLocal oldName newName e
                                , isUnboxed
                                )
                            )
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (renameLocal oldName newName body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (renameLocal oldName newName func)
                (List.map (renameLocal oldName newName) args)
                resultType
                callInfo

        MonoTailCall name args resultType ->
            MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( renameLocal oldName newName c, renameLocal oldName newName t )) branches)
                (renameLocal oldName newName final)
                resultType

        MonoLet def body resultType ->
            if getDefName def == oldName then
                -- Name is shadowed, only rename in the def's bound expression
                MonoLet (renameLocalInDef oldName newName def) body resultType

            else
                MonoLet (renameLocalInDef oldName newName def) (renameLocal oldName newName body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                newPath =
                    substitutePath oldName newName path

                newInner =
                    if destructName == oldName then
                        inner

                    else
                        renameLocal oldName newName inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase unused rootName decider branches resultType ->
            MonoCase unused
                (if rootName == oldName then
                    newName

                 else
                    rootName
                )
                (renameLocalInDecider oldName newName decider)
                (List.map (\( idx, e ) -> ( idx, renameLocal oldName newName e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (renameLocal oldName newName inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (renameLocal oldName newName inner)
                (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (renameLocal oldName newName) items) tupleType


{-| Returns a `let` definition with `renameLocal` applied to its bound
expression, unless it is a local tail function with a parameter named
`oldName`.
-}
renameLocalInDef : Name -> Name -> Mono.MonoDef -> Mono.MonoDef
renameLocalInDef oldName newName def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (renameLocal oldName newName bound)

        Mono.MonoTailDef name params bound ->
            if List.any (\( n, _ ) -> n == oldName) params then
                def

            else
                Mono.MonoTailDef name params (renameLocal oldName newName bound)


{-| Returns a decision tree with `renameLocal` applied to every `Inline` leaf,
and every test path's root renamed.
-}
renameLocalInDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameLocalInDecider oldName newName decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.Leaf (Mono.Inline (renameLocal oldName newName expr))

        Mono.Leaf (Mono.Jump _) ->
            decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( substituteDtPath oldName newName dtPath, test )
                    )
                    testChain
                )
                (renameLocalInDecider oldName newName success)
                (renameLocalInDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (substituteDtPath oldName newName path)
                (List.map (\( test, d ) -> ( test, renameLocalInDecider oldName newName d )) edges)
                (renameLocalInDecider oldName newName fallback)



-- ============================================================================
-- ====== DIRECT CALL INLINING ======
-- ============================================================================


{-| Returns the call of inline candidate `specId` with `args` replaced by a
copy of the callee's body, or `Nothing` when the call is not inlined, with the
context.

It is not inlined when the current node's inline budget is spent, `specId` is
not a candidate, an exact-only candidate gets fewer arguments than it has
parameters, or a callee with no parameters whose value is a bare kernel
reference is called with a function-typed result. A call with fewer arguments
than parameters is also declined when `preserveSets` is on, or when the
residual closure would exceed `HeapLimits.maxStageArity`.

A callee with no parameters called with arguments is copied with fresh lambda
ids only. Any other copy has fresh lambda ids, its parameters bound to the
arguments by `let`s under fresh names, and fresh `let` names. Then:

  - A callee with no parameters called with arguments becomes a call of the
    copied value with all of them.
  - An exact call becomes the body under the argument `let`s.
  - A call with fewer arguments becomes a residual closure over the remaining
    parameters, under the argument `let`s, with a fresh lambda id in the
    callee's module and no lambda-set identity.
  - A call with more arguments becomes a call of the body under the `let`s,
    with the rest of the arguments.

-}
tryInlineCall : Region -> RewriteCtx -> SpecId -> List MonoExpr -> Mono.MonoType -> ( Maybe MonoExpr, RewriteCtx )
tryInlineCall callRegion ctx specId args resultType =
    if ctx.inlineCountThisFunction >= ctx.maxInlinesPerFunction then
        ( Nothing, ctx )

    else
        case Dict.get specId ctx.inlineCandidates of
            Nothing ->
                ( Nothing, ctx )

            Just ( params, body, ( exactOnly, calleeMember ) ) ->
                let
                    numParams =
                        List.length params

                    numArgs =
                        List.length args
                in
                if exactOnly && numArgs < numParams then
                    -- An exact-only candidate is never inlined partially.
                    ( Nothing, ctx )

                else if numParams == 0 && numArgs > 0 then
                    -- A called value with no params: inline the value and call
                    -- it. Not done for a bare kernel reference when the call's
                    -- result is a function, so that the partial application
                    -- keeps the specialized wrapper (such as `Basics.add` at
                    -- `Int`) as its target rather than the kernel itself.
                    let
                        bodyIsKernelRef =
                            case body of
                                MonoVarKernel _ _ _ _ _ ->
                                    True

                                _ ->
                                    False

                        resultIsFunctionType =
                            case resultType of
                                Mono.MFunction _ _ _ _ ->
                                    True

                                _ ->
                                    False
                    in
                    if bodyIsKernelRef && resultIsFunctionType then
                        ( Nothing, ctx )

                    else
                        let
                            ( remappedBody, ctx1 ) =
                                remapLambdaIds ctx body

                            inlined =
                                MonoCall A.zero remappedBody args resultType Mono.defaultCallInfo
                        in
                        ( Just inlined
                        , recordInlineAt callRegion specId ctx1
                        )

                else if numArgs < numParams && ctx.preserveSets then
                    -- The residual closure built below would belong to no
                    -- lambda set; the callee's own partial application keeps
                    -- its member. Whitelisted and `partialHof` candidates are
                    -- declined too.
                    ( Nothing, bumpDeclinedPreserveSets ctx )

                else if numArgs < numParams then
                    let
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( usedParams, remainingParams ) =
                            ( List.take numArgs params, List.drop numArgs params )

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 usedParams args

                        ( substituted, ctx2a ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        ( newLambdaId, ctx3 ) =
                            freshLambdaIdForSpec ctx2a specId

                        newClosureType =
                            residualClosureType remainingParams resultType

                        newCaptures =
                            Closure.computeClosureCaptures remainingParams substituted

                        newClosureInfo =
                            { lambdaId = newLambdaId
                            , srcLambda = Nothing
                            , lssMember = Nothing
                            , params = remainingParams
                            , captures = newCaptures
                            , closureKind = Nothing
                            , captureAbi = Nothing
                            }

                        newClosure =
                            MonoClosure newClosureInfo substituted newClosureType

                        inlined =
                            wrapInLetsForInline bindings newClosure newClosureType
                    in
                    if exceedsStageArity remainingParams newCaptures then
                        ( Nothing, bumpDeclinedArityCap ctx )

                    else
                        ( Just inlined
                        , recordInline specId
                            (bumpClearedMember (lambdaUid newLambdaId) calleeMember "tryInline" ctx3)
                        )

                else if numArgs > numParams then
                    let
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( usedArgs, extraArgs ) =
                            ( List.take numParams args, List.drop numParams args )

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 params usedArgs

                        ( substituted, ctx3 ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        innerExpr =
                            wrapInLetsForInline bindings substituted resultType

                        inlined =
                            MonoCall A.zero innerExpr extraArgs resultType Mono.defaultCallInfo
                    in
                    ( Just inlined
                    , recordInlineAt callRegion specId ctx3
                    )

                else
                    let
                        -- Fresh lambda ids, so the copy does not duplicate the callee's.
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 params args

                        ( substituted, ctx3 ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        inlined =
                            wrapInLetsForInline bindings substituted resultType
                    in
                    ( Just inlined
                    , recordInlineAt callRegion specId ctx3
                    )


{-| Returns the parameters, body and lambda-set member of a node that can be
inlined: the parameters and body of a `MonoDefine` closure, or the whole body
of any other `MonoDefine` with no parameters and no member. Any other node,
a tail function included, gives `Nothing`.
-}
getInlinableBody : MonoNode -> Maybe ( List ( Name, Mono.MonoType ), MonoExpr, Maybe Int )
getInlinableBody node =
    case node of
        MonoDefine expr _ ->
            case expr of
                MonoClosure info body _ ->
                    Just ( info.params, body, info.lssMember )

                _ ->
                    -- A value with no parameters.
                    Just ( [], expr, Nothing )

        MonoTailFunc _ _ _ ->
            -- Its MonoTailCalls mean something only inside a MonoTailFunc.
            Nothing

        _ ->
            Nothing


{-| Returns whether `expr` is a `MonoCase` at top level.
-}
isCase : MonoExpr -> Bool
isCase expr =
    case expr of
        MonoCase _ _ _ _ _ ->
            True

        _ ->
            False


{-| Returns the bindings of `params` to `args`, as `createBindings` makes them,
and none for a callee with no parameters.
-}
createBindingsForInline : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindingsForInline ctx params args =
    if List.isEmpty params then
        ( [], ctx )

    else
        createBindings ctx params args


{-| Returns `expr` with the bindings' parameters renamed, as `substituteAll`
does.
-}
substituteAllForInline : List Binding -> MonoExpr -> MonoExpr
substituteAllForInline =
    substituteAll


{-| Returns `body` under the bindings' `let`s, as `wrapInLets` does.
-}
wrapInLetsForInline : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLetsForInline =
    wrapInLets



-- ============================================================================
-- ====== LET SIMPLIFICATION ======
-- ============================================================================


{-| Returns a `let` chain with every bound expression and the final body
simplified, and its dead definitions dropped.

A definition that is not a closure is dead when no later definition and not the
final body uses it, and its bound expression is pure: `isPureExpr`, or
`isDroppableExpr` with `kernelFactsDce` on. A closure definition is dead when
no other definition of the chain and not the final body uses it: siblings can
refer to each other in both directions, but a closure's reference to itself
does not keep it. A local tail function is never dropped. Dropping one
definition can make another dead, so dropping repeats until nothing more is
dropped.

-}
simplifyLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spine0, finalBody0 ) =
            splitSpine chainExpr []

        ( spineSimplifiedRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( bound1, c1 ) =
                            simplifyLets c (getDefBound d)
                    in
                    ( ( setDefBound d bound1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spine0

        ( finalBody1, ctx2 ) =
            simplifyLets ctx1 finalBody0

        spineForward =
            List.reverse spineSimplifiedRev

        ctx2c =
            censusDeadDefs ctx2 spineForward finalBody1

        ( keptSpine, ctx3 ) =
            dropDeadDefs ctx2c spineForward finalBody1
    in
    ( List.foldr (\( d, t ) acc -> MonoLet d acc t) finalBody1 keptSpine, ctx3 )


{-| Returns `ctx` with the dead definitions of a chain counted, before any is
dropped.

Every `MonoDef` that no later definition and not the final body uses is counted
in `deadLets`, closures included. One bound to a bare kernel reference is also
counted in `deadBareKernelVar`, and one bound to a call of a kernel whose
`KernelFacts` row is droppable in `deadDroppableKernelLets`, whatever its
arguments, so that count can exceed what is dropped. Definitions that become
dead only after a drop are not seen. This runs each time the chain is
simplified, so a dead definition that is kept is counted again every round.

-}
censusDeadDefs : RewriteCtx -> List ( Mono.MonoDef, Mono.MonoType ) -> MonoExpr -> RewriteCtx
censusDeadDefs ctx spine finalBody =
    let
        usesInDefs : Name -> List ( Mono.MonoDef, Mono.MonoType ) -> Int
        usesInDefs name defs =
            List.foldl (\( d, _ ) n -> n + countUsagesInDef name d) 0 defs

        classify ( d, _ ) ( rest, m ) =
            case d of
                Mono.MonoTailDef _ _ _ ->
                    ( List.drop 1 rest, m )

                Mono.MonoDef _ _ ->
                    let
                        laterUses =
                            usesInDefs (getDefName d) rest
                                + countUsages (getDefName d) finalBody
                    in
                    if laterUses /= 0 then
                        ( List.drop 1 rest, m )

                    else
                        ( List.drop 1 rest
                        , case getDefBound d of
                            MonoVarKernel _ _ _ _ _ ->
                                { m
                                    | deadLets = m.deadLets + 1
                                    , deadBareKernelVar = m.deadBareKernelVar + 1
                                }

                            MonoCall _ (MonoVarKernel _ prefix home name _) _ _ _ ->
                                { m
                                    | deadLets = m.deadLets + 1
                                    , deadDroppableKernelLets =
                                        if KernelFacts.droppableFor ( prefix, home, name ) then
                                            m.deadDroppableKernelLets + 1

                                        else
                                            m.deadDroppableKernelLets
                                }

                            _ ->
                                { m | deadLets = m.deadLets + 1 }
                        )

        ( _, metrics1 ) =
            List.foldl classify ( List.drop 1 spine, ctx.metrics ) spine
    in
    { ctx | metrics = metrics1 }


{-| Returns the definitions of `spine` that are not dead, as
`simplifyLetChain` describes, dropping in passes until a pass drops nothing.
-}
dropDeadDefs : RewriteCtx -> List ( Mono.MonoDef, Mono.MonoType ) -> MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), RewriteCtx )
dropDeadDefs ctx spine finalBody =
    let
        usesInDefs : Name -> List ( Mono.MonoDef, Mono.MonoType ) -> Int
        usesInDefs name defs =
            List.foldl (\( d, _ ) n -> n + countUsagesInDef name d) 0 defs

        go earlierRev remaining c anyDropped =
            case remaining of
                [] ->
                    ( List.reverse earlierRev, c, anyDropped )

                (( d, _ ) as entry) :: rest ->
                    let
                        keep () =
                            go (entry :: earlierRev) rest c anyDropped

                        name =
                            getDefName d

                        bound =
                            getDefBound d
                    in
                    case d of
                        Mono.MonoDef _ _ ->
                            let
                                laterUses =
                                    usesInDefs name rest + countUsages name finalBody
                            in
                            if isClosure bound then
                                if laterUses == 0 && usesInDefs name earlierRev == 0 then
                                    go earlierRev rest (bumpClosureDCE c) True

                                else
                                    keep ()

                            else if
                                laterUses
                                    == 0
                                    && (if c.kernelFactsDce then
                                            isDroppableExpr bound

                                        else
                                            isPureExpr bound
                                       )
                            then
                                go earlierRev rest (bumpKernelDCE c bound) True

                            else
                                keep ()

                        Mono.MonoTailDef _ _ _ ->
                            keep ()

        ( kept, ctxOut, dropped ) =
            go [] spine ctx False
    in
    if dropped then
        dropDeadDefs ctxOut kept finalBody

    else
        ( kept, ctxOut )


{-| Returns `expr` with the dead definitions dropped from every `let` chain in
it, at every depth (`simplifyLetChain`).
-}
simplifyLets : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLets ctx expr =
    case expr of
        MonoLet _ _ _ ->
            -- A chain is simplified as a whole, so that dead-closure removal
            -- sees references between siblings in both directions.
            simplifyLetChain ctx expr

        MonoCall region func args resultType callInfo ->
            let
                ( simplifiedFunc, ctx1 ) =
                    simplifyLets ctx func

                ( simplifiedArgs, ctx2 ) =
                    simplifyLetsExprs ctx1 args
            in
            ( MonoCall region simplifiedFunc simplifiedArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( simplifiedCaptures, ctx1 ) =
                    simplifyLetsCaptures ctx info.captures

                ( simplifiedBody, ctx2 ) =
                    simplifyLets ctx1 body
            in
            ( MonoClosure { info | captures = simplifiedCaptures } simplifiedBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoList region simplifiedItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( simplifiedBranches, ctx1 ) =
                    simplifyLetsBranches ctx branches

                ( simplifiedFinal, ctx2 ) =
                    simplifyLets ctx1 final
            in
            ( MonoIf simplifiedBranches simplifiedFinal resultType, ctx2 )

        MonoDestruct destructor inner resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoDestruct destructor simplifiedInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( simplifiedDecider, ctx1 ) =
                    simplifyLetsDecider ctx decider

                ( simplifiedBranches, ctx2 ) =
                    simplifyLetsCaseBranches ctx1 branches
            in
            ( MonoCase scrutName scrutType simplifiedDecider simplifiedBranches resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( simplifiedFields, ctx1 ) =
                    simplifyLetsNamedFields ctx fields
            in
            ( MonoRecordCreate simplifiedFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoRecordAccess simplifiedInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner

                ( simplifiedUpdates, ctx2 ) =
                    simplifyLetsNamedFields ctx1 updates
            in
            ( MonoRecordUpdate simplifiedInner simplifiedUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoTupleCreate region simplifiedItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            let
                ( simplifiedArgs, ctx1 ) =
                    simplifyLetsTailCallArgs ctx args
            in
            ( MonoTailCall name simplifiedArgs resultType, ctx1 )

        _ ->
            ( expr, ctx )


{-| Returns each expression of a list with `simplifyLets` applied, in order,
threading the context.
-}
simplifyLetsExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
simplifyLetsExprs ctx exprs =
    let
        ( revExprs, finalCtx ) =
            List.foldl
                (\expr ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( simplified :: acc, newCtx )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, finalCtx )


{-| Returns each captured value of a closure with `simplifyLets` applied,
threading the context.
-}
simplifyLetsCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
simplifyLetsCaptures ctx captures =
    let
        ( revCaptures, finalCtx ) =
            List.foldl
                (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified, isUnboxed ) :: acc, newCtx )
                )
                ( [], ctx )
                captures
    in
    ( List.reverse revCaptures, finalCtx )


{-| Returns each condition and branch of an `if` with `simplifyLets` applied,
threading the context.
-}
simplifyLetsBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
simplifyLetsBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( cond, body ) ( acc, accCtx ) ->
                    let
                        ( simplifiedCond, ctx1 ) =
                            simplifyLets accCtx cond

                        ( simplifiedBody, ctx2 ) =
                            simplifyLets ctx1 body
                    in
                    ( ( simplifiedCond, simplifiedBody ) :: acc, ctx2 )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


{-| Returns each jump branch of a case with `simplifyLets` applied, threading
the context.
-}
simplifyLetsCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
simplifyLetsCaseBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( idx, body ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx body
                    in
                    ( ( idx, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


{-| Returns a decision tree with `simplifyLets` applied to every `Inline` leaf.
-}
simplifyLetsDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
simplifyLetsDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( simplified, ctx1 ) =
                            simplifyLets ctx expr
                    in
                    ( Mono.Leaf (Mono.Inline simplified), ctx1 )

                Mono.Jump _ ->
                    ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( simplifiedSuccess, ctx1 ) =
                    simplifyLetsDecider ctx success

                ( simplifiedFailure, ctx2 ) =
                    simplifyLetsDecider ctx1 failure
            in
            ( Mono.Chain testChain simplifiedSuccess simplifiedFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( revEdges, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( simplified, newCtx ) =
                                    simplifyLetsDecider accCtx d
                            in
                            ( ( test, simplified ) :: acc, newCtx )
                        )
                        ( [], ctx )
                        edges

                simplifiedEdges =
                    List.reverse revEdges

                ( simplifiedFallback, ctx2 ) =
                    simplifyLetsDecider ctx1 fallback
            in
            ( Mono.FanOut path simplifiedEdges simplifiedFallback, ctx2 )


{-| Returns each field value with `simplifyLets` applied, threading the
context.
-}
simplifyLetsNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsNamedFields ctx fields =
    let
        ( revFields, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                fields
    in
    ( List.reverse revFields, finalCtx )


{-| Returns each argument of a tail call with `simplifyLets` applied,
threading the context.
-}
simplifyLetsTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsTailCallArgs ctx args =
    let
        ( revArgs, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                args
    in
    ( List.reverse revArgs, finalCtx )


{-| Returns a `let` definition's bound expression.
-}
getDefBound : Mono.MonoDef -> MonoExpr
getDefBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


{-| Returns a `let` definition with its bound expression replaced.
-}
setDefBound : Mono.MonoDef -> MonoExpr -> Mono.MonoDef
setDefBound def newBound =
    case def of
        Mono.MonoDef name _ ->
            Mono.MonoDef name newBound

        Mono.MonoTailDef name params _ ->
            Mono.MonoTailDef name params newBound


{-| Returns whether `expr` is a closure literal.
-}
isClosure : MonoExpr -> Bool
isClosure expr =
    case expr of
        MonoClosure _ _ _ ->
            True

        _ ->
            False


{-| Returns whether evaluating `expr` can be left out or moved without changing
what the program does. It cannot when `expr` contains, outside any closure, a
call, a tail call or a bare kernel reference; a closure counts as pure, since
building it runs nothing. This is the test for moving the arguments of a
forwarded partial call, and for dropping a dead definition with
`kernelFactsDce` off.
-}
isPureExpr : MonoExpr -> Bool
isPureExpr =
    isPureExprGen False


{-| Returns whether a dead definition bound to `expr` can be dropped: as
`isPureExpr`, but also accepting a call of a kernel whose `KernelFacts` row is
droppable, with no more arguments than the kernel's flat arity and pure
arguments.
-}
isDroppableExpr : MonoExpr -> Bool
isDroppableExpr =
    isPureExprGen True


{-| Returns `isPureExpr` of `expr`, or `isDroppableExpr` when `kDrop` is set.
-}
isPureExprGen : Bool -> MonoExpr -> Bool
isPureExprGen kDrop expr =
    case expr of
        MonoLiteral _ _ ->
            True

        MonoVarLocal _ _ ->
            True

        MonoVarGlobal _ _ _ ->
            True

        MonoVarKernel _ _ _ _ _ ->
            -- Treated as impure, so that no unaudited kernel constant is dropped.
            False

        MonoUnit ->
            True

        MonoAccessorValue _ _ _ ->
            True

        MonoList _ items _ ->
            List.all (isPureExprGen kDrop) items

        MonoClosure _ _ _ ->
            -- Closure creation is pure (evaluation is not)
            True

        MonoCall _ callee args _ _ ->
            case ( kDrop, callee ) of
                ( True, MonoVarKernel _ prefix home name kernelType ) ->
                    -- No separate check for kernels that call back into Elm:
                    -- `droppable` needs `cseSafe`, which the KernelFacts
                    -- validation rules require to exclude call-backs. Over-
                    -- application is refused, since the row says nothing about
                    -- applying the result; a partial call only builds a PAP.
                    (case KernelFacts.lookup ( prefix, home, name ) of
                        Just facts ->
                            KernelFacts.droppable facts

                        Nothing ->
                            False
                    )
                        && (List.length args <= flatArrowArity kernelType)
                        && List.all (isPureExprGen kDrop) args

                _ ->
                    False

        MonoTailCall _ _ _ ->
            False

        MonoIf branches final _ ->
            List.all (\( c, t ) -> isPureExprGen kDrop c && isPureExprGen kDrop t) branches
                && isPureExprGen kDrop final

        MonoLet def body _ ->
            isPureExprDefGen kDrop def && isPureExprGen kDrop body

        MonoDestruct _ inner _ ->
            isPureExprGen kDrop inner

        MonoCase _ _ decider branches _ ->
            isPureDeciderGen kDrop decider
                && List.all (\( _, e ) -> isPureExprGen kDrop e) branches

        MonoRecordCreate fields _ ->
            List.all (\( _, e ) -> isPureExprGen kDrop e) fields

        MonoRecordAccess inner _ _ ->
            isPureExprGen kDrop inner

        MonoRecordUpdate inner updates _ ->
            isPureExprGen kDrop inner
                && List.all (\( _, e ) -> isPureExprGen kDrop e) updates

        MonoTupleCreate _ items _ ->
            List.all (isPureExprGen kDrop) items


{-| Returns `isPureExprGen` of a `let` definition's bound expression.
-}
isPureExprDefGen : Bool -> Mono.MonoDef -> Bool
isPureExprDefGen kDrop def =
    case def of
        Mono.MonoDef _ bound ->
            isPureExprGen kDrop bound

        Mono.MonoTailDef _ _ bound ->
            isPureExprGen kDrop bound


{-| Returns whether every `Inline` leaf of a decision tree is pure under
`isPureExprGen`. A `Jump` leaf counts as pure; its branch is in the case's jump
list.
-}
isPureDeciderGen : Bool -> Mono.Decider Mono.MonoChoice -> Bool
isPureDeciderGen kDrop decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    isPureExprGen kDrop expr

                Mono.Jump _ ->
                    True

        Mono.Chain _ success failure ->
            isPureDeciderGen kDrop success && isPureDeciderGen kDrop failure

        Mono.FanOut _ tests fallback ->
            List.all (\( _, d ) -> isPureDeciderGen kDrop d) tests
                && isPureDeciderGen kDrop fallback


{-| Returns how many times `expr` refers to the local `name`: as a variable, as
a case's root, as the root of a destructuring path, or as the callee of a tail
call.

Inside a closure with a parameter `name` only the captures are counted, inside
a `let` that defines `name` only its definition, and inside a local tail
function with a parameter `name` nothing. The roots of decision-tree paths are
not counted.

-}
countUsages : Name -> MonoExpr -> Int
countUsages name expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                1

            else
                0

        MonoLiteral _ _ ->
            0

        MonoVarGlobal _ _ _ ->
            0

        MonoVarKernel _ _ _ _ _ ->
            0

        MonoUnit ->
            0

        MonoAccessorValue _ _ _ ->
            0

        MonoList _ items _ ->
            sumBy (countUsages name) items

        MonoClosure info body _ ->
            -- Don't count if shadowed by param
            if List.any (\( n, _ ) -> n == name) info.params then
                sumBy (\( _, e, _ ) -> countUsages name e) info.captures

            else
                sumBy (\( _, e, _ ) -> countUsages name e) info.captures
                    + countUsages name body

        MonoCall _ func args _ _ ->
            countUsages name func + sumBy (countUsages name) args

        MonoTailCall funcName args _ ->
            (if funcName == name then
                1

             else
                0
            )
                + sumBy (\( _, e ) -> countUsages name e) args

        MonoIf branches final _ ->
            sumBy (\( c, t ) -> countUsages name c + countUsages name t) branches
                + countUsages name final

        MonoLet def body _ ->
            let
                defName =
                    getDefName def

                boundUsages =
                    countUsagesInDef name def
            in
            if defName == name then
                boundUsages

            else
                boundUsages + countUsages name body

        MonoDestruct (Mono.MonoDestructor _ path _) inner _ ->
            countUsagesInPath name path + countUsages name inner

        MonoCase _ rootName decider branches _ ->
            let
                rootUsage =
                    if rootName == name then
                        1

                    else
                        0
            in
            rootUsage + countUsagesInDecider name decider + sumBy (\( _, e ) -> countUsages name e) branches

        MonoRecordCreate fields _ ->
            sumBy (\( _, e ) -> countUsages name e) fields

        MonoRecordAccess inner _ _ ->
            countUsages name inner

        MonoRecordUpdate inner updates _ ->
            countUsages name inner + sumBy (\( _, e ) -> countUsages name e) updates

        MonoTupleCreate _ items _ ->
            sumBy (countUsages name) items


{-| Returns `countUsages` of a `let` definition's bound expression, or 0 for a
local tail function with a parameter named `name`.
-}
countUsagesInDef : Name -> Mono.MonoDef -> Int
countUsagesInDef name def =
    case def of
        Mono.MonoDef _ bound ->
            countUsages name bound

        Mono.MonoTailDef _ params bound ->
            if List.any (\( n, _ ) -> n == name) params then
                0

            else
                countUsages name bound


{-| Returns 1 when the root of a destructuring path is `name`, and 0 otherwise.
-}
countUsagesInPath : Name -> Mono.MonoPath -> Int
countUsagesInPath name path =
    case path of
        Mono.MonoRoot rootName _ ->
            if rootName == name then
                1

            else
                0

        Mono.MonoIndex _ _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoField _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoUnbox _ innerPath ->
            countUsagesInPath name innerPath


{-| Returns `countUsages` summed over the `Inline` leaves of a decision tree.
-}
countUsagesInDecider : Name -> Mono.Decider Mono.MonoChoice -> Int
countUsagesInDecider name decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    countUsages name expr

                Mono.Jump _ ->
                    0

        Mono.Chain _ success failure ->
            countUsagesInDecider name success + countUsagesInDecider name failure

        Mono.FanOut _ edges fallback ->
            sumBy (\( _, d ) -> countUsagesInDecider name d) edges
                + countUsagesInDecider name fallback


{-| Returns `expr` with each reference to the local `name` replaced by
`replacement`. A case root or path root is replaced only when `replacement` is
a variable. Nothing in this module calls it.
-}
inlineVar : Name -> MonoExpr -> MonoExpr -> MonoExpr
inlineVar name replacement expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                replacement

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (inlineVar name replacement) items) itemType

        MonoClosure info body closureType ->
            if List.any (\( n, _ ) -> n == name) info.params then
                expr

            else
                let
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) -> ( n, inlineVar name replacement e, isUnboxed ))
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (inlineVar name replacement body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (inlineVar name replacement func)
                (List.map (inlineVar name replacement) args)
                resultType
                callInfo

        MonoTailCall n args resultType ->
            MonoTailCall n
                (List.map (\( argName, e ) -> ( argName, inlineVar name replacement e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( inlineVar name replacement c, inlineVar name replacement t )) branches)
                (inlineVar name replacement final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == name then
                MonoLet (inlineVarInDef name replacement def) body resultType

            else
                MonoLet (inlineVarInDef name replacement def) (inlineVar name replacement body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                newPath =
                    inlineVarInPath name replacement path

                newInner =
                    if destructName == name then
                        inner

                    else
                        inlineVar name replacement inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase scrutName rootName decider branches resultType ->
            let
                newRootName =
                    if rootName == name then
                        case replacement of
                            MonoVarLocal newName_ _ ->
                                newName_

                            _ ->
                                rootName

                    else
                        rootName
            in
            MonoCase scrutName
                newRootName
                (inlineVarInDecider name replacement decider)
                (List.map (\( idx, e ) -> ( idx, inlineVar name replacement e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (inlineVar name replacement inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (inlineVar name replacement inner)
                (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (inlineVar name replacement) items) tupleType


{-| Returns a `let` definition with `inlineVar` applied to its bound
expression, unless it is a local tail function with a parameter named `name`.
-}
inlineVarInDef : Name -> MonoExpr -> Mono.MonoDef -> Mono.MonoDef
inlineVarInDef name replacement def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (inlineVar name replacement bound)

        Mono.MonoTailDef n params bound ->
            if List.any (\( pn, _ ) -> pn == name) params then
                def

            else
                Mono.MonoTailDef n params (inlineVar name replacement bound)


{-| Returns a destructuring path whose root is `name` re-rooted at
`replacement` when that is a variable, and otherwise unchanged.
-}
inlineVarInPath : Name -> MonoExpr -> Mono.MonoPath -> Mono.MonoPath
inlineVarInPath name replacement path =
    case path of
        Mono.MonoRoot rootName rootType ->
            if rootName == name then
                case replacement of
                    MonoVarLocal newName _ ->
                        Mono.MonoRoot newName rootType

                    _ ->
                        -- Can't inline a non-variable expression into a path root
                        path

            else
                path

        Mono.MonoIndex idx container resultType innerPath ->
            Mono.MonoIndex idx container resultType (inlineVarInPath name replacement innerPath)

        Mono.MonoField fieldIdx resultType innerPath ->
            Mono.MonoField fieldIdx resultType (inlineVarInPath name replacement innerPath)

        Mono.MonoUnbox resultType innerPath ->
            Mono.MonoUnbox resultType (inlineVarInPath name replacement innerPath)


{-| Returns a decision-tree path whose root is `name` re-rooted at
`replacement` when that is a variable, and otherwise unchanged.
-}
inlineVarInDtPath : Name -> MonoExpr -> Mono.MonoDtPath -> Mono.MonoDtPath
inlineVarInDtPath name replacement dtPath =
    case dtPath of
        Mono.DtRoot rootName ty ->
            if rootName == name then
                case replacement of
                    MonoVarLocal newName _ ->
                        Mono.DtRoot newName ty

                    _ ->
                        dtPath

            else
                dtPath

        Mono.DtIndex idx kind resultTy inner ->
            Mono.DtIndex idx kind resultTy (inlineVarInDtPath name replacement inner)

        Mono.DtUnbox resultTy inner ->
            Mono.DtUnbox resultTy (inlineVarInDtPath name replacement inner)


{-| Returns a decision tree with `inlineVar` applied to every `Inline` leaf and
every test path.
-}
inlineVarInDecider : Name -> MonoExpr -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
inlineVarInDecider name replacement decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    Mono.Leaf (Mono.Inline (inlineVar name replacement expr))

                Mono.Jump _ ->
                    decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( inlineVarInDtPath name replacement dtPath, test )
                    )
                    testChain
                )
                (inlineVarInDecider name replacement success)
                (inlineVarInDecider name replacement failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (inlineVarInDtPath name replacement path)
                (List.map (\( test, d ) -> ( test, inlineVarInDecider name replacement d )) edges)
                (inlineVarInDecider name replacement fallback)


{-| Returns, in ascending order, the lambda uid of each residual closure
recorded in `cleared` (a `clearedMembers` table) that `graph` holds in tail
position: as the value a node's or closure's body returns. A uid appears once
for each such closure found.

Only residuals whose source closure had a lambda-set member are looked for, and
the walk is the one `reshapeCensus` describes.

-}
reshapeReturnedUids : Dict String Int -> Mono.MonoGraph -> List Int
reshapeReturnedUids cleared graph =
    reshapeCensusGo cleared graph
        |> Tuple.second
        |> List.sort


{-| Returns the residual closures recorded in `cleared` (a `clearedMembers`
table) that `graph` still holds, counted by where each is:

  - `appliedSameFn`: the callee of a call;
  - `returned`: in tail position of a node's or closure's body, so that it is
    the value returned;
  - `storedOrMulti`: anywhere else, such as an argument, an element of data,
    a `let`'s bound expression, or an `if` condition.

Only residuals whose source closure had a lambda-set member are looked for:
the `RESHAPES|` keys are skipped. The bodies of `MonoDefine` and
`MonoTailFunc` nodes are walked, but not the expressions closures capture, nor
the inside of a residual found as a callee.

-}
reshapeCensus : Dict String Int -> Mono.MonoGraph -> Dict String Int
reshapeCensus cleared graph =
    Tuple.first (reshapeCensusGo cleared graph)


{-| Returns the counts `reshapeCensus` gives and the uids
`reshapeReturnedUids` gives, from one walk.
-}
reshapeCensusGo : Dict String Int -> Mono.MonoGraph -> ( Dict String Int, List Int )
reshapeCensusGo cleared (Mono.MonoGraph record) =
    let
        uids =
            Dict.foldl
                (\k _ acc ->
                    if String.startsWith "RESHAPES|" k then
                        acc

                    else
                        case String.split "|" k of
                            u :: _ ->
                                case String.toInt u of
                                    Just n ->
                                        Set.insert n acc

                                    Nothing ->
                                        acc

                            [] ->
                                acc
                )
                Set.empty
                cleared

        residualUid e =
            case e of
                MonoClosure info _ _ ->
                    if Set.member (lambdaUid info.lambdaId) uids then
                        Just (lambdaUid info.lambdaId)

                    else
                        Nothing

                _ ->
                    Nothing

        bump k ( d, us ) =
            ( Dict.update k (\v -> Just (1 + Maybe.withDefault 0 v)) d, us )

        -- A `returned` residual also has its uid recorded.
        bumpAt tail uid acc =
            case bump (posKey tail) acc of
                ( d, us ) ->
                    ( d
                    , if tail then
                        uid :: us

                      else
                        us
                    )

        goDef def acc =
            case def of
                Mono.MonoDef _ bound ->
                    go False bound acc

                Mono.MonoTailDef _ _ bound ->
                    go False bound acc

        goDecider tail d acc =
            case d of
                Mono.Leaf (Mono.Inline e) ->
                    go tail e acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ ok no ->
                    goDecider tail no (goDecider tail ok acc)

                Mono.FanOut _ tests fb ->
                    goDecider tail
                        fb
                        (List.foldl (\( _, dd ) a -> goDecider tail dd a) acc tests)

        -- `tail`: this expression's value is the value of the enclosing node
        -- or closure body.
        go tail e acc =
            case e of
                MonoCall _ func args _ _ ->
                    let
                        accF =
                            case residualUid func of
                                Just _ ->
                                    bump "appliedSameFn" acc

                                Nothing ->
                                    go False func acc
                    in
                    List.foldl (go False) accF args

                MonoClosure info body _ ->
                    go True
                        body
                        (if Set.member (lambdaUid info.lambdaId) uids then
                            bumpAt tail (lambdaUid info.lambdaId) acc

                         else
                            acc
                        )

                MonoLet def body _ ->
                    go tail body (goDef def acc)

                MonoDestruct _ inner _ ->
                    go tail inner acc

                MonoIf branches final _ ->
                    go tail
                        final
                        (List.foldl (\( c, t ) a -> go tail t (go False c a)) acc branches)

                MonoCase _ _ decider branches _ ->
                    List.foldl (\( _, b ) a -> go tail b a) (goDecider tail decider acc) branches

                MonoList _ items _ ->
                    List.foldl (go False) acc items

                MonoTupleCreate _ items _ ->
                    List.foldl (go False) acc items

                MonoRecordCreate fields _ ->
                    List.foldl (\( _, v ) a -> go False v a) acc fields

                MonoRecordAccess inner _ _ ->
                    go False inner acc

                MonoRecordUpdate inner ups _ ->
                    List.foldl (\( _, v ) a -> go False v a) (go False inner acc) ups

                MonoTailCall _ args _ ->
                    List.foldl (\( _, v ) a -> go False v a) acc args

                _ ->
                    acc

        posKey tail =
            if tail then
                "returned"

            else
                "storedOrMulti"
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (MonoDefine expr _) ->
                    go True expr acc

                Just (MonoTailFunc _ expr _) ->
                    go True expr acc

                _ ->
                    acc
        )
        ( Dict.empty, [] )
        record.nodes
