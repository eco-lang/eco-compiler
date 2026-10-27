module Compiler.GlobalOpt.CafCensus exposing (report)

{-| Reports how many closed subexpressions inside function bodies
`Compiler.GlobalOpt.CafHoist` could move out into CAFs (constant applicative
forms: nullary top-level values evaluated once), and why it would skip the
rest, without changing the graph.

The terms are those of `CafHoist`'s module docstring: a _closed_
subexpression mentions no local variable bound outside itself, and hoisting
one turns it into a new top-level value evaluated once. This module counts
the opportunity; `report` returns its counts as text and the graph it is given
is not modified.

The walk looks where `CafHoist` looks: the body and capture expressions of a
`MonoDefine` whose value is a closure, and the body of a `MonoTailFunc`. It
collects _maximal_ candidates: a closed node of a candidate kind (a call,
`let`, `if`, `case`, destructuring, record creation or update, tuple, or
non-empty list) is taken whole and the candidates inside it are not counted
separately. The _layered_ count is the other measure: every closed node of a
candidate kind, including those nested inside another.

Each candidate records whether its result is of scalar type, whether it is of
function type, whether it touches `elm/bytes`, whether it references a `Debug`
kernel, and its size in nodes. The _eligible_ count is the candidates that are
of none of these kinds and have at least `minNodes` nodes. Each candidate also
records whether it contains a closure; the eligible count does not test it.

This walk is separate code from `CafHoist`'s and does not give the same
answer. A `Debug` reference counts here only when a `Debug` kernel appears in
the subtree itself, whereas `CafHoist` also rejects a subtree referencing a
global spec from which `Debug` is reachable, so the eligible count here can be
higher. It can also be lower, because a maximal candidate that fails a test
hides any eligible candidates inside it, which `CafHoist` would still take.

@docs report

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.CafHoist as CafHoist
import Dict exposing (Dict)
import Set exposing (Set)


{-| One maximal closed candidate found by the walk, with the attributes the
census counts.

`head` names the callee of a call: `"G:"` followed by a SpecId for a global,
`"K:"` followed by home and name for a kernel, `"dyn"` for any other callee,
and the empty string for a candidate that is not a call. `size` is the
candidate's size in nodes. `valueAbi` is false for a scalar-typed result.
`bytesEx` is true when the result type touches `elm/bytes` or the candidate is
a call to a `Bytes` kernel. `dedupeKey` is the key under which two candidates
are the same shape, and is `Nothing` for a candidate that contains a closure.

-}
type alias Cand =
    { kind : String
    , head : String
    , size : Int
    , valueAbi : Bool
    , hasClosure : Bool
    , hasDebug : Bool
    , bytesEx : Bool
    , fnType : Bool
    , dedupeKey : Maybe ( String, Mono.MonoType, Mono.MonoExpr ) -- kind tag, type, region-zeroed expression
    }


{-| What the walk knows about one subexpression once it has been visited.

`free` is the set of local names it mentions that are bound outside it; it is
closed when `free` is empty. `cands` are the maximal candidates found in it,
and `layered` counts every closed candidate node in it, nested ones included.
`size` is its size in nodes, and `hasClosure` and `hasDebug` say whether it
contains a closure or a reference to a `Debug` kernel.

-}
type alias Walk =
    { free : Set Name.Name
    , cands : List Cand
    , size : Int
    , hasClosure : Bool
    , hasDebug : Bool
    , layered : Int
    }


{-| The walk of a subexpression that mentions nothing and contains nothing.
-}
emptyWalk : Walk
emptyWalk =
    { free = Set.empty, cands = [], size = 0, hasClosure = False, hasDebug = False, layered = 0 }


{-| Combines the walks of two sibling subexpressions: free names and
candidates are united, sizes and layered counts are added.
-}
merge : Walk -> Walk -> Walk
merge a b =
    { free = Set.union a.free b.free
    , cands = a.cands ++ b.cands
    , size = a.size + b.size
    , hasClosure = a.hasClosure || b.hasClosure
    , hasDebug = a.hasDebug || b.hasDebug
    , layered = a.layered + b.layered
    }


{-| Combines the walks of any number of sibling subexpressions.
-}
mergeAll : List Walk -> Walk
mergeAll =
    List.foldl merge emptyWalk


{-| Returns the kind name and callee head of `expr` if its top node is of a
candidate kind, or `Nothing` if it is not. Closures, literals, empty lists,
variable references and accessors are not candidate kinds.
-}
candKind : Mono.MonoExpr -> Maybe ( String, String )
candKind expr =
    case expr of
        Mono.MonoCall _ func _ _ _ ->
            Just ( "call", headOf func )

        Mono.MonoRecordCreate _ _ ->
            Just ( "record", "" )

        Mono.MonoTupleCreate _ _ _ ->
            Just ( "tuple", "" )

        Mono.MonoList _ items _ ->
            if List.isEmpty items then
                Nothing

            else
                Just ( "list", "" )

        Mono.MonoLet _ _ _ ->
            Just ( "let", "" )

        Mono.MonoIf _ _ _ ->
            Just ( "if", "" )

        Mono.MonoCase _ _ _ _ _ ->
            Just ( "case", "" )

        Mono.MonoDestruct _ _ _ ->
            Just ( "destruct", "" )

        Mono.MonoRecordUpdate _ _ _ ->
            Just ( "recordUpdate", "" )

        _ ->
            Nothing


{-| Returns the `head` string naming a call's callee, in the form `Cand`
describes.
-}
headOf : Mono.MonoExpr -> String
headOf func =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            "G:" ++ String.fromInt specId

        Mono.MonoVarKernel _ _ home name _ ->
            "K:" ++ Name.toElmString home ++ "." ++ Name.toElmString name

        _ ->
            "dyn"


{-| Tells whether `t` is not a scalar type. It is false for `Int`, `Float`,
`Char` and a `number` type variable, and true for every other type.
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


{-| Returns the local variable a destructuring path starts from.
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


{-| Returns the local variable a decision-tree test path starts from.
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


{-| Walks a `case` decision tree: the inline branch bodies at its leaves, and
the variables its tests inspect, which count as free. A jump leaf contributes
nothing; the branch it jumps to is walked with the `case` itself.
-}
walkDecider : Mono.Decider Mono.MonoChoice -> Walk
walkDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            walkExpr e

        Mono.Leaf (Mono.Jump _) ->
            emptyWalk

        Mono.Chain tests succ fail ->
            List.foldl
                (\( dtPath, _ ) acc ->
                    { acc | free = Set.insert (dtRoot dtPath) acc.free }
                )
                (merge (walkDecider succ) (walkDecider fail))
                tests

        Mono.FanOut dtPath edges fallback ->
            List.foldl (\( _, d ) acc -> merge (walkDecider d) acc)
                (walkDecider fallback)
                edges
                |> (\acc -> { acc | free = Set.insert (dtRoot dtPath) acc.free })


{-| Walks `expr` bottom-up and returns its `Walk`.

When `expr` is closed and of a candidate kind, its `cands` is that one
candidate, replacing whatever was found inside it, while `layered` still adds
the nested ones. Names bound by a closure, `let` or destructuring are removed
from the free set of the part they scope over.

-}
walkExpr : Mono.MonoExpr -> Walk
walkExpr expr =
    let
        inner : Walk
        inner =
            case expr of
                Mono.MonoLiteral _ _ ->
                    emptyWalk

                Mono.MonoVarLocal n _ ->
                    { emptyWalk | free = Set.singleton n }

                Mono.MonoVarGlobal _ _ _ ->
                    emptyWalk

                Mono.MonoVarKernel _ _ home _ _ ->
                    { emptyWalk | hasDebug = home == "Debug" }

                Mono.MonoUnit ->
                    emptyWalk

                Mono.MonoAccessorValue _ _ _ ->
                    emptyWalk

                Mono.MonoList _ items _ ->
                    mergeAll (List.map walkExpr items)

                Mono.MonoClosure info body _ ->
                    let
                        captureWalks =
                            mergeAll
                                (List.map (\( _, ce, _ ) -> walkExpr ce) info.captures)

                        bound =
                            Set.fromList
                                (List.map (\( n, _ ) -> n) info.params
                                    ++ List.map (\( n, _, _ ) -> n) info.captures
                                )

                        bodyWalk =
                            walkExpr body

                        merged =
                            merge captureWalks
                                { bodyWalk | free = Set.diff bodyWalk.free bound }
                    in
                    { merged | hasClosure = True }

                Mono.MonoCall _ func args _ _ ->
                    mergeAll (walkExpr func :: List.map walkExpr args)

                Mono.MonoTailCall n args _ ->
                    let
                        argWalks =
                            mergeAll (List.map (\( _, e ) -> walkExpr e) args)
                    in
                    { argWalks | free = Set.insert n argWalks.free }

                Mono.MonoIf branches final _ ->
                    mergeAll
                        (walkExpr final
                            :: List.map
                                (\( c, t ) -> merge (walkExpr c) (walkExpr t))
                                branches
                        )

                Mono.MonoLet def body _ ->
                    case def of
                        Mono.MonoDef n bound ->
                            let
                                bodyWalk =
                                    walkExpr body
                            in
                            merge (walkExpr bound)
                                { bodyWalk | free = Set.remove n bodyWalk.free }

                        Mono.MonoTailDef n params bound ->
                            let
                                boundWalk =
                                    walkExpr bound

                                paramSet =
                                    Set.insert n
                                        (Set.fromList (List.map (\( pn, _ ) -> pn) params))

                                bodyWalk =
                                    walkExpr body
                            in
                            merge
                                { boundWalk | free = Set.diff boundWalk.free paramSet }
                                { bodyWalk | free = Set.remove n bodyWalk.free }

                Mono.MonoDestruct (Mono.MonoDestructor n path _) body _ ->
                    let
                        bodyWalk =
                            walkExpr body
                    in
                    { bodyWalk
                        | free =
                            Set.insert (pathRoot path)
                                (Set.remove n bodyWalk.free)
                    }

                Mono.MonoCase s1 s2 decider branches _ ->
                    let
                        branchWalks =
                            mergeAll (List.map (\( _, e ) -> walkExpr e) branches)

                        all =
                            merge (walkDecider decider) branchWalks
                    in
                    { all | free = Set.insert s1 (Set.insert s2 all.free) }

                Mono.MonoRecordCreate fields _ ->
                    mergeAll (List.map (\( _, e ) -> walkExpr e) fields)

                Mono.MonoRecordAccess rec _ _ ->
                    walkExpr rec

                Mono.MonoRecordUpdate rec updates _ ->
                    mergeAll
                        (walkExpr rec
                            :: List.map (\( _, e ) -> walkExpr e) updates
                        )

                Mono.MonoTupleCreate _ items _ ->
                    mergeAll (List.map walkExpr items)

        sized : Walk
        sized =
            { inner | size = inner.size + 1 }
    in
    if Set.isEmpty sized.free then
        case candKind expr of
            Just ( kind, head ) ->
                let
                    ty =
                        Mono.typeOf expr

                    cand =
                        { kind = kind
                        , head = head
                        , size = sized.size
                        , valueAbi = valueAbi ty
                        , hasClosure = sized.hasClosure
                        , hasDebug = sized.hasDebug
                        , bytesEx =
                            CafHoist.typeTouchesBytes ty || bytesHeadedCensus expr
                        , fnType =
                            case ty of
                                Mono.MFunction _ _ _ _ ->
                                    True

                                _ ->
                                    False
                        , dedupeKey =
                            if sized.hasClosure then
                                Nothing

                            else
                                Just ( CafHoist.kindTagOf expr, ty, CafHoist.zeroRegions expr )
                        }
                in
                { sized | cands = [ cand ], layered = sized.layered + 1 }

            Nothing ->
                sized

    else
        sized


{-| Tells whether `expr` is a call whose callee is a kernel with home `Bytes`.
-}
bytesHeadedCensus : Mono.MonoExpr -> Bool
bytesHeadedCensus expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Bytes" _ _) _ _ _ ->
            True

        _ ->
            False


{-| Returns the candidates found in one node and its layered count.

Only the body and capture expressions of a `MonoDefine` whose value is a
closure, and the body of a `MonoTailFunc`, are walked. Every other node,
including a `MonoDefine` whose value is not a closure, gives no candidates.

-}
walkNode : Mono.MonoNode -> ( List Cand, Int )
walkNode node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure info body _) _ ->
            let
                bodyWalk =
                    walkExpr body

                captureWalks =
                    List.map (\( _, ce, _ ) -> walkExpr ce) info.captures
            in
            ( bodyWalk.cands ++ List.concatMap .cands captureWalks
            , bodyWalk.layered + List.sum (List.map .layered captureWalks)
            )

        Mono.MonoDefine _ _ ->
            ( [], 0 )

        Mono.MonoTailFunc _ body _ ->
            let
                w =
                    walkExpr body
            in
            ( w.cands, w.layered )

        _ ->
            ( [], 0 )


{-| Builds the census report for a graph as six lines of text, each starting
with `prefix`. `minNodes` is the size floor used for the below-minimum and
eligible counts.

The first line gives the number of node slots in the graph, the number of
candidates, how many have a non-scalar ABI, and their total size in nodes. The
second gives the eligible count, the number of distinct shapes among eligible
candidates without a closure, the layered count, how many candidates contain a
closure, and how many have each excluded attribute (including being below
`minNodes`). A candidate can have several attributes, so those
counts overlap. Two candidates have the same shape when their kind tags and
types are equal and their expressions are equal once source regions are
erased, as `CafHoist.zeroRegions` describes. The remaining lines give counts
by kind and by size bucket, the 25 most common call heads, and the 20 specs
with the most candidates.

-}
report : String -> { minNodes : Int } -> Mono.MonoGraph -> String
report prefix hoistCfg (Mono.MonoGraph g) =
    let
        ( perSpec, allCands, ( specsWalked, layeredTotal ) ) =
            Array.foldl
                (\maybeNode ( acc, cands, ( sid, lay ) ) ->
                    case maybeNode of
                        Just node ->
                            let
                                ( cs, layN ) =
                                    walkNode node
                            in
                            ( if List.isEmpty cs then
                                acc

                              else
                                Dict.insert sid (List.length cs) acc
                            , cs ++ cands
                            , ( sid + 1, lay + layN )
                            )

                        Nothing ->
                            ( acc, cands, ( sid + 1, lay ) )
                )
                ( Dict.empty, [], ( 0, 0 ) )
                g.nodes

        total =
            List.length allCands

        vAbi =
            List.length (List.filter .valueAbi allCands)

        candNodes =
            List.sum (List.map .size allCands)

        closureContaining =
            List.length (List.filter .hasClosure allCands)

        bytesExcluded =
            List.length (List.filter .bytesEx allCands)

        debugContaining =
            List.length (List.filter .hasDebug allCands)

        scalarExcluded =
            List.length (List.filter (\c -> not c.valueAbi) allCands)

        fnTypeExcluded =
            List.length (List.filter .fnType allCands)

        belowMin =
            List.length (List.filter (\c -> c.size < hoistCfg.minNodes) allCands)

        eligible c =
            c.valueAbi
                && not c.fnType
                && not c.bytesEx
                && not c.hasDebug
                && c.size
                >= hoistCfg.minNodes

        eligibleV1 =
            List.length (List.filter eligible allCands)

        distinctShapes =
            List.foldl
                (\c buckets ->
                    case ( eligible c, c.dedupeKey ) of
                        ( True, Just ( tag, ty, zeroed ) ) ->
                            let
                                inner =
                                    Maybe.withDefault Mono.specMapEmpty (Dict.get tag buckets)

                                bucket =
                                    Maybe.withDefault [] (Mono.specMapGet ty inner)
                            in
                            if List.any (\z -> z == zeroed) bucket then
                                buckets

                            else
                                Dict.insert tag (Mono.specMapInsert ty (zeroed :: bucket) inner) buckets

                        _ ->
                            buckets
                )
                Dict.empty
                allCands
                |> Dict.foldl (\_ inner n -> Mono.specMapFoldl (\_ bucket m -> m + List.length bucket) n inner) 0

        byKind =
            List.foldl (\c d -> bump c.kind d) Dict.empty allCands

        sizeBucket c =
            if c.size <= 2 then
                "s1_2"

            else if c.size <= 9 then
                "s3_9"

            else if c.size <= 49 then
                "s10_49"

            else
                "s50plus"

        bySize =
            List.foldl (\c d -> bump (sizeBucket c) d) Dict.empty allCands

        byHead =
            List.foldl
                (\c d ->
                    if c.head == "" then
                        d

                    else
                        bump (renderHead c.head) d
                )
                Dict.empty
                allCands

        specName sid =
            case Array.get sid g.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global (ModuleName.Canonical _ moduleName) n, _ ) ->
                    moduleName ++ "." ++ Name.toElmString n

                Just ( Mono.Accessor f, _ ) ->
                    "accessor." ++ Name.toElmString f

                Nothing ->
                    "spec" ++ String.fromInt sid

        renderHead h =
            case String.split ":" h of
                [ "G", sid ] ->
                    String.toInt sid
                        |> Maybe.map specName
                        |> Maybe.withDefault h

                _ ->
                    String.dropLeft 2 h

        top n d =
            Dict.toList d
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take n
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        topSpecs =
            Dict.toList perSpec
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take 20
                |> List.map (\( sid, c ) -> specName sid ++ "=" ++ String.fromInt c)
                |> String.join " "

        renderDict d =
            Dict.toList d
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "
    in
    String.join "\n"
        [ prefix
            ++ ": specs="
            ++ String.fromInt specsWalked
            ++ " candidates="
            ++ String.fromInt total
            ++ " valueAbi="
            ++ String.fromInt vAbi
            ++ " candNodes="
            ++ String.fromInt candNodes
        , prefix
            ++ " v1: eligible="
            ++ String.fromInt eligibleV1
            ++ " distinctShapes="
            ++ String.fromInt distinctShapes
            ++ " layered="
            ++ String.fromInt layeredTotal
            ++ " closureContaining="
            ++ String.fromInt closureContaining
            ++ " bytesExcluded="
            ++ String.fromInt bytesExcluded
            ++ " debugContaining="
            ++ String.fromInt debugContaining
            ++ " scalarExcluded="
            ++ String.fromInt scalarExcluded
            ++ " fnTypeExcluded="
            ++ String.fromInt fnTypeExcluded
            ++ " belowMinNodes="
            ++ String.fromInt belowMin
        , prefix ++ " kinds: " ++ renderDict byKind
        , prefix ++ " sizes: " ++ renderDict bySize
        , prefix ++ " top heads: " ++ top 25 byHead
        , prefix ++ " top specs: " ++ topSpecs
        ]


{-| Adds one to the count for `k`, starting from zero.
-}
bump : String -> Dict String Int -> Dict String Int
bump k d =
    Dict.insert k (1 + Maybe.withDefault 0 (Dict.get k d)) d
