module Compiler.GlobalOpt.CafHoist exposing
    ( run, Stats, emptyStats, renderStats
    , zeroRegions, kindTagOf, typeTouchesBytes
    )

{-| A function body that evaluates the same closed expression on every call
does the same work every time, and this pass moves such an expression out so
that it is evaluated once.

A _closed_ subexpression is one that mentions no local variable bound outside
itself, so its value does not depend on where it sits. A _CAF_ (constant
applicative form) is a nullary top-level `MonoDefine`, a value with no
arguments, which the back end evaluates once and keeps. To _hoist_ a closed
subexpression is to mint a new CAF whose body is that subexpression, verbatim,
and to replace the subexpression where it stood with a `MonoVarGlobal`
referring to the new spec. Everything attached to the moved nodes, such as a
call's `CallInfo`, moves with them unchanged.

`run` is the pass. It looks inside the bodies of top-level closures, their
capture expressions, and the bodies of top-level tail functions; the bodies of
other nodes are left alone. Each body is handled in two walks.

The first walk, bottom-up, finds the body's _eligible-maximal candidates_. A
node is a candidate when it is closed, is one of the kinds worth moving (a
call, `let`, `if`, `case`, destructuring, record creation or update, tuple, or
non-empty list), has at least `minNodes` nodes, and passes the exclusions
below. A candidate is taken whole and nothing inside it is taken as well. A
closed node that fails a test is not taken, but the candidates found inside it
still are.

The exclusions are these. A result of scalar type (`Int`, `Float`, `Char`, or
a `number` variable) is not hoisted. Neither is a result of function type,
because a call's `CallInfo` describes the shape of its callee expression, and
replacing that expression with a global would leave the `CallInfo` describing
a shape that is no longer there. A subtree that references a kernel whose home
is `Debug` is not hoisted: moving a `Debug` call would change how many times
it logs. The test looks only at kernel references, so a subtree that calls a
global function that logs can still be hoisted. A result whose type contains a type from the
`elm/bytes` package, other than inside a function type, is not hoisted either,
and nor is a call whose callee is a `Bytes` kernel.

The second walk, top-down, replaces every subtree equal under `==` to one of
the body's candidates and does not look inside a subtree it has replaced.

Candidates that contain no closure are shared across the whole graph: one
whose body, with every source region set to `A.zero`, equals that of a spec
already minted at the same type reuses that spec instead of minting another.
Only regions are erased, so two copies that differ only in the names of their
local variables are not shared. A candidate that contains a closure gets a
spec of its own at every site, because a closure carries a `lambdaId`
identifying it. `zeroRegions` and `kindTagOf`, which build the key for this
sharing, are exposed for the other passes that compare expressions the same
way.

Once `maxHoists` specs have been minted, a candidate that would need a new
spec is left where it is. Minted specs are appended after the existing nodes,
named `hoist_0`, `hoist_1`, ... in the module `CafHoist` of the package
`eco/hoisted`, in the order they were minted. Bodies are visited in SpecId
order, so the result is deterministic.

@docs run, Stats, emptyStats, renderStats
@docs zeroRegions, kindTagOf, typeTouchesBytes

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Set exposing (Set)


{-| Counts describing what one `run` did.

`sites` is the number of subexpressions replaced, which is `hoisted` (specs
minted) plus `deduped` (sites given a spec minted earlier). `skippedBudget`
counts sites left in place because `maxHoists` had been reached.

The other `skipped` counts are of closed subexpressions of a candidate kind and
of at least `minNodes` nodes that an exclusion rejected. A subexpression is
counted under the first exclusion that rejects it, tried in the order scalar,
function type, `Debug`, bytes, and one below the size floor is counted
nowhere.

-}
type alias Stats =
    { hoisted : Int
    , sites : Int
    , deduped : Int
    , skippedBudget : Int
    , skippedBytes : Int
    , skippedDebug : Int
    , skippedScalar : Int
    , skippedFnType : Int
    , origNodes : Int -- total size, in nodes, of the subexpressions replaced
    }


{-| Statistics with every count at zero.
-}
emptyStats : Stats
emptyStats =
    { hoisted = 0
    , sites = 0
    , deduped = 0
    , skippedBudget = 0
    , skippedBytes = 0
    , skippedDebug = 0
    , skippedScalar = 0
    , skippedFnType = 0
    , origNodes = 0
    }


{-| Returns `s` as one line of `name=value` pairs, beginning `caf-hoist:`.
-}
renderStats : Stats -> String
renderStats s =
    "caf-hoist: hoisted="
        ++ String.fromInt s.hoisted
        ++ " sites="
        ++ String.fromInt s.sites
        ++ " deduped="
        ++ String.fromInt s.deduped
        ++ " skippedBudget="
        ++ String.fromInt s.skippedBudget
        ++ " skippedBytes="
        ++ String.fromInt s.skippedBytes
        ++ " skippedDebug="
        ++ String.fromInt s.skippedDebug
        ++ " skippedScalar="
        ++ String.fromInt s.skippedScalar
        ++ " skippedFnType="
        ++ String.fromInt s.skippedFnType
        ++ " origNodes="
        ++ String.fromInt s.origNodes


{-| What the first walk has learned about one subtree.

`free` holds the local names the subtree uses without binding them; the
subtree is closed when it is empty. `size` is the number of nodes in the
subtree. `hasDebug` is set when it references a `Debug` kernel.

-}
type alias Info =
    { free : Set Name.Name
    , size : Int
    , hasClosure : Bool
    , hasDebug : Bool
    }


{-| The facts for a subtree that uses no local name, has no nodes counted yet,
and contains no closure and no `Debug` kernel.
-}
leafInfo : Info
leafInfo =
    { free = Set.empty, size = 0, hasClosure = False, hasDebug = False }


{-| Combines the facts of two sibling subtrees: the union of their free names,
the sum of their sizes, and either one's flags.
-}
mergeInfo : Info -> Info -> Info
mergeInfo a b =
    { free = Set.union a.free b.free
    , size = a.size + b.size
    , hasClosure = a.hasClosure || b.hasClosure
    , hasDebug = a.hasDebug || b.hasDebug
    }


{-| A subexpression chosen for hoisting, with its size in nodes and whether it
contains a closure, which decides whether it may share a spec.
-}
type alias Candidate =
    { expr : Mono.MonoExpr
    , size : Int
    , hasClosure : Bool
    }


{-| The state carried through the whole graph by `run`.

`nextId` is the SpecId the next minted spec receives. `minted` holds the
bodies and types of the specs minted so far, the most recent first. `dedupe`
finds the spec already minted for a closure-free candidate: it is keyed by
`kindTagOf` and then by type, and holds each region-zeroed body with its
SpecId.

-}
type alias Ctx =
    { nextId : Int
    , minted : List ( Mono.MonoExpr, Mono.MonoType )
    , dedupe : Dict String (Mono.SpecMap (List ( Mono.MonoExpr, Int )))
    , stats : Stats
    , maxHoists : Int
    }



-- ====== PUBLIC ENTRY ======


{-| Returns the graph with its eligible-maximal candidates hoisted into new
CAF specs, as the module documentation describes, and counts of what was done.

The graph's registry must have `nextId` equal to the number of nodes and a
`reverseMapping` of the same length, because new specs are numbered from
`nextId` and appended to both; otherwise this crashes. The new specs get
entries in `nodes` and `reverseMapping` only: the forward `mapping`,
`countByGlobal` and `callEdges` are not extended.

-}
run : { minNodes : Int, maxHoists : Int } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run cfg (Mono.MonoGraph g) =
    let
        ctx0 : Ctx
        ctx0 =
            { nextId = g.registry.nextId
            , minted = []
            , dedupe = Dict.empty
            , stats = emptyStats
            , maxHoists = cfg.maxHoists
            }

        ( newNodes, ctxFinal ) =
            Array.foldl
                (\maybeNode ( accNodes, accCtx ) ->
                    case maybeNode of
                        Just node ->
                            let
                                ( node1, accCtx1 ) =
                                    hoistNode cfg.minNodes accCtx node
                            in
                            ( Array.push (Just node1) accNodes, accCtx1 )

                        Nothing ->
                            ( Array.push Nothing accNodes, accCtx )
                )
                ( Array.empty, ctx0 )
                g.nodes

        mintedInOrder =
            List.reverse ctxFinal.minted

        nodesWithHoists =
            List.foldl
                (\( expr, ty ) acc -> Array.push (Just (Mono.MonoDefine expr ty)) acc)
                newNodes
                mintedInOrder

        ( reverseMappingWithHoists, _ ) =
            List.foldl
                (\( _, ty ) ( acc, ordinal ) ->
                    ( Array.push
                        (Just
                            ( Mono.Global
                                (ModuleName.Canonical ( "eco", "hoisted" ) "CafHoist")
                                ("hoist_" ++ String.fromInt ordinal)
                            , ty
                            )
                        )
                        acc
                    , ordinal + 1
                    )
                )
                ( g.registry.reverseMapping, 0 )
                mintedInOrder

        registry1 =
            { nextId = ctxFinal.nextId
            , mapping = g.registry.mapping
            , reverseMapping = reverseMappingWithHoists
            , countByGlobal = g.registry.countByGlobal
            }
    in
    ( Mono.MonoGraph
        { g
            | nodes = nodesWithHoists
            , registry = registry1
        }
    , ctxFinal.stats
    )


{-| Returns `node` with candidates hoisted from the body and capture
expressions of a closure-valued `MonoDefine`, or from the body of a
`MonoTailFunc`. Any other node is returned unchanged; a `MonoDefine` whose body
is not a closure is already a CAF and is evaluated once anyway.
-}
hoistNode : Int -> Ctx -> Mono.MonoNode -> ( Mono.MonoNode, Ctx )
hoistNode minNodes ctx node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure info body cty) ty ->
            let
                ( body1, ctx1 ) =
                    hoistBody minNodes ctx body

                ( capturesRev, ctx2 ) =
                    List.foldl
                        (\( n, ce, b ) ( acc, c ) ->
                            let
                                ( ce1, c1 ) =
                                    hoistBody minNodes c ce
                            in
                            ( ( n, ce1, b ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        info.captures
            in
            ( Mono.MonoDefine
                (Mono.MonoClosure { info | captures = List.reverse capturesRev } body1 cty)
                ty
            , ctx2
            )

        Mono.MonoDefine _ _ ->
            ( node, ctx )

        Mono.MonoTailFunc params body ty ->
            let
                ( body1, ctx1 ) =
                    hoistBody minNodes ctx body
            in
            ( Mono.MonoTailFunc params body1 ty, ctx1 )

        _ ->
            ( node, ctx )


{-| Returns `body` with its eligible-maximal candidates replaced by references
to specs, except where the hoist budget leaves a candidate in place, finding
the candidates in one walk and replacing them in a second. A body with no
candidates is returned as it was.
-}
hoistBody : Int -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
hoistBody minNodes ctx body =
    let
        ( _, cands, ctx1 ) =
            collectExpr minNodes ctx body
    in
    if List.isEmpty cands then
        ( body, ctx1 )

    else
        replaceExpr cands ctx1 body



-- ====== PHASE 1: COLLECT (pure analysis; Ctx only for skip counters) ======


{-| Returns the facts about `expr`, its eligible-maximal candidates, and `ctx`
with the skip counts raised for any closed subexpression an exclusion
rejected.

If `expr` itself is a candidate it is the only one returned; otherwise the
candidates found among its children are returned.

-}
collectExpr : Int -> Ctx -> Mono.MonoExpr -> ( Info, List Candidate, Ctx )
collectExpr minNodes ctx expr =
    let
        ( innerInfo, childCands, ctx1 ) =
            collectChildren minNodes ctx expr

        info =
            { innerInfo | size = innerInfo.size + 1 }
    in
    if Set.isEmpty info.free && candidateKind expr then
        let
            ty =
                Mono.typeOf expr

            bump f =
                { ctx1 | stats = f ctx1.stats }
        in
        if info.size < minNodes then
            ( info, childCands, ctx1 )

        else if not (valueAbi ty) then
            ( info, childCands, bump (\s -> { s | skippedScalar = s.skippedScalar + 1 }) )

        else if isFnType ty then
            ( info, childCands, bump (\s -> { s | skippedFnType = s.skippedFnType + 1 }) )

        else if info.hasDebug then
            ( info, childCands, bump (\s -> { s | skippedDebug = s.skippedDebug + 1 }) )

        else if typeTouchesBytes ty || bytesHeaded expr then
            ( info, childCands, bump (\s -> { s | skippedBytes = s.skippedBytes + 1 }) )

        else
            ( info
            , [ { expr = expr, size = info.size, hasClosure = info.hasClosure } ]
            , ctx1
            )

    else
        ( info, childCands, ctx1 )


{-| Returns the combined facts and candidates of the children of `expr`, not
counting `expr` itself in the size.

A name bound inside `expr` (a closure's parameters and captures, a `let`, a
destructured name) is removed from its scope's free names. A tail call's own
function name, a destructuring's source variable, and both names of a `case`
are counted as free, so an expression containing them is closed only if an
enclosing binding inside the candidate binds them.

-}
collectChildren : Int -> Ctx -> Mono.MonoExpr -> ( Info, List Candidate, Ctx )
collectChildren minNodes ctx expr =
    let
        go =
            collectExpr minNodes

        goList c exprs =
            List.foldl
                (\e ( i, cs, cx ) ->
                    let
                        ( ei, ecs, cx1 ) =
                            go cx e
                    in
                    ( mergeInfo i ei, cs ++ ecs, cx1 )
                )
                ( leafInfo, [], c )
                exprs
    in
    case expr of
        Mono.MonoLiteral _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoVarLocal n _ ->
            ( { leafInfo | free = Set.singleton n }, [], ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoVarKernel _ _ home _ _ ->
            ( { leafInfo | hasDebug = home == "Debug" }, [], ctx )

        Mono.MonoUnit ->
            ( leafInfo, [], ctx )

        Mono.MonoAccessorValue _ _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoList _ items _ ->
            goList ctx items

        Mono.MonoClosure info body _ ->
            let
                ( capInfo, capCands, ctx1 ) =
                    goList ctx (List.map (\( _, ce, _ ) -> ce) info.captures)

                ( bodyInfo, bodyCands, ctx2 ) =
                    go ctx1 body

                bound =
                    Set.fromList
                        (List.map Tuple.first info.params
                            ++ List.map (\( n, _, _ ) -> n) info.captures
                        )

                merged =
                    mergeInfo capInfo { bodyInfo | free = Set.diff bodyInfo.free bound }
            in
            ( { merged | hasClosure = True }, capCands ++ bodyCands, ctx2 )

        Mono.MonoCall _ func args _ _ ->
            goList ctx (func :: args)

        Mono.MonoTailCall n args _ ->
            let
                ( i, cs, ctx1 ) =
                    goList ctx (List.map Tuple.second args)
            in
            ( { i | free = Set.insert n i.free }, cs, ctx1 )

        Mono.MonoIf branches final _ ->
            goList ctx
                (final :: List.concatMap (\( c, t ) -> [ c, t ]) branches)

        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef n bound ->
                    let
                        ( bi, bcs, ctx1 ) =
                            go ctx bound

                        ( boi, bocs, ctx2 ) =
                            go ctx1 body
                    in
                    ( mergeInfo bi { boi | free = Set.remove n boi.free }
                    , bcs ++ bocs
                    , ctx2
                    )

                Mono.MonoTailDef n params bound ->
                    let
                        ( bi, bcs, ctx1 ) =
                            go ctx bound

                        paramSet =
                            Set.insert n (Set.fromList (List.map Tuple.first params))

                        ( boi, bocs, ctx2 ) =
                            go ctx1 body
                    in
                    ( mergeInfo { bi | free = Set.diff bi.free paramSet }
                        { boi | free = Set.remove n boi.free }
                    , bcs ++ bocs
                    , ctx2
                    )

        Mono.MonoDestruct (Mono.MonoDestructor n path _) body _ ->
            let
                ( bi, bcs, ctx1 ) =
                    go ctx body
            in
            ( { bi | free = Set.insert (pathRoot path) (Set.remove n bi.free) }
            , bcs
            , ctx1
            )

        Mono.MonoCase s1 s2 decider branches _ ->
            let
                ( di, dcs, ctx1 ) =
                    collectDecider minNodes ctx decider

                ( bi, bcs, ctx2 ) =
                    goList ctx1 (List.map Tuple.second branches)

                merged =
                    mergeInfo di bi
            in
            ( { merged | free = Set.insert s1 (Set.insert s2 merged.free) }
            , dcs ++ bcs
            , ctx2
            )

        Mono.MonoRecordCreate fields _ ->
            goList ctx (List.map Tuple.second fields)

        Mono.MonoRecordAccess rec _ _ ->
            go ctx rec

        Mono.MonoRecordUpdate rec updates _ ->
            goList ctx (rec :: List.map Tuple.second updates)

        Mono.MonoTupleCreate _ items _ ->
            goList ctx items


{-| Returns the combined facts and candidates of a `case` decision tree: the
bodies held inline at its leaves, with the variable each test reads counted as
free. A `Jump` leaf contributes nothing, since the branch it names is walked
with the `case`'s branch list.
-}
collectDecider : Int -> Ctx -> Mono.Decider Mono.MonoChoice -> ( Info, List Candidate, Ctx )
collectDecider minNodes ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collectExpr minNodes ctx e

        Mono.Leaf (Mono.Jump _) ->
            ( leafInfo, [], ctx )

        Mono.Chain tests succ fail ->
            let
                ( si, scs, ctx1 ) =
                    collectDecider minNodes ctx succ

                ( fi, fcs, ctx2 ) =
                    collectDecider minNodes ctx1 fail

                testFree =
                    List.foldl (\( dtPath, _ ) acc -> Set.insert (dtRoot dtPath) acc)
                        Set.empty
                        tests

                merged =
                    mergeInfo si fi
            in
            ( { merged | free = Set.union testFree merged.free }, scs ++ fcs, ctx2 )

        Mono.FanOut dtPath edges fallback ->
            let
                ( ei, ecs, ctx1 ) =
                    List.foldl
                        (\( _, d ) ( i, cs, c ) ->
                            let
                                ( di, dcs, c1 ) =
                                    collectDecider minNodes c d
                            in
                            ( mergeInfo i di, cs ++ dcs, c1 )
                        )
                        ( leafInfo, [], ctx )
                        edges

                ( fi, fcs, ctx2 ) =
                    collectDecider minNodes ctx1 fallback

                merged =
                    mergeInfo ei fi
            in
            ( { merged | free = Set.insert (dtRoot dtPath) merged.free }
            , ecs ++ fcs
            , ctx2
            )



-- ====== PHASE 2: REPLACE (top-down; stop at a replaced site) ======


{-| Returns `expr` with every subtree equal to one of `cands` replaced by a
reference to a spec for it, unless the budget is spent and it is left as it
is, and `ctx` updated with any new spec. A matching subtree is not looked
inside.
-}
replaceExpr : List Candidate -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
replaceExpr cands ctx expr =
    case List.filter (\c -> c.expr == expr) cands of
        c :: _ ->
            mintOrDedupe ctx c

        [] ->
            replaceChildren cands ctx expr


{-| Returns the expression to stand in place of `cand`.

A candidate with no closure reuses a spec minted earlier for a body equal to it
once regions are zeroed, at the same type and under the same `kindTagOf`;
otherwise, or if it contains a closure, a new spec is minted for it, within the
budget.

-}
mintOrDedupe : Ctx -> Candidate -> ( Mono.MonoExpr, Ctx )
mintOrDedupe ctx cand =
    let
        ty =
            Mono.typeOf cand.expr
    in
    if cand.hasClosure then
        mintOrBudget ctx cand ty Nothing

    else
        let
            zeroed =
                zeroRegions cand.expr

            tag =
                kindTagOf cand.expr

            bucket =
                Dict.get tag ctx.dedupe
                    |> Maybe.andThen (Mono.specMapGet ty)
                    |> Maybe.withDefault []
        in
        case List.filter (\( z, _ ) -> z == zeroed) bucket of
            ( _, sid ) :: _ ->
                let
                    stats0 =
                        ctx.stats

                    stats1 =
                        { stats0
                            | sites = stats0.sites + 1
                            , deduped = stats0.deduped + 1
                            , origNodes = stats0.origNodes + cand.size
                        }
                in
                ( Mono.MonoVarGlobal A.zero sid ty, { ctx | stats = stats1 } )

            [] ->
                mintOrBudget ctx cand ty (Just ( tag, zeroed ))


{-| Returns a reference to a newly minted spec whose body is `cand`, of type
`ty`, or `cand` itself, unchanged, when `maxHoists` specs have already been
minted. `maybeKey`, the kind tag and region-zeroed body of a closure-free
candidate, records the new spec for later sites to reuse; `Nothing` records
nothing.
-}
mintOrBudget : Ctx -> Candidate -> Mono.MonoType -> Maybe ( String, Mono.MonoExpr ) -> ( Mono.MonoExpr, Ctx )
mintOrBudget ctx cand ty maybeKey =
    if ctx.stats.hoisted >= ctx.maxHoists then
        ( cand.expr
        , { ctx | stats = (\s -> { s | skippedBudget = s.skippedBudget + 1 }) ctx.stats }
        )

    else
        let
            sid =
                ctx.nextId

            stats0 =
                ctx.stats

            stats1 =
                { stats0
                    | hoisted = stats0.hoisted + 1
                    , sites = stats0.sites + 1
                    , origNodes = stats0.origNodes + cand.size
                }

            dedupe1 =
                case maybeKey of
                    Just ( tag, zeroed ) ->
                        let
                            inner =
                                Maybe.withDefault Mono.specMapEmpty (Dict.get tag ctx.dedupe)

                            prev =
                                Maybe.withDefault [] (Mono.specMapGet ty inner)
                        in
                        Dict.insert tag
                            (Mono.specMapInsert ty (( zeroed, sid ) :: prev) inner)
                            ctx.dedupe

                    Nothing ->
                        ctx.dedupe
        in
        ( Mono.MonoVarGlobal A.zero sid ty
        , { ctx
            | nextId = sid + 1
            , minted = ( cand.expr, ty ) :: ctx.minted
            , dedupe = dedupe1
            , stats = stats1
          }
        )


{-| Returns `expr` with `replaceExpr` applied to each of its children, threading
`ctx` through them in order.
-}
replaceChildren : List Candidate -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
replaceChildren cands ctx expr =
    let
        go =
            replaceExpr cands

        goList c exprs =
            let
                ( rev, c1 ) =
                    List.foldl
                        (\e ( acc, cx ) ->
                            let
                                ( e1, cx1 ) =
                                    go cx e
                            in
                            ( e1 :: acc, cx1 )
                        )
                        ( [], c )
                        exprs
            in
            ( List.reverse rev, c1 )
    in
    case expr of
        Mono.MonoLiteral _ _ ->
            ( expr, ctx )

        Mono.MonoVarLocal _ _ ->
            ( expr, ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        Mono.MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        Mono.MonoUnit ->
            ( expr, ctx )

        Mono.MonoAccessorValue _ _ _ ->
            ( expr, ctx )

        Mono.MonoList region items ty ->
            let
                ( items1, ctx1 ) =
                    goList ctx items
            in
            ( Mono.MonoList region items1 ty, ctx1 )

        Mono.MonoClosure info body ty ->
            let
                ( capturesRev, ctx1 ) =
                    List.foldl
                        (\( n, ce, b ) ( acc, c ) ->
                            let
                                ( ce1, c1 ) =
                                    go c ce
                            in
                            ( ( n, ce1, b ) :: acc, c1 )
                        )
                        ( [], ctx )
                        info.captures

                ( body1, ctx2 ) =
                    go ctx1 body
            in
            ( Mono.MonoClosure { info | captures = List.reverse capturesRev } body1 ty
            , ctx2
            )

        Mono.MonoCall region func args ty callInfo ->
            let
                ( func1, ctx1 ) =
                    go ctx func

                ( args1, ctx2 ) =
                    goList ctx1 args
            in
            ( Mono.MonoCall region func1 args1 ty callInfo, ctx2 )

        Mono.MonoTailCall n args ty ->
            let
                ( argsRev, ctx1 ) =
                    List.foldl
                        (\( an, ae ) ( acc, c ) ->
                            let
                                ( ae1, c1 ) =
                                    go c ae
                            in
                            ( ( an, ae1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
            in
            ( Mono.MonoTailCall n (List.reverse argsRev) ty, ctx1 )

        Mono.MonoIf branches final ty ->
            let
                ( branchesRev, ctx1 ) =
                    List.foldl
                        (\( c, t ) ( acc, cx ) ->
                            let
                                ( c1, cx1 ) =
                                    go cx c

                                ( t1, cx2 ) =
                                    go cx1 t
                            in
                            ( ( c1, t1 ) :: acc, cx2 )
                        )
                        ( [], ctx )
                        branches

                ( final1, ctx2 ) =
                    go ctx1 final
            in
            ( Mono.MonoIf (List.reverse branchesRev) final1 ty, ctx2 )

        Mono.MonoLet def body ty ->
            let
                ( def1, ctx1 ) =
                    case def of
                        Mono.MonoDef n bound ->
                            let
                                ( bound1, c1 ) =
                                    go ctx bound
                            in
                            ( Mono.MonoDef n bound1, c1 )

                        Mono.MonoTailDef n params bound ->
                            let
                                ( bound1, c1 ) =
                                    go ctx bound
                            in
                            ( Mono.MonoTailDef n params bound1, c1 )

                ( body1, ctx2 ) =
                    go ctx1 body
            in
            ( Mono.MonoLet def1 body1 ty, ctx2 )

        Mono.MonoDestruct d body ty ->
            let
                ( body1, ctx1 ) =
                    go ctx body
            in
            ( Mono.MonoDestruct d body1 ty, ctx1 )

        Mono.MonoCase s1 s2 decider branches ty ->
            let
                ( decider1, ctx1 ) =
                    replaceDecider cands ctx decider

                ( branchesRev, ctx2 ) =
                    List.foldl
                        (\( idx, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( idx, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        branches
            in
            ( Mono.MonoCase s1 s2 decider1 (List.reverse branchesRev) ty, ctx2 )

        Mono.MonoRecordCreate fields ty ->
            let
                ( fieldsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( Mono.MonoRecordCreate (List.reverse fieldsRev) ty, ctx1 )

        Mono.MonoRecordAccess rec field ty ->
            let
                ( rec1, ctx1 ) =
                    go ctx rec
            in
            ( Mono.MonoRecordAccess rec1 field ty, ctx1 )

        Mono.MonoRecordUpdate rec updates ty ->
            let
                ( rec1, ctx1 ) =
                    go ctx rec

                ( updatesRev, ctx2 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( Mono.MonoRecordUpdate rec1 (List.reverse updatesRev) ty, ctx2 )

        Mono.MonoTupleCreate region items ty ->
            let
                ( items1, ctx1 ) =
                    goList ctx items
            in
            ( Mono.MonoTupleCreate region items1 ty, ctx1 )


{-| Returns a `case` decision tree with `replaceExpr` applied to the bodies held
inline at its leaves.
-}
replaceDecider : List Candidate -> Ctx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, Ctx )
replaceDecider cands ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            let
                ( e1, ctx1 ) =
                    replaceExpr cands ctx e
            in
            ( Mono.Leaf (Mono.Inline e1), ctx1 )

        Mono.Leaf (Mono.Jump j) ->
            ( Mono.Leaf (Mono.Jump j), ctx )

        Mono.Chain tests succ fail ->
            let
                ( succ1, ctx1 ) =
                    replaceDecider cands ctx succ

                ( fail1, ctx2 ) =
                    replaceDecider cands ctx1 fail
            in
            ( Mono.Chain tests succ1 fail1, ctx2 )

        Mono.FanOut dtPath edges fallback ->
            let
                ( edgesRev, ctx1 ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c1 ) =
                                    replaceDecider cands c d
                            in
                            ( ( t, d1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        edges

                ( fallback1, ctx2 ) =
                    replaceDecider cands ctx1 fallback
            in
            ( Mono.FanOut dtPath (List.reverse edgesRev) fallback1, ctx2 )



-- ====== ELIGIBILITY ======


{-| Tells whether `expr` is of a kind worth hoisting: a call, `let`, `if`,
`case`, destructuring, record creation or update, tuple, or non-empty list.
-}
candidateKind : Mono.MonoExpr -> Bool
candidateKind expr =
    case expr of
        Mono.MonoCall _ _ _ _ _ ->
            True

        Mono.MonoLet _ _ _ ->
            True

        Mono.MonoIf _ _ _ ->
            True

        Mono.MonoCase _ _ _ _ _ ->
            True

        Mono.MonoDestruct _ _ _ ->
            True

        Mono.MonoRecordCreate _ _ ->
            True

        Mono.MonoRecordUpdate _ _ _ ->
            True

        Mono.MonoTupleCreate _ _ _ ->
            True

        Mono.MonoList _ items _ ->
            not (List.isEmpty items)

        _ ->
            False


{-| Tells whether a value of type `t` is not a scalar: false for `Int`,
`Float`, `Char` and a `number` type variable, true for every other type.
-}
valueAbi : Mono.MonoType -> Bool
valueAbi t =
    case t of
        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MVar _ Mono.CNumber ->
            False

        _ ->
            True


{-| Tells whether `t` is a function type. Only an `MFunction` counts, so a
type variable is never treated as a function type, whatever it stands for.
-}
isFnType : Mono.MonoType -> Bool
isFnType t =
    case t of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Tells whether `t` contains a custom type from the `elm/bytes` package,
looking through custom type arguments, lists, tuples and records, but not into
function types: a function returning an encoder does not count.
-}
typeTouchesBytes : Mono.MonoType -> Bool
typeTouchesBytes t =
    case t of
        Mono.MCustom _ (ModuleName.Canonical pkg _) _ args ->
            pkg == ( "elm", "bytes" ) || List.any typeTouchesBytes args

        Mono.MList _ inner ->
            typeTouchesBytes inner

        Mono.MTuple _ items ->
            List.any typeTouchesBytes items

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc || typeTouchesBytes ft) False fields

        Mono.MFunction _ _ _ _ ->
            False

        _ ->
            False


{-| Tells whether `expr` is a call whose callee is a kernel with home `Bytes`.
-}
bytesHeaded : Mono.MonoExpr -> Bool
bytesHeaded expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Bytes" _ _) _ _ _ ->
            True

        _ ->
            False


{-| Returns the variable a destructuring path starts from.
-}
pathRoot : Mono.MonoPath -> Name.Name
pathRoot path =
    case path of
        Mono.MonoRoot n _ ->
            n

        Mono.MonoIndex _ _ _ rest ->
            pathRoot rest

        Mono.MonoField _ _ rest ->
            pathRoot rest

        Mono.MonoUnbox _ rest ->
            pathRoot rest


{-| Returns the variable a decision-tree path starts from.
-}
dtRoot : Mono.MonoDtPath -> Name.Name
dtRoot path =
    case path of
        Mono.DtRoot n _ ->
            n

        Mono.DtIndex _ _ _ rest ->
            dtRoot rest

        Mono.DtUnbox _ rest ->
            dtRoot rest



-- ====== DEDUPE MACHINERY ======


{-| Returns `expr` with every source region in it set to `A.zero`, so that two
copies of an expression from different places compare equal under `==`.

Nothing else is changed: local names, closure `lambdaId`s and `CallInfo`s are
kept, so expressions that differ in any of them still compare unequal.

-}
zeroRegions : Mono.MonoExpr -> Mono.MonoExpr
zeroRegions expr =
    case expr of
        Mono.MonoLiteral l ty ->
            Mono.MonoLiteral l ty

        Mono.MonoVarLocal n ty ->
            Mono.MonoVarLocal n ty

        Mono.MonoVarGlobal _ sid ty ->
            Mono.MonoVarGlobal A.zero sid ty

        Mono.MonoVarKernel _ p h n ty ->
            Mono.MonoVarKernel A.zero p h n ty

        Mono.MonoUnit ->
            Mono.MonoUnit

        Mono.MonoAccessorValue _ n ty ->
            Mono.MonoAccessorValue A.zero n ty

        Mono.MonoList _ items ty ->
            Mono.MonoList A.zero (List.map zeroRegions items) ty

        Mono.MonoClosure info body ty ->
            Mono.MonoClosure
                { info | captures = List.map (\( n, ce, b ) -> ( n, zeroRegions ce, b )) info.captures }
                (zeroRegions body)
                ty

        Mono.MonoCall _ func args ty callInfo ->
            Mono.MonoCall A.zero (zeroRegions func) (List.map zeroRegions args) ty callInfo

        Mono.MonoTailCall n args ty ->
            Mono.MonoTailCall n (List.map (\( an, ae ) -> ( an, zeroRegions ae )) args) ty

        Mono.MonoIf branches final ty ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( zeroRegions c, zeroRegions t )) branches)
                (zeroRegions final)
                ty

        Mono.MonoLet def body ty ->
            Mono.MonoLet (zeroRegionsDef def) (zeroRegions body) ty

        Mono.MonoDestruct d body ty ->
            Mono.MonoDestruct d (zeroRegions body) ty

        Mono.MonoCase s1 s2 decider branches ty ->
            Mono.MonoCase s1
                s2
                (zeroRegionsDecider decider)
                (List.map (\( i, e ) -> ( i, zeroRegions e )) branches)
                ty

        Mono.MonoRecordCreate fields ty ->
            Mono.MonoRecordCreate (List.map (\( n, e ) -> ( n, zeroRegions e )) fields) ty

        Mono.MonoRecordAccess rec field ty ->
            Mono.MonoRecordAccess (zeroRegions rec) field ty

        Mono.MonoRecordUpdate rec updates ty ->
            Mono.MonoRecordUpdate (zeroRegions rec)
                (List.map (\( n, e ) -> ( n, zeroRegions e )) updates)
                ty

        Mono.MonoTupleCreate _ items ty ->
            Mono.MonoTupleCreate A.zero (List.map zeroRegions items) ty


{-| Returns a local definition with `zeroRegions` applied to its body.
-}
zeroRegionsDef : Mono.MonoDef -> Mono.MonoDef
zeroRegionsDef def =
    case def of
        Mono.MonoDef n e ->
            Mono.MonoDef n (zeroRegions e)

        Mono.MonoTailDef n params e ->
            Mono.MonoTailDef n params (zeroRegions e)


{-| Returns a `case` decision tree with `zeroRegions` applied to the bodies held
inline at its leaves.
-}
zeroRegionsDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
zeroRegionsDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (zeroRegions e))

        Mono.Leaf (Mono.Jump j) ->
            Mono.Leaf (Mono.Jump j)

        Mono.Chain tests succ fail ->
            Mono.Chain tests (zeroRegionsDecider succ) (zeroRegionsDecider fail)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( t, d ) -> ( t, zeroRegionsDecider d )) edges)
                (zeroRegionsDecider fallback)


{-| Returns a short tag for the kind of `expr`'s top node, used to divide
expressions into buckets before comparing them in full.

A call's tag also names its callee when the callee is a global (by SpecId) or a
kernel (by home and name), and a list's tag includes its length. Two
expressions with different tags are never equal, so the tag decides only how
large each bucket is, never which expressions are found equal.

-}
kindTagOf : Mono.MonoExpr -> String
kindTagOf expr =
    let
        headTag func =
            case func of
                Mono.MonoVarGlobal _ sid _ ->
                    "g" ++ String.fromInt sid

                Mono.MonoVarKernel _ _ home name _ ->
                    "k" ++ home ++ "." ++ name

                _ ->
                    "dyn"
    in
    case expr of
        Mono.MonoCall _ func _ _ _ ->
            "c:" ++ headTag func

        Mono.MonoLet _ _ _ ->
            "l"

        Mono.MonoIf _ _ _ ->
            "i"

        Mono.MonoCase _ _ _ _ _ ->
            "k"

        Mono.MonoDestruct _ _ _ ->
            "d"

        Mono.MonoRecordCreate _ _ ->
            "r"

        Mono.MonoRecordUpdate _ _ _ ->
            "u"

        Mono.MonoTupleCreate _ _ _ ->
            "t"

        Mono.MonoList _ items _ ->
            "s" ++ String.fromInt (List.length items)

        _ ->
            "x"
