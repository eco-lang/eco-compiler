module Compiler.GlobalOpt.MonoCse exposing (Stats, emptyStats, renderStats, run)

{-| C2: bounded-scope common-subexpression elimination over pure Mono-level
calls (kernel-opt-13 Phase 3, executing `plans/cse-pure-calls.md` §"C2").

Targets the probe-then-insert idiom —
`if Set.member (f x) s then … else Set.insert (f x) s`, where `f x` is built
twice. Nothing in the pipeline eliminates redundant computation at the Elm
level; LLVM's CSE runs downstream of every boxing, closure and layout decision
and sees two identical _allocation sequences_ it may not merge.

**Where the safety comes from, in three parts:**

1.  _Purity._ `CsePurity` admits only calls whose kernels are audited `cseSafe`
    and whose global callees are transitively observation-free. `Debug` is
    unsafe by construction, so no merge can change how many log lines are
    emitted (`OPT_DEBUG_ORDER_001` D-2).
2.  _Distance._ A group is merged only if at least one occurrence's path from
    the lowest common ancestor is entirely unconditional — that occurrence is
    evaluated on every path that reaches any other, so binding the value at the
    LCA evaluates nothing that was not already going to be evaluated. Groups
    reached through a closure body are excluded permanently: different
    evaluation frequency.
3.  _Scope._ The binding goes at the LCA and **nothing above it**. Every free
    local of the candidate is in scope at the occurrences by construction;
    moving above its binder would make the moved expression ill-scoped. A group
    is dropped if any binder between the LCA and an occurrence rebinds one of
    those free names.

**It moves, it never copies.** The first occurrence becomes the let's bound
expression and every occurrence becomes a `MonoVarLocal`, so binder
multiplicity strictly decreases and the inliner's duplicate-SSA-name hazard
does not arise.

**Why it runs post-annotation** (in `runGlobalOptPhase`, not inside
`globalOptimizeWithStats`): this pass's whole job is adding `MonoLet` bindings,
and `annotateCallStaging` is O(2^let-depth). Running before it would re-arm a
known exponential. Verbatim moves are already licensed in this slot — CGEN\_069
records the `CafHoist` precedent — and function-typed results, the one case
CGEN\_069 says breaks it, are excluded.

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CsePurity as CsePurity
import Dict exposing (Dict)
import Set exposing (Set)


type alias Stats =
    { specsTouched : Int
    , groups : Int
    , merged : Int
    , letsInserted : Int
    , shadowBlocked : Int
    , budgetExhausted : Int
    }


emptyStats : Stats
emptyStats =
    { specsTouched = 0
    , groups = 0
    , merged = 0
    , letsInserted = 0
    , shadowBlocked = 0
    , budgetExhausted = 0
    }


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


{-| A root→node path, serialized. Paths are compared and used as `Dict` keys, so
they are carried as strings; the per-step encoding keeps the prefix property
(the LCA of two paths is the longest common prefix), which is what makes
`lcaOf` a plain string operation.

`u` marks an unconditional step (strict operand, let sequence, or the FIRST
condition of an if-chain, which is evaluated whenever the chain is). `b` marks a
conditional one, `c` entering a closure body.

-}
type alias Path =
    List String


pathKey : Path -> String
pathKey =
    String.join "/"


{-| Does this suffix dominate — i.e. is it reached on every path that reaches
the LCA's continuation?
-}
dominates : List String -> Bool
dominates =
    List.all (\s -> String.startsWith "u" s)


hasClosure : List String -> Bool
hasClosure =
    List.any (\s -> String.startsWith "c" s)



-- OCCURRENCES


type alias Occ =
    { key : String
    , shape : MonoExpr
    , orig : MonoExpr
    , ty : Mono.MonoType
    , path : Path
    , binders : List ( Int, Name )
    , cost : Int
    }


type alias Group =
    { lca : Path
    , occPaths : Set String
    , bound : MonoExpr
    , ty : Mono.MonoType
    , name : Name
    }



-- ENTRY


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
                            -- `Nothing` slots are the Prune gap convention; the
                            -- array length and index↔specId identity are graph
                            -- invariants and must be passed through unchanged.
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
    -- Only `g.nodes` changes, and only within bodies. No spec is minted or
    -- removed, so CafHoist's append-only drift assertion is trivially satisfied
    -- and the three already-empty caches stay empty.
    ( Mono.MonoGraph { g | nodes = nodes1 }, stats1 )


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


rewriteBody : CsePurity.Oracle -> { minCost : Int, maxPerDef : Int } -> MonoExpr -> Stats -> Int -> ( MonoExpr, Stats, Int )
rewriteBody oracle cfg body stats counter =
    let
        occs =
            collect oracle cfg.minCost body [] [] []

        buckets =
            List.foldl
                (\o d -> Dict.update o.key (\m -> Just (o :: Maybe.withDefault [] m)) d)
                Dict.empty
                occs

        ( allGroups, stats1, counter1 ) =
            Dict.foldl
                (\_ members acc -> formGroups cfg members acc)
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


{-| Turn one fingerprint bucket into merge groups: exact-equality partition,
then the distance / shadow / budget tests.
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

                    -- SCOPE, not shadowing. A local bound between the LCA and
                    -- an occurrence is in scope AT the occurrence but not at the
                    -- LCA, so binding the candidate there would reference a name
                    -- that does not exist yet. The plan's claim that "every free
                    -- local is by construction in scope at the occurrences"
                    -- is true and beside the point -- the binding does not go at
                    -- the occurrence, it goes at the LCA.
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


{-| Keep a NON-OVERLAPPING subset of the candidate groups.

A group's let binds the ORIGINAL first-occurrence subtree, inserted verbatim
without rebuilding. If a second group's occurrences lived inside that subtree,
they would either vanish (the subtree gets replaced by a var) or reference a let
that does not dominate them — the `unbound variable mono_cse_N` failure mode.
Rejecting any group whose occurrence subtrees overlap an already-kept group's
also covers the LCA case, because a group's LCA is an ancestor of all of its
occurrences: if the LCA were inside another group's occurrence, every occurrence
would be too.

Greedy in encounter order, which is deterministic.

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


isPrefixPath : String -> String -> Bool
isPrefixPath a b =
    String.startsWith (a ++ "/") b


{-| Longest common prefix of every path — the lowest common ancestor.
-}
lcaOf : List Path -> Path
lcaOf paths =
    case paths of
        [] ->
            []

        p0 :: rest ->
            List.foldl (\p acc -> commonPrefix acc p) p0 rest


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
                -- The let-bound NAME scopes over the body.
                bodyBinders =
                    ( depth + 1, defName def ) :: binders

                -- A MonoTailDef's PARAMETERS scope over its bound expression.
                -- Missing these is what let a candidate mentioning a tail-func
                -- parameter be hoisted above the parameter's binder, producing
                -- `lookupVar: unbound variable i`. The shadow test can only be
                -- as complete as this list.
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


{-| `dpath` distinguishes decider leaves.

Without it every `Leaf (Inline _)` in a `Chain`/`FanOut` tree would share one
path key, two distinct occurrences would look like the same node, and the LCA
would be computed against a path that does not identify either of them — which
produces a `MonoLet` that does not dominate its uses.

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


{-| Candidate test. Mirrors `CseCensus.admit` exactly — the census's numbers are
only meaningful if the pass admits the same set.
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
                -- The purity gate. Without this the pass would merge Debug
                -- calls and effectful kernels; `CsePurity` is what makes
                -- OPT_DEBUG_ORDER_001 D-2 hold by construction.
                Nothing

            else if cost < minCost then
                Nothing

            else
                Just
                    { key = CafHoist.fingerprintOf expr ty
                    , shape = CafHoist.zeroRegions expr
                    , orig = expr
                    , ty = ty
                    , path = path
                    , binders = binders
                    , cost = cost
                    }

        _ ->
            Nothing


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


{-| Top-down rebuild. At an occurrence path the node becomes a `MonoVarLocal`;
at an LCA path the rebuilt node is wrapped in the group's `MonoLet`. Occurrences
are replaced BEFORE the wrap, so the let's bound expression is the original.
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



-- SHARED SHAPE HELPERS


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


defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


defName : Mono.MonoDef -> Name
defName def =
    case def of
        Mono.MonoDef n _ ->
            n

        Mono.MonoTailDef n _ _ ->
            n


mapDefBound : (MonoExpr -> MonoExpr) -> Mono.MonoDef -> Mono.MonoDef
mapDefBound f def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (f bound)

        Mono.MonoTailDef n ps bound ->
            Mono.MonoTailDef n ps (f bound)


destructBinders : Int -> Mono.MonoDestructor -> List ( Int, Name )
destructBinders depth d =
    case d of
        Mono.MonoDestructor n _ _ ->
            [ ( depth, n ) ]
