module Compiler.GlobalOpt.MonoCse exposing
    ( run
    , Stats, emptyStats, renderStats
    )

{-| Elm code often computes the same pure call twice in one function body, as in
`if Set.member (f x) s then ... else Set.insert (f x) s`, and nothing later in
the compiler merges the two; this module binds such a call once and reuses the
value.

The pass is common subexpression elimination (CSE) over monomorphized
function bodies. A _candidate_ is a call that `CsePurity.isSafeExpr` accepts,
whose result is not a function, which contains no `let`, destructuring,
`case` or closure, and whose `CsePurity.costOf` is at least `minCost`. An
_occurrence_ is one candidate in a body together with its _path_, the list of
steps from the body's root down to it. A _group_ is two or more occurrences
that are equal once source regions are ignored. A group's _lowest common
ancestor_ (LCA) is the longest prefix shared by all of its paths. A merged
group becomes `let mono_cse_N = <one occurrence> in <LCA node>`, and every
occurrence becomes a reference to `mono_cse_N`.

Three rules decide whether a group is merged.

  - Purity. Which calls may be merged is `CsePurity`'s decision, described
    there.

  - Evaluation. Each step of a path is either unconditional, meaning the child
    is evaluated whenever its parent is, conditional, or entering a closure
    body. A group is merged only if no occurrence lies inside a closure body
    below the LCA, and at least one occurrence is reached from the LCA by
    unconditional steps alone. That occurrence is evaluated whenever the LCA
    node is, so binding the value at the LCA adds no evaluation. The one
    exception is the body of a local tail-recursive function, whose step is
    marked unconditional although it runs only when the function is called.

  - Scope. The binding is placed at the LCA and no higher. A group is dropped
    if any name bound below the LCA on the way to an occurrence is a free
    local of the candidate, whether or not it shadows another name, because
    the binding at the LCA could not see it.

Each body takes at most `maxPerDef` groups, and of groups whose occurrences
overlap only one is kept. Names `mono_cse_N` are numbered across
the whole graph.

Expressions are moved, never copied: one occurrence becomes the bound
expression and the others disappear, so no local name is duplicated.

The inserted `let`s carry no call staging information of their own. Only
non-function values are bound, which is why candidates whose result is a
function are excluded.

@docs run
@docs Stats, emptyStats, renderStats

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CsePurity as CsePurity
import Dict exposing (Dict)
import Set exposing (Set)


{-| Counters for one run of the pass.

`groups` and `merged` are counted before overlapping groups are dropped, so
they can exceed what was applied: `groups` is groups that passed every test,
and `merged` is their occurrences other than the first. `letsInserted` counts
the groups actually bound, and `specsTouched` the bodies that received at least
one. `shadowBlocked` counts groups dropped by the scope rule, and
`budgetExhausted` counts groups of equal occurrences turned away because the
body already had `maxPerDef` groups, before any other test was applied to them.

-}
type alias Stats =
    { specsTouched : Int
    , groups : Int
    , merged : Int
    , letsInserted : Int
    , shadowBlocked : Int
    , budgetExhausted : Int
    }


{-| All counters at zero.
-}
emptyStats : Stats
emptyStats =
    { specsTouched = 0
    , groups = 0
    , merged = 0
    , letsInserted = 0
    , shadowBlocked = 0
    , budgetExhausted = 0
    }


{-| Returns the counters as one line beginning `mono-cse:`.
-}
renderStats : Stats -> String
renderStats s =
    "mono-cse: specsTouched="
        ++ String.fromInt s.specsTouched
        ++ " groups="
        ++ String.fromInt s.groups
        ++ " merged="
        ++ String.fromInt s.merged
        ++ " letsInserted="
        ++ String.fromInt s.letsInserted
        ++ " shadowBlocked="
        ++ String.fromInt s.shadowBlocked
        ++ " budgetExhausted="
        ++ String.fromInt s.budgetExhausted



-- PATHS


{-| The steps from a body's root down to one expression, one string per step.

A step's first letter classifies it. `u` is unconditional: call function and
arguments, tail call arguments, list, tuple and record elements, the record of
an access or update, the bound expression and body of a `let`, the body of a
destructuring, and the first condition of an `if`. `b` is conditional: later
`if` conditions, every `if` branch and the final `else`, `case` branches, and
expressions inline in a `case` decision tree. `c` is the body of a closure. The
rest of the step says which child it is, so two different expressions in one
body never share a path.

-}
type alias Path =
    List String


{-| Returns the path as one string with steps joined by `/`, for use as a
`Dict` key.
-}
pathKey : Path -> String
pathKey =
    String.join "/"


{-| Returns whether every step of a path suffix is unconditional.
-}
dominates : List String -> Bool
dominates =
    List.all (\s -> String.startsWith "u" s)


{-| Returns whether a path suffix enters a closure body.
-}
hasClosure : List String -> Bool
hasClosure =
    List.any (\s -> String.startsWith "c" s)



-- OCCURRENCES


{-| One occurrence of a candidate in a body.

`key` is `CafHoist.kindTagOf` of the call and `shape` is the call with its
source regions zeroed; occurrences are grouped by equal `shape`. `orig` is the
call as written. `binders` holds the names bound by lets and destructurings
above the occurrence, and a local tail-recursive function's parameters within
its body, each with the length of the path at which it comes into scope.

-}
type alias Occ =
    { key : String
    , shape : MonoExpr
    , orig : MonoExpr
    , ty : Mono.MonoType
    , path : Path
    , binders : List ( Int, Name )
    , cost : Int
    }


{-| A group that passed every test: where its `let` goes (`lca`), the path
keys of its occurrences, the expression it binds, that expression's type, and
the name it binds it to.
-}
type alias Group =
    { lca : Path
    , occPaths : Set String
    , bound : MonoExpr
    , ty : Mono.MonoType
    , name : Name
    }



-- ENTRY


{-| Runs the pass over the body of every `MonoDefine` and `MonoTailFunc` node in
the graph, and returns the rewritten graph with the counters.

Candidates must cost at least `minCost` by `CsePurity.costOf`, and at most
`maxPerDef` groups are bound in each body. Only those bodies change: every
other node, the empty slots of the node array, and every node's index are
kept, and no node is added or removed.

-}
run : { minCost : Int, maxPerDef : Int } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run cfg ((Mono.MonoGraph g) as graph) =
    let
        oracle =
            CsePurity.analyze graph

        ( nodes1, stats1, _ ) =
            Array.foldl
                (\maybeNode ( acc, st, counter ) ->
                    case maybeNode of
                        Nothing ->
                            -- Kept so that every node keeps its index.
                            ( Array.push Nothing acc, st, counter )

                        Just node ->
                            let
                                ( node1, st1, counter1 ) =
                                    rewriteNode oracle cfg node st counter
                            in
                            ( Array.push (Just node1) acc, st1, counter1 )
                )
                ( Array.empty, emptyStats, 0 )
                g.nodes
    in
    ( Mono.MonoGraph { g | nodes = nodes1 }, stats1 )


{-| Rewrites the body of a `MonoDefine` or `MonoTailFunc` node and returns any
other node unchanged, threading the counters and the next `mono_cse_N` number.
-}
rewriteNode : CsePurity.Oracle -> { minCost : Int, maxPerDef : Int } -> Mono.MonoNode -> Stats -> Int -> ( Mono.MonoNode, Stats, Int )
rewriteNode oracle cfg node stats counter =
    case node of
        Mono.MonoDefine body ty ->
            let
                ( body1, st, c ) =
                    rewriteBody oracle cfg body stats counter
            in
            ( Mono.MonoDefine body1 ty, st, c )

        Mono.MonoTailFunc params body ty ->
            let
                ( body1, st, c ) =
                    rewriteBody oracle cfg body stats counter
            in
            ( Mono.MonoTailFunc params body1 ty, st, c )

        other ->
            ( other, stats, counter )


{-| Returns `body` with every kept group merged, together with the updated
counters and the next `mono_cse_N` number.

Occurrences are bucketed by kind tag and then by result type before groups are
formed in each bucket. The order buckets are visited in decides which of two
overlapping groups is kept.

-}
rewriteBody : CsePurity.Oracle -> { minCost : Int, maxPerDef : Int } -> MonoExpr -> Stats -> Int -> ( MonoExpr, Stats, Int )
rewriteBody oracle cfg body stats counter =
    let
        occs =
            collect oracle cfg.minCost body [] [] []

        buckets =
            List.foldl
                (\o d ->
                    Dict.update o.key
                        (\m ->
                            let
                                inner =
                                    Maybe.withDefault Mono.specMapEmpty m

                                prev =
                                    Maybe.withDefault [] (Mono.specMapGet o.ty inner)
                            in
                            Just (Mono.specMapInsert o.ty (o :: prev) inner)
                        )
                        d
                )
                Dict.empty
                occs

        ( allGroups, stats1, counter1 ) =
            Dict.foldl
                (\_ inner acc ->
                    Mono.specMapFoldl (\_ members acc2 -> formGroups cfg members acc2) acc inner
                )
                ( [], stats, counter )
                buckets

        groups =
            dropOverlapping allGroups
    in
    if List.isEmpty groups then
        ( body, stats1, counter1 )

    else
        let
            byOcc =
                List.foldl
                    (\gr d -> Set.foldl (\p acc -> Dict.insert p ( gr.name, gr.ty ) acc) d gr.occPaths)
                    Dict.empty
                    groups

            byLca =
                List.foldl
                    (\gr d -> Dict.update (pathKey gr.lca) (\m -> Just (gr :: Maybe.withDefault [] m)) d)
                    Dict.empty
                    groups
        in
        ( rebuild byOcc byLca [] body
        , { stats1
            | specsTouched = stats1.specsTouched + 1
            , letsInserted = stats1.letsInserted + List.length groups
          }
        , counter1
        )


{-| Adds to the accumulator the groups formed from one bucket of occurrences.

The bucket is split into sets of equal `shape`. A set of one is ignored. A set
of two or more is turned away once the body already has `maxPerDef` groups, and
otherwise becomes a group if it passes the evaluation and scope rules of the
module docstring. A new group binds the set's head occurrence's expression and
takes the next `mono_cse_N` number.

-}
formGroups :
    { minCost : Int, maxPerDef : Int }
    -> List Occ
    -> ( List Group, Stats, Int )
    -> ( List Group, Stats, Int )
formGroups cfg members ( groups, stats, counter ) =
    case members of
        [] ->
            ( groups, stats, counter )

        first :: rest ->
            let
                ( same, different ) =
                    List.partition (\o -> o.shape == first.shape) rest

                recurse acc =
                    formGroups cfg different acc
            in
            if List.isEmpty same then
                recurse ( groups, stats, counter )

            else if List.length groups >= cfg.maxPerDef then
                recurse ( groups, { stats | budgetExhausted = stats.budgetExhausted + 1 }, counter )

            else
                let
                    members1 =
                        first :: same

                    lca =
                        lcaOf (List.map .path members1)

                    lcaLen =
                        List.length lca

                    suffixes =
                        List.map (\o -> List.drop lcaLen o.path) members1

                    free =
                        freeLocals first.orig

                    -- A name bound below the LCA is not in scope at the LCA,
                    -- whether or not it shadows anything.
                    shadowed =
                        List.any
                            (\o ->
                                List.any
                                    (\( d, n ) -> d > lcaLen && Set.member n free)
                                    o.binders
                            )
                            members1
                in
                if List.any hasClosure suffixes then
                    recurse ( groups, stats, counter )

                else if not (List.any dominates suffixes) then
                    recurse ( groups, stats, counter )

                else if shadowed then
                    recurse ( groups, { stats | shadowBlocked = stats.shadowBlocked + 1 }, counter )

                else
                    recurse
                        ( { lca = lca
                          , occPaths = Set.fromList (List.map (\o -> pathKey o.path) members1)
                          , bound = first.orig
                          , ty = first.ty
                          , name = "mono_cse_" ++ String.fromInt counter
                          }
                            :: groups
                        , { stats
                            | groups = stats.groups + 1
                            , merged = stats.merged + List.length same
                          }
                        , counter + 1
                        )


{-| Returns the groups that do not overlap a group already kept, taking them in
list order.

Two groups overlap when an occurrence of one is equal to, inside, or around an
occurrence of the other. A group binds one of its occurrences exactly as written,
so an occurrence of another group inside it would not be replaced, and an
occurrence around it would remove it. A group's LCA is above all its
occurrences, so a group whose LCA lay inside another's occurrence would overlap
it too.

-}
dropOverlapping : List Group -> List Group
dropOverlapping groups =
    List.foldl
        (\gr kept ->
            let
                taken =
                    List.concatMap (\k -> Set.toList k.occPaths) kept

                mine =
                    Set.toList gr.occPaths

                overlaps =
                    List.any
                        (\a -> List.any (\b -> a == b || isPrefixPath a b || isPrefixPath b a) mine)
                        taken
            in
            if overlaps then
                kept

            else
                gr :: kept
        )
        []
        groups


{-| Returns whether path key `b` lies strictly below path key `a`.
-}
isPrefixPath : String -> String -> Bool
isPrefixPath a b =
    String.startsWith (a ++ "/") b


{-| Returns the longest prefix shared by every path, the lowest common
ancestor, or the empty path for no paths.
-}
lcaOf : List Path -> Path
lcaOf paths =
    case paths of
        [] ->
            []

        p0 :: rest ->
            List.foldl (\p acc -> commonPrefix acc p) p0 rest


{-| Returns the longest prefix shared by two paths.
-}
commonPrefix : Path -> Path -> Path
commonPrefix a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            if x == y then
                x :: commonPrefix xs ys

            else
                []

        _ ->
            []


{-| Returns the names of the `MonoVarLocal`s in an expression, not looking
inside a closure's capture expressions.

It does not remove names the expression binds itself.

-}
freeLocals : MonoExpr -> Set Name
freeLocals root =
    let
        go e acc =
            case e of
                MonoVarLocal n _ ->
                    Set.insert n acc

                _ ->
                    List.foldl go acc (childrenOf e)
    in
    go root Set.empty



-- COLLECT


{-| Adds to `acc` every candidate occurrence in `expr` and below it, except
inside closure capture expressions, given the path to `expr` and the names
bound inside the body that are in scope there.
-}
collect : CsePurity.Oracle -> Int -> MonoExpr -> Path -> List ( Int, Name ) -> List Occ -> List Occ
collect oracle minCost expr path binders acc =
    let
        acc1 =
            case admit oracle minCost expr path binders of
                Just occ ->
                    occ :: acc

                Nothing ->
                    acc

        depth =
            List.length path

        step tag child bs a =
            collect oracle minCost child (path ++ [ tag ]) bs a

        each tag items bs a =
            List.foldl (\( n, e ) b -> step (tag n) e bs b) a (List.indexedMap Tuple.pair items)
    in
    case expr of
        MonoList _ items _ ->
            each (\n -> "u s" ++ String.fromInt n) items binders acc1

        MonoClosure _ body _ ->
            step "c" body binders acc1

        MonoCall _ func args _ _ ->
            each (\n -> "u a" ++ String.fromInt n) args binders (step "u f" func binders acc1)

        MonoTailCall _ args _ ->
            each (\n -> "u t" ++ String.fromInt n) (List.map Tuple.second args) binders acc1

        MonoIf branches final _ ->
            let
                a1 =
                    List.foldl
                        (\( n, ( c, t ) ) b ->
                            step ("b t" ++ String.fromInt n)
                                t
                                binders
                                (step
                                    (if n == 0 then
                                        "u g0"

                                     else
                                        "b g" ++ String.fromInt n
                                    )
                                    c
                                    binders
                                    b
                                )
                        )
                        acc1
                        (List.indexedMap Tuple.pair branches)
            in
            step "b fin" final binders a1

        MonoLet def body _ ->
            let
                bodyBinders =
                    ( depth + 1, defName def ) :: binders

                -- The scope rule is only as complete as these binder lists.
                boundBinders =
                    case def of
                        Mono.MonoTailDef _ params _ ->
                            List.map (\( n, _ ) -> ( depth + 1, n )) params ++ binders

                        Mono.MonoDef _ _ ->
                            binders
            in
            step "u lb" body bodyBinders (step "u ld" (defBound def) boundBinders acc1)

        MonoDestruct d body _ ->
            step "u db" body (destructBinders (depth + 1) d ++ binders) acc1

        MonoCase _ _ decider branches _ ->
            each (\n -> "b k" ++ String.fromInt n)
                (List.map Tuple.second branches)
                binders
                (collectDecider oracle minCost path "" binders acc1 decider)

        MonoRecordCreate fields _ ->
            each (\n -> "u r" ++ String.fromInt n) (List.map Tuple.second fields) binders acc1

        MonoRecordAccess inner _ _ ->
            step "u ra" inner binders acc1

        MonoRecordUpdate inner updates _ ->
            each (\n -> "u ru" ++ String.fromInt n)
                (List.map Tuple.second updates)
                binders
                (step "u rb" inner binders acc1)

        MonoTupleCreate _ items _ ->
            each (\n -> "u p" ++ String.fromInt n) items binders acc1

        _ ->
            acc1


{-| Adds to `acc` the occurrences in the expressions held inline at the leaves
of a `case` decision tree.

`dpath` records the way down the tree to the current node, and becomes part of
the leaf's step, so that two leaves of one tree have different paths. Jump
leaves hold no expression here; their targets are the `case` branches.

-}
collectDecider : CsePurity.Oracle -> Int -> Path -> String -> List ( Int, Name ) -> List Occ -> Mono.Decider Mono.MonoChoice -> List Occ
collectDecider oracle minCost path dpath binders acc decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collect oracle minCost e (path ++ [ "b dl" ++ dpath ]) binders acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            collectDecider oracle
                minCost
                path
                (dpath ++ "f")
                binders
                (collectDecider oracle minCost path (dpath ++ "s") binders acc success)
                failure

        Mono.FanOut _ tests fallback ->
            collectDecider oracle
                minCost
                path
                (dpath ++ "b")
                binders
                (List.foldl
                    (\( n, ( _, d ) ) a ->
                        collectDecider oracle minCost path (dpath ++ "t" ++ String.fromInt n) binders a d
                    )
                    acc
                    (List.indexedMap Tuple.pair tests)
                )
                fallback


{-| Returns the occurrence for `expr` if it is a candidate, as the module
docstring defines one.
-}
admit : CsePurity.Oracle -> Int -> MonoExpr -> Path -> List ( Int, Name ) -> Maybe Occ
admit oracle minCost expr path binders =
    case expr of
        MonoCall _ _ _ ty _ ->
            let
                cost =
                    CsePurity.costOf expr
            in
            if Mono.isFunctionType ty then
                Nothing

            else if hasBinderOrClosure expr then
                Nothing

            else if not (CsePurity.isSafeExpr oracle expr) then
                Nothing

            else if cost < minCost then
                Nothing

            else
                Just
                    { key = CafHoist.kindTagOf expr
                    , shape = CafHoist.zeroRegions expr
                    , orig = expr
                    , ty = ty
                    , path = path
                    , binders = binders
                    , cost = cost
                    }

        _ ->
            Nothing


{-| Returns whether an expression contains a `let`, a destructuring, a `case` or
a closure.
-}
hasBinderOrClosure : MonoExpr -> Bool
hasBinderOrClosure root =
    let
        go e =
            case e of
                MonoLet _ _ _ ->
                    True

                MonoDestruct _ _ _ ->
                    True

                MonoCase _ _ _ _ _ ->
                    True

                MonoClosure _ _ _ ->
                    True

                _ ->
                    List.any go (childrenOf e)
    in
    go root



-- REBUILD


{-| Returns `expr`, found at `path`, with the groups applied: an occurrence
becomes a reference to its group's name, and a node that is some groups' LCA is
rebuilt and then wrapped in one `let` per group. Each `let` binds its group's
bound expression as written, not a rebuilt copy.
-}
rebuild : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> MonoExpr -> MonoExpr
rebuild byOcc byLca path expr =
    let
        here =
            pathKey path
    in
    case Dict.get here byOcc of
        Just ( n, ty ) ->
            MonoVarLocal n ty

        Nothing ->
            let
                inner =
                    rebuildChildren byOcc byLca path expr
            in
            case Dict.get here byLca of
                Nothing ->
                    inner

                Just groups ->
                    List.foldl
                        (\gr acc ->
                            MonoLet (Mono.MonoDef gr.name gr.bound) acc (Mono.typeOf acc)
                        )
                        inner
                        groups


{-| Returns `expr` with `rebuild` applied to each child, using the same steps
as `collect`.
-}
rebuildChildren : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> MonoExpr -> MonoExpr
rebuildChildren byOcc byLca path expr =
    let
        at tag child =
            rebuild byOcc byLca (path ++ [ tag ]) child

        mapIdx tag items =
            List.indexedMap (\n e -> at (tag n) e) items
    in
    case expr of
        MonoList r items ty ->
            MonoList r (mapIdx (\n -> "u s" ++ String.fromInt n) items) ty

        MonoClosure ci body ty ->
            MonoClosure ci (at "c" body) ty

        MonoCall r func args ty ci ->
            MonoCall r (at "u f" func) (mapIdx (\n -> "u a" ++ String.fromInt n) args) ty ci

        MonoTailCall n args ty ->
            MonoTailCall n
                (List.indexedMap (\k ( nm, e ) -> ( nm, at ("u t" ++ String.fromInt k) e )) args)
                ty

        MonoIf branches final ty ->
            MonoIf
                (List.indexedMap
                    (\n ( c, t ) ->
                        ( at
                            (if n == 0 then
                                "u g0"

                             else
                                "b g" ++ String.fromInt n
                            )
                            c
                        , at ("b t" ++ String.fromInt n) t
                        )
                    )
                    branches
                )
                (at "b fin" final)
                ty

        MonoLet def body ty ->
            MonoLet (mapDefBound (at "u ld") def) (at "u lb" body) ty

        MonoDestruct d body ty ->
            MonoDestruct d (at "u db" body) ty

        MonoCase s j decider branches ty ->
            MonoCase s
                j
                (rebuildDecider byOcc byLca path "" decider)
                (List.indexedMap (\n ( k, e ) -> ( k, at ("b k" ++ String.fromInt n) e )) branches)
                ty

        MonoRecordCreate fields ty ->
            MonoRecordCreate
                (List.indexedMap (\n ( f, e ) -> ( f, at ("u r" ++ String.fromInt n) e )) fields)
                ty

        MonoRecordAccess inner f ty ->
            MonoRecordAccess (at "u ra" inner) f ty

        MonoRecordUpdate inner updates ty ->
            MonoRecordUpdate (at "u rb" inner)
                (List.indexedMap (\n ( f, e ) -> ( f, at ("u ru" ++ String.fromInt n) e )) updates)
                ty

        MonoTupleCreate r items ty ->
            MonoTupleCreate r (mapIdx (\n -> "u p" ++ String.fromInt n) items) ty

        other ->
            other


{-| Returns a `case` decision tree with `rebuild` applied to the expressions
held inline at its leaves, using the same steps as `collectDecider`.
-}
rebuildDecider : Dict String ( Name, Mono.MonoType ) -> Dict String (List Group) -> Path -> String -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
rebuildDecider byOcc byLca path dpath decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (rebuild byOcc byLca (path ++ [ "b dl" ++ dpath ]) e))

        Mono.Leaf (Mono.Jump j) ->
            Mono.Leaf (Mono.Jump j)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (rebuildDecider byOcc byLca path (dpath ++ "s") success)
                (rebuildDecider byOcc byLca path (dpath ++ "f") failure)

        Mono.FanOut p tests fallback ->
            Mono.FanOut p
                (List.indexedMap
                    (\n ( t, d ) -> ( t, rebuildDecider byOcc byLca path (dpath ++ "t" ++ String.fromInt n) d ))
                    tests
                )
                (rebuildDecider byOcc byLca path (dpath ++ "b") fallback)



-- SHAPE HELPERS


{-| Returns the direct subexpressions of an expression, including those inline
in a `case` decision tree, except a closure's capture expressions.
-}
childrenOf : MonoExpr -> List MonoExpr
childrenOf expr =
    case expr of
        MonoList _ items _ ->
            items

        MonoClosure _ body _ ->
            [ body ]

        MonoCall _ func args _ _ ->
            func :: args

        MonoTailCall _ args _ ->
            List.map Tuple.second args

        MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        MonoLet def body _ ->
            [ defBound def, body ]

        MonoDestruct _ body _ ->
            [ body ]

        MonoCase _ _ decider branches _ ->
            deciderExprs decider ++ List.map Tuple.second branches

        MonoRecordCreate fields _ ->
            List.map Tuple.second fields

        MonoRecordAccess inner _ _ ->
            [ inner ]

        MonoRecordUpdate inner updates _ ->
            inner :: List.map Tuple.second updates

        MonoTupleCreate _ items _ ->
            items

        _ ->
            []


{-| Returns the expressions held inline at the leaves of a decision tree.
-}
deciderExprs : Mono.Decider Mono.MonoChoice -> List MonoExpr
deciderExprs decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ success failure ->
            deciderExprs success ++ deciderExprs failure

        Mono.FanOut _ tests fallback ->
            List.concatMap (\( _, d ) -> deciderExprs d) tests ++ deciderExprs fallback


{-| Returns the expression a local definition binds.
-}
defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


{-| Returns the name a local definition binds.
-}
defName : Mono.MonoDef -> Name
defName def =
    case def of
        Mono.MonoDef n _ ->
            n

        Mono.MonoTailDef n _ _ ->
            n


{-| Returns a local definition with `f` applied to its bound expression.
-}
mapDefBound : (MonoExpr -> MonoExpr) -> Mono.MonoDef -> Mono.MonoDef
mapDefBound f def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (f bound)

        Mono.MonoTailDef n ps bound ->
            Mono.MonoTailDef n ps (f bound)


{-| Returns the name a destructuring binds, paired with `depth`.
-}
destructBinders : Int -> Mono.MonoDestructor -> List ( Int, Name )
destructBinders depth d =
    case d of
        Mono.MonoDestructor n _ _ ->
            [ ( depth, n ) ]
