module Compiler.MonoOpt.NullableMaybe exposing
    ( admissible, admissibleNoConstants
    , isMaybeType
    , NullStats, run, renderStats
    , Info, Choice, choose, rewriteStep, touches, recordNullable
    )

{-| The nullable representation of `Maybe` (plans/constructor-representation-levels.md
§7): `Nothing` is the Empty constant and `Just x` is `x` itself, for a payload
type whose runtime word can never be Empty.

@docs admissible, admissibleNoConstants
@docs isMaybeType
@docs NullStats, run, renderStats
@docs Info, Choice, choose, rewriteStep, touches, recordNullable

-}

import Array
import Compiler.Core.Index as Index
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Kernel.Visibility as Visibility
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Data.NonEmptyList as NE
import Dict
import Set


{-| Returns whether `t` is `Maybe a` for some `a`.
-}
isMaybeType : Mono.MonoType -> Bool
isMaybeType t =
    case t of
        Mono.MCustom _ home name _ ->
            home == ModuleName.maybe && name == "Maybe"

        _ ->
            False


{-| Returns whether a value of type `t` is a boxed word that can never be the
Empty constant, so that `Maybe t` may represent `Just x` as `x` (MONO_033).

Every `MonoType` constructor is answered explicitly, so that a new one forces
a decision. A kernel-owned custom type is not admissible, because the kernel
chooses its word (`type Bytes = Bytes` has Empty for its empty value).

-}
admissible : Mono.MonoType -> Bool
admissible t =
    case t of
        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MBool ->
            True

        Mono.MString ->
            False

        Mono.MUnit ->
            False

        Mono.MList _ _ ->
            False

        Mono.MTuple _ _ ->
            True

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields)

        Mono.MCustom _ home name _ ->
            not (isMaybeType t)
                && not (Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name)

        Mono.MFunction _ _ _ _ ->
            True

        Mono.MVar _ _ ->
            False


{-| Returns whether no value of type `t` is an embedded constant (Empty,
True, False or a null-cons word), which a Maybe-shaped user type needs of its
payload (decision D2). `shapesOf` gives a custom type's constructors.
-}
admissibleNoConstants : (Mono.MonoType -> Maybe (List Mono.CtorShape)) -> Mono.MonoType -> Bool
admissibleNoConstants shapesOf t =
    case t of
        Mono.MTuple _ _ ->
            True

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields)

        Mono.MFunction _ _ _ _ ->
            True

        Mono.MCustom _ home name _ ->
            not (Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name)
                && (case shapesOf t of
                        Just shapes ->
                            not (List.isEmpty shapes) && List.all (\s -> not (List.isEmpty s.fieldTypes)) shapes

                        Nothing ->
                            False
                   )

        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MBool ->
            False

        Mono.MString ->
            False

        Mono.MUnit ->
            False

        Mono.MList _ _ ->
            False

        Mono.MVar _ _ ->
            False



-- ====== THE PASS ======


{-| What one run of the pass did.
-}
type alias NullStats =
    { candidates : Int
    , nullable : Int
    , excludedKv : Int
    , excludedMeets : Int
    , testsRewritten : Int
    }


{-| The statistics as one line for the inline report.
-}
renderStats : NullStats -> String
renderStats s =
    "nullable-maybe: "
        ++ String.fromInt s.nullable
        ++ " of "
        ++ String.fromInt s.candidates
        ++ " admissible types made nullable; excluded kernel-visible "
        ++ String.fromInt s.excludedKv
        ++ ", meeting another view "
        ++ String.fromInt s.excludedMeets
        ++ "; rewrote "
        ++ String.fromInt s.testsRewritten
        ++ " decision-tree tests"


{-| A chosen nullable type's constructors (`info`) and the nullary one's
declaration index, which the rewritten tests carry.
-}
type alias Info =
    { info : Mono.NullableInfo
    , nullIndex : Index.ZeroBased
    }


{-| The two constructors of a Maybe-shaped type, the nullary one first, with
the nullary one's declaration index.
-}
maybeShape : List Mono.CtorShape -> Maybe ( Mono.CtorShape, Mono.CtorShape )
maybeShape shapes =
    case shapes of
        [ a, b ] ->
            case ( a.fieldTypes, b.fieldTypes ) of
                ( [], [ _ ] ) ->
                    Just ( a, b )

                ( [ _ ], [] ) ->
                    Just ( b, a )

                _ ->
                    Nothing

        _ ->
            Nothing


indexOf : Int -> Index.ZeroBased
indexOf n =
    List.foldl (\_ i -> Index.next i) Index.first (List.range 1 n)


{-| Chooses the nullable types of `graph` and rewrites its decision trees
(plans/constructor-representation-levels.md §7, N1a and, with `userTypes`, N1b).

A candidate is a `Maybe t` whose `t` is `admissible`, or with `userTypes` a
Maybe-shaped user type whose field type has no embedded constants
(`admissibleNoConstants`, decision D2), that is not kernel-visible at that
instantiation. A candidate that meets any other view in `meets` (taken on the
graph this pass runs on) is excluded: an erased `Maybe a` reading a bare value
would take it for a `Custom`.

The chosen types are recorded in the graph's `repr.nullable`; the code
generator builds and reads their values in the nullable representation. This
pass only rewrites each decision-tree test of the field constructor on a
nullable value into the negated test of the nullary constructor, since a bare
field has no constructor tag to test.

-}
run : { userTypes : Bool } -> KernelVisible.KvSet -> List RepresentationMeets.Meet -> Mono.MonoGraph -> ( Mono.MonoGraph, NullStats )
run opts kv meets (Mono.MonoGraph g) =
    let
        choice =
            choose opts kv meets g.ctorShapes

        ( nodes1, rewritten ) =
            if Mono.layoutMapIsEmpty choice.nullable then
                ( g.nodes, 0 )

            else
                Array.foldl
                    (\maybeNode ( acc, n ) ->
                        case maybeNode of
                            Just node ->
                                let
                                    ( node1, n1 ) =
                                        rewriteNode choice.nullable node n
                                in
                                ( Array.push (Just node1) acc, n1 )

                            Nothing ->
                                ( Array.push Nothing acc, n )
                    )
                    ( Array.empty, 0 )
                    g.nodes

        stats =
            choice.stats
    in
    ( recordNullable choice (Mono.MonoGraph { g | nodes = nodes1 })
    , { stats | testsRewritten = rewritten }
    )


{-| The nullable types chosen for a graph, with what the choice found. The
decision-tree tests are rewritten afterwards, by `rewriteStep`.
-}
type alias Choice =
    { nullable : Mono.LayoutMap Info
    , stats : NullStats
    }


{-| Records the chosen nullable types in the graph's `repr.nullable`, which the
code generator reads.
-}
recordNullable : Choice -> Mono.MonoGraph -> Mono.MonoGraph
recordNullable choice (Mono.MonoGraph g) =
    let
        repr =
            g.repr
    in
    Mono.MonoGraph { g | repr = { repr | nullable = Mono.layoutMapMap (\_ i -> i.info) choice.nullable } }


{-| Chooses the nullable types of a graph whose constructors are `ctorShapes`,
as `run` does, without rewriting anything.
-}
choose : { userTypes : Bool } -> KernelVisible.KvSet -> List RepresentationMeets.Meet -> Mono.LayoutMap (List Mono.CtorShape) -> Choice
choose opts kv meets ctorShapes =
    let
        shapesOf t =
            Mono.layoutMapGet t ctorShapes

        -- Admissible candidates, before the kernel-visibility and meet exclusions.
        admissibleCands : List ( Mono.MonoType, Info )
        admissibleCands =
            Mono.layoutMapFoldl
                (\key shapes acc ->
                    case ( key, maybeShape shapes ) of
                        ( Mono.MCustom _ home name _, Just ( nullShape, valueShape ) ) ->
                            let
                                payload =
                                    List.head valueShape.fieldTypes |> Maybe.withDefault Mono.MUnit

                                ok =
                                    if isMaybeType key then
                                        admissible payload

                                    else
                                        opts.userTypes
                                            && not (Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name)
                                            && admissibleNoConstants shapesOf payload
                            in
                            if ok then
                                ( key
                                , { info =
                                        { nullCtor = nullShape.name
                                        , valueCtor = valueShape.name
                                        , constantBitTest = not (isMaybeType key)
                                        }
                                  , nullIndex = indexOf nullShape.tag
                                  }
                                )
                                    :: acc

                            else
                                acc

                        _ ->
                            acc
                )
                []
                ctorShapes

        notKv =
            List.filter (\( key, _ ) -> not (KernelVisible.isVisibleInstance kv key)) admissibleCands

        candKeys =
            List.map Tuple.first notKv |> Mono.layoutSetFromList

        isCand t =
            case t of
                Mono.MCustom _ _ _ _ ->
                    Mono.layoutSetMember t candKeys

                _ ->
                    False

        excluded =
            List.foldl
                (\m acc ->
                    if (isCand m.a || isCand m.b) && not (Mono.eqKeyLayout m.a m.b) then
                        acc
                            |> (if isCand m.a then
                                    Mono.layoutSetInsert m.a

                                else
                                    identity
                               )
                            |> (if isCand m.b then
                                    Mono.layoutSetInsert m.b

                                else
                                    identity
                               )

                    else
                        acc
                )
                Mono.layoutSetEmpty
                meets

        chosen =
            List.filter (\( key, _ ) -> not (Mono.layoutSetMember key excluded)) notKv

        nullable : Mono.LayoutMap Info
        nullable =
            List.foldl (\( key, info ) acc -> Mono.layoutMapInsert key info acc) Mono.layoutMapEmpty chosen

    in
    { nullable = nullable
    , stats =
        { candidates = List.length admissibleCands
        , nullable = List.length chosen
        , excludedKv = List.length admissibleCands - List.length notKv
        , excludedMeets = List.length notKv - List.length chosen
        , testsRewritten = 0
        }
    }


rewriteNode : Mono.LayoutMap Info -> Mono.MonoNode -> Int -> ( Mono.MonoNode, Int )
rewriteNode nullable node n =
    let
        go expr cnt =
            Traverse.traverseExpr (rewriteCase (nullableAt nullable)) cnt expr
    in
    case node of
        Mono.MonoDefine expr t ->
            Tuple.mapFirst (\e -> Mono.MonoDefine e t) (go expr n)

        Mono.MonoTailFunc params expr t ->
            Tuple.mapFirst (\e -> Mono.MonoTailFunc params e t) (go expr n)

        Mono.MonoPortIncoming expr t ->
            Tuple.mapFirst (\e -> Mono.MonoPortIncoming e t) (go expr n)

        Mono.MonoPortOutgoing expr t ->
            Tuple.mapFirst (\e -> Mono.MonoPortOutgoing e t) (go expr n)

        _ ->
            ( node, n )


{-| The rewrite of one expression in a bottom-up traversal (`Traverse.traverseExpr`):
a `case` whose decision tree tests a nullable value has those tests rewritten,
and `cnt` counts the rewritten tests. `norm` is applied to a tested value's type
before it is looked up in `nullable`, so that the step can run on a node whose
types a pass in the same traversal has not rewritten yet (`EraseWrappers`
passes `eraseType`).
-}
rewriteStep : (Mono.MonoType -> Mono.MonoType) -> Mono.LayoutMap Info -> Int -> Mono.MonoExpr -> ( Maybe Mono.MonoExpr, Int )
rewriteStep norm nullable cnt expr =
    if Mono.layoutMapIsEmpty nullable then
        ( Nothing, cnt )

    else
        rewriteCase (\path -> Mono.layoutMapGet (norm (Mono.dtPathType path)) nullable) cnt expr


{-| Returns whether `t` holds a custom type with the name of a nullable type:
whether a node with `t` in it can have a test `rewriteStep` rewrites. It reads
names only, so it may say yes for a type of that name that is not nullable (a
`Maybe` at another payload), never no for one that is; a type that a pass in
the same traversal erases to a nullable one is that pass's to report.
-}
touches : Mono.LayoutMap Info -> Mono.MonoType -> Bool
touches nullable =
    let
        names =
            Mono.layoutMapFoldl
                (\t _ acc ->
                    case t of
                        Mono.MCustom _ _ name _ ->
                            Set.insert name acc

                        _ ->
                            acc
                )
                Set.empty
                nullable

        go t =
            case t of
                Mono.MCustom _ _ name args ->
                    Set.member name names || List.any go args

                Mono.MList _ x ->
                    go x

                Mono.MTuple _ shape ->
                    List.any go (Mono.tupleToList shape)

                Mono.MRecord _ fields ->
                    List.any go (Dict.values fields)

                Mono.MFunction _ _ ps res ->
                    go res || List.any go ps

                _ ->
                    False
    in
    if Set.isEmpty names then
        \_ -> False

    else
        go


rewriteCase : (Mono.MonoDtPath -> Maybe Info) -> Int -> Mono.MonoExpr -> ( Maybe Mono.MonoExpr, Int )
rewriteCase nullableAtPath cnt expr =
    case expr of
        Mono.MonoCase label scrut decider jumps t ->
            let
                ( prepared, ( _, hoisted ) ) =
                    prepareChains nullableAtPath decider ( 1 + List.foldl (\( i, _ ) m -> max i m) -1 jumps, [] )

                ( decider1, cnt1 ) =
                    rewriteDecider nullableAtPath prepared cnt
            in
            if cnt1 == cnt then
                ( Nothing, cnt )

            else
                ( Just (Mono.MonoCase label scrut decider1 (jumps ++ List.reverse hoisted) t), cnt1 )

        _ ->
            ( Nothing, cnt )


{-| Gets a decision tree ready for `rewriteDecider`, which splits a chain of
several tests, one of which is on a nullable value, into nested one-test chains,
each with the chain's failure branch: the failure branch is then in the tree
once per test. An `Inline` leaf of it that holds a closure would put that
lambda in the graph more than once under one lambda id, and later passes can
transform the copies apart (MONO_019). So each such leaf becomes a `Jump` to a
new jump of the `case`, numbered from the first free index, and the copies
share it. Leaves without a closure stay inline.
-}
prepareChains : (Mono.MonoDtPath -> Maybe Info) -> Mono.Decider Mono.MonoChoice -> ( Int, List ( Int, Mono.MonoExpr ) ) -> ( Mono.Decider Mono.MonoChoice, ( Int, List ( Int, Mono.MonoExpr ) ) )
prepareChains nullableAtPath decider st =
    case decider of
        Mono.Leaf _ ->
            ( decider, st )

        Mono.Chain tests success failure ->
            let
                ( success1, st1 ) =
                    prepareChains nullableAtPath success st

                ( failure1, st2 ) =
                    prepareChains nullableAtPath failure st1

                testList =
                    NE.toList tests
            in
            if List.length testList > 1 && List.any (\( p, _ ) -> nullableAtPath p /= Nothing) testList then
                let
                    ( failure2, st3 ) =
                        hoistClosures failure1 st2
                in
                ( Mono.Chain tests success1 failure2, st3 )

            else
                ( Mono.Chain tests success1 failure1, st2 )

        Mono.FanOut path edges fallback ->
            let
                ( edges1, st1 ) =
                    NE.foldr
                        (\( test, d ) ( acc, s1 ) ->
                            let
                                ( d1, s2 ) =
                                    prepareChains nullableAtPath d s1
                            in
                            ( ( test, d1 ) :: acc, s2 )
                        )
                        ( [], st )
                        edges

                ( fallback1, st2 ) =
                    prepareChains nullableAtPath fallback st1
            in
            case edges1 of
                first :: rest ->
                    ( Mono.FanOut path (NE.Nonempty first rest) fallback1, st2 )

                [] ->
                    ( decider, st )


hoistClosures : Mono.Decider Mono.MonoChoice -> ( Int, List ( Int, Mono.MonoExpr ) ) -> ( Mono.Decider Mono.MonoChoice, ( Int, List ( Int, Mono.MonoExpr ) ) )
hoistClosures decider (( next, hoisted ) as st) =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            if holdsClosure e then
                ( Mono.Leaf (Mono.Jump next), ( next + 1, ( next, e ) :: hoisted ) )

            else
                ( decider, st )

        Mono.Leaf (Mono.Jump _) ->
            ( decider, st )

        Mono.Chain tests success failure ->
            let
                ( success1, st1 ) =
                    hoistClosures success st

                ( failure1, st2 ) =
                    hoistClosures failure st1
            in
            ( Mono.Chain tests success1 failure1, st2 )

        Mono.FanOut path edges fallback ->
            let
                ( edges1, st1 ) =
                    NE.foldr
                        (\( test, d ) ( acc, s1 ) ->
                            let
                                ( d1, s2 ) =
                                    hoistClosures d s1
                            in
                            ( ( test, d1 ) :: acc, s2 )
                        )
                        ( [], st )
                        edges

                ( fallback1, st2 ) =
                    hoistClosures fallback st1
            in
            case edges1 of
                first :: rest ->
                    ( Mono.FanOut path (NE.Nonempty first rest) fallback1, st2 )

                [] ->
                    ( decider, st )


holdsClosure : Mono.MonoExpr -> Bool
holdsClosure e =
    Traverse.foldExpr
        (\x acc ->
            case x of
                Mono.MonoClosure _ _ _ ->
                    True

                _ ->
                    acc
        )
        False
        e


nullableAt : Mono.LayoutMap Info -> Mono.MonoDtPath -> Maybe Info
nullableAt nullable path =
    Mono.layoutMapGet (Mono.dtPathType path) nullable


nullTestFor : Info -> Test.Test -> Test.Test
nullTestFor info test =
    case test of
        Test.IsCtor home _ _ numAlts ctorOpts ->
            Test.IsCtor home info.info.nullCtor info.nullIndex numAlts ctorOpts

        _ ->
            test


nullTestForFan : Info -> Test.FanTest -> Test.Test
nullTestForFan info test =
    case test of
        Test.FCtor home _ _ numAlts ctorOpts ->
            Test.IsCtor home info.info.nullCtor info.nullIndex numAlts ctorOpts

        _ ->
            Test.IsCtor ModuleName.maybe info.info.nullCtor info.nullIndex 2 Can.Normal


rewriteDecider : (Mono.MonoDtPath -> Maybe Info) -> Mono.Decider a -> Int -> ( Mono.Decider a, Int )
rewriteDecider nullableAtPath decider cnt =
    case decider of
        Mono.Leaf _ ->
            ( decider, cnt )

        Mono.Chain tests success failure ->
            let
                ( success1, c1 ) =
                    rewriteDecider nullableAtPath success cnt

                ( failure1, c2 ) =
                    rewriteDecider nullableAtPath failure c1

                testList =
                    NE.toList tests
            in
            if List.any (\( p, _ ) -> nullableAtPath p /= Nothing) testList then
                buildChain nullableAtPath testList success1 failure1 c2

            else
                ( Mono.Chain tests success1 failure1, c2 )

        Mono.FanOut path edges fallback ->
            let
                ( fallback1, c1 ) =
                    rewriteDecider nullableAtPath fallback cnt

                ( edges1, c2 ) =
                    NE.foldr
                        (\( test, d ) ( acc, c ) ->
                            let
                                ( d1, c_ ) =
                                    rewriteDecider nullableAtPath d c
                            in
                            ( ( test, d1 ) :: acc, c_ )
                        )
                        ( [], c1 )
                        edges
            in
            case nullableAtPath path of
                Just info ->
                    let
                        edgeFor name =
                            List.filterMap
                                (\( test, d ) ->
                                    case test of
                                        Test.FCtor _ n _ _ _ ->
                                            if n == name then
                                                Just d

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                                )
                                edges1
                                |> List.head
                                |> Maybe.withDefault fallback1

                        firstTest =
                            case edges1 of
                                ( t, _ ) :: _ ->
                                    t

                                [] ->
                                    Test.FCtor ModuleName.maybe info.info.nullCtor info.nullIndex 2 Can.Normal
                    in
                    ( Mono.Chain (NE.Nonempty ( path, nullTestForFan info firstTest ) [])
                        (edgeFor info.info.nullCtor)
                        (edgeFor info.info.valueCtor)
                    , c2 + 1
                    )

                Nothing ->
                    case edges1 of
                        first :: rest ->
                            ( Mono.FanOut path (NE.Nonempty first rest) fallback1, c2 )

                        [] ->
                            ( decider, cnt )


{-| A chain of `tests`, all of which must pass to reach `success`, as nested
chains in which every test on a nullable value tests the nullary constructor.
-}
buildChain : (Mono.MonoDtPath -> Maybe Info) -> List ( Mono.MonoDtPath, Test.Test ) -> Mono.Decider a -> Mono.Decider a -> Int -> ( Mono.Decider a, Int )
buildChain nullableAtPath tests success failure cnt =
    case tests of
        [] ->
            ( success, cnt )

        ( p, test ) :: rest ->
            let
                ( inner, c1 ) =
                    buildChain nullableAtPath rest success failure cnt
            in
            case ( nullableAtPath p, test ) of
                ( Just info, Test.IsCtor _ name _ _ _ ) ->
                    if name == info.info.nullCtor then
                        ( Mono.Chain (NE.Nonempty ( p, test ) []) inner failure, c1 + 1 )

                    else
                        ( Mono.Chain (NE.Nonempty ( p, nullTestFor info test ) []) failure inner, c1 + 1 )

                _ ->
                    ( Mono.Chain (NE.Nonempty ( p, test ) []) inner failure, c1 )
