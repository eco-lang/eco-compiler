module Compiler.MonoOpt.NullableMaybe exposing
    ( admissiblePayload, censusClass
    , isMaybeType
    , NullStats, run, renderStats
    , Info, Choice, choose, rewriteStep, touchesNode, recordNullable
    )

{-| The nullable representation of `Maybe` and of Maybe-shaped user types
(plans/constructor-representation-levels.md §7, plans/constructor-representation-followups.md
F2): the field constructor's value is its field itself, and the nullary
constructor's is a constant word, the type's null word, that no value of the
field type can be. `Maybe`'s is the Empty constant and a user type's its
nullary constructor's null-cons word, unless the field type can be that word;
then it is a spare word, `0x6 | (level << 43)`, one level above the field
type's own (`assignNullWords`).

@docs admissiblePayload, censusClass
@docs isMaybeType
@docs NullStats, run, renderStats
@docs Info, Choice, choose, rewriteStep, touchesNode, recordNullable

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


-- ====== NULL WORDS (plans/constructor-representation-followups.md F2) ======


{-| What words a value of a type can be, as far as choosing a null word needs:
whether it can be the Empty constant, whether it can be a null-cons word (of
any index), and the highest spare-word level it can be (0 for none).
-}
type alias Words =
    { empty : Bool
    , nullCons : Bool
    , maxSpare : Int
    }


noWords : Words
noWords =
    { empty = False, nullCons = False, maxSpare = 0 }


unionWords : Words -> Words -> Words
unionWords a b =
    { empty = a.empty || b.empty, nullCons = a.nullCons || b.nullCons, maxSpare = max a.maxSpare b.maxSpare }


{-| The words of `t` that are not heap pointers, outside the nullable
representation: a nullable type answers through `nullableWords`.
-}
plainWords : (Mono.MonoType -> Maybe (List Mono.CtorShape)) -> Mono.MonoType -> Words
plainWords shapesOf t =
    case t of
        Mono.MString ->
            { noWords | empty = True }

        Mono.MUnit ->
            { noWords | empty = True }

        Mono.MList _ _ ->
            { noWords | empty = True }

        Mono.MRecord _ fields ->
            if Dict.isEmpty fields then
                { noWords | empty = True }

            else
                noWords

        Mono.MCustom _ home name _ ->
            if isMaybeType t then
                { noWords | empty = True }

            else if Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name then
                -- The kernel chooses its words (`Bytes`'s empty value is Empty).
                { noWords | empty = True, nullCons = True }

            else
                case shapesOf t of
                    Just shapes ->
                        { noWords | nullCons = List.any (\s -> List.isEmpty s.fieldTypes) shapes }

                    Nothing ->
                        { noWords | empty = True, nullCons = True }

        _ ->
            noWords


{-| Returns whether `t` can be a nullable type's payload at all: its values
must be boxed words of a known shape, so not Int, Float, Char, a type variable
or a kernel-owned type.
-}
admissiblePayload : Mono.MonoType -> Bool
admissiblePayload t =
    case t of
        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MVar _ _ ->
            False

        Mono.MCustom _ home name _ ->
            not (Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name)

        _ ->
            True


{-| The null words of the nullable types `cands` (each with its payload and
whether it is a `Maybe`), and the candidates dropped: those whose payload,
followed through nullable payloads, comes back to themselves (`type L = N | C L`,
where `C N` would be `N`'s word under any encoding), and those that would need a
level above `Mono.nullWordMaxIndex`. Each null word differs from every word the
payload can be: `Maybe` takes Empty unless the payload can be Empty, a user type
its nullary constructor's null-cons word unless the payload can be a null-cons
word, and otherwise a spare word one level above the payload's highest.
Dropping a candidate changes the words of the others, so it repeats until none
is dropped.
-}
assignNullWords :
    (Mono.MonoType -> Maybe (List Mono.CtorShape))
    -> List ( Mono.MonoType, { payload : Mono.MonoType, isMaybe : Bool, nullIndex : Int } )
    -> ( Mono.LayoutMap Mono.NullWord, List Mono.MonoType )
assignNullWords shapesOf cands =
    let
        attempt live dropped =
            let
                candMap =
                    List.foldl (\( k, c ) acc -> Mono.layoutMapInsert k c acc) Mono.layoutMapEmpty live

                -- The words of `t`, with the null words found so far; `Err t` names a candidate on a cycle
                -- or over the level limit.
                wordsOf visiting memo t =
                    case Mono.layoutMapGet t candMap of
                        Nothing ->
                            Ok ( plainWords shapesOf t, memo )

                        Just c ->
                            case Mono.layoutMapGet t memo of
                                Just nw ->
                                    wordsOf visiting memo c.payload
                                        |> Result.map (\( w, m ) -> ( unionWords (wordOfNull nw) w, m ))

                                Nothing ->
                                    if Mono.layoutSetMember t visiting then
                                        Err t

                                    else
                                        wordsOf (Mono.layoutSetInsert t visiting) memo c.payload
                                            |> Result.andThen
                                                (\( w, m ) ->
                                                    let
                                                        nw =
                                                            chooseNull c w
                                                    in
                                                    if nw.index > Mono.nullWordMaxIndex then
                                                        Err t

                                                    else
                                                        Ok ( unionWords (wordOfNull nw) w, Mono.layoutMapInsert t nw m )
                                                )

                result =
                    List.foldl
                        (\( k, _ ) acc -> Result.andThen (\memo -> Result.map Tuple.second (wordsOf Mono.layoutSetEmpty memo k)) acc)
                        (Ok Mono.layoutMapEmpty)
                        live
            in
            case result of
                Ok memo ->
                    ( memo, dropped )

                Err bad ->
                    attempt (List.filter (\( k, _ ) -> not (Mono.eqKeyLayout k bad)) live) (bad :: dropped)
    in
    attempt cands []


chooseNull : { payload : Mono.MonoType, isMaybe : Bool, nullIndex : Int } -> Words -> Mono.NullWord
chooseNull c w =
    if c.isMaybe && not w.empty then
        Mono.emptyNullWord

    else if not c.isMaybe && not w.nullCons then
        { nullCons = True, index = c.nullIndex }

    else
        { nullCons = False, index = w.maxSpare + 1 }


wordOfNull : Mono.NullWord -> Words
wordOfNull nw =
    if nw.nullCons then
        { noWords | nullCons = True }

    else if nw.index == 0 then
        { noWords | empty = True }

    else
        { noWords | maxSpare = nw.index }


{-| The census class of a nullable candidate's payload `t` (`CtorCensus`):
"inadm" when it cannot be a payload (`admissiblePayload`), "spare" when, outside
the nullable representation, a value of `t` can be the word the type would
otherwise take (Empty for `Maybe`, a null-cons word for a user type), and "adm"
otherwise.
-}
censusClass : (Mono.MonoType -> Maybe (List Mono.CtorShape)) -> Bool -> Mono.MonoType -> String
censusClass shapesOf isMaybe t =
    if not (admissiblePayload t) then
        "inadm"

    else
        let
            w =
                plainWords shapesOf t
        in
        if (isMaybe && w.empty) || (not isMaybe && w.nullCons) then
            "spare"

        else
            "adm"


-- ====== THE PASS ======


{-| What one run of the pass did.
-}
type alias NullStats =
    { candidates : Int
    , nullable : Int
    , excludedKv : Int
    , excludedMeets : Int
    , excludedRecursive : Int
    , spare : Int
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
        ++ ", recursive "
        ++ String.fromInt s.excludedRecursive
        ++ "; spare null words "
        ++ String.fromInt s.spare
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

A candidate is a `Maybe t`, or with `userTypes` a Maybe-shaped user type that
is not kernel-owned, whose field type `t` is `admissiblePayload`, that is not
kernel-visible at that instantiation. Each chosen type's null word is chosen by
`assignNullWords`, which drops a recursive candidate. A candidate that meets any other view in `meets` (taken on the
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
        admissibleCands : List ( Mono.MonoType, ( Info, { payload : Mono.MonoType, isMaybe : Bool, nullIndex : Int } ) )
        admissibleCands =
            Mono.layoutMapFoldl
                (\key shapes acc ->
                    case ( key, maybeShape shapes ) of
                        ( Mono.MCustom _ home name _, Just ( nullShape, valueShape ) ) ->
                            let
                                payload =
                                    List.head valueShape.fieldTypes |> Maybe.withDefault Mono.MUnit

                                ok =
                                    admissiblePayload payload
                                        && (isMaybeType key
                                                || (opts.userTypes
                                                        && not (Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name)
                                                   )
                                           )
                            in
                            if ok then
                                ( key
                                , ( { info =
                                        { nullCtor = nullShape.name
                                        , valueCtor = valueShape.name
                                        , nullWord = Mono.emptyNullWord
                                        }
                                    , nullIndex = indexOf nullShape.tag
                                    }
                                  , { payload = payload, isMaybe = isMaybeType key, nullIndex = nullShape.tag }
                                  )
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

        unexcluded =
            List.filter (\( key, _ ) -> not (Mono.layoutSetMember key excluded)) notKv

        ( nullWords, recursive ) =
            assignNullWords shapesOf (List.map (\( key, ( _, c ) ) -> ( key, c )) unexcluded)

        chosen =
            List.filterMap
                (\( key, ( info, _ ) ) ->
                    Mono.layoutMapGet key nullWords
                        |> Maybe.map (\nw -> ( key, { info | info = { nullCtor = info.info.nullCtor, valueCtor = info.info.valueCtor, nullWord = nw } } ))
                )
                unexcluded

        nullable : Mono.LayoutMap Info
        nullable =
            List.foldl (\( key, info ) acc -> Mono.layoutMapInsert key info acc) Mono.layoutMapEmpty chosen

    in
    { nullable = nullable
    , stats =
        { candidates = List.length admissibleCands
        , nullable = List.length chosen
        , excludedKv = List.length admissibleCands - List.length notKv
        , excludedMeets = List.length notKv - List.length unexcluded
        , excludedRecursive = List.length recursive
        , spare = List.length (List.filter (\( _, i ) -> not i.info.nullWord.nullCons && i.info.nullWord.index > 0) chosen)
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


{-| Returns whether `node` has a `case` whose decision tree tests a value of a
nullable type: whether `rewriteStep` can rewrite anything in it. The types are
looked up as they stand, so a type that a pass in the same traversal erases to a
nullable one is that pass's to report (`EraseWrappers.rewriteNodes` asks only
about a node that mentions no erased type). It reads the decision trees only,
not the types of the node's other expressions.
-}
touchesNode : Mono.LayoutMap Info -> Mono.MonoNode -> Bool
touchesNode nullable node =
    let
        hit path =
            Mono.layoutMapMember (Mono.dtPathType path) nullable

        deciderHits decider =
            case decider of
                Mono.Leaf _ ->
                    False

                Mono.Chain tests success failure ->
                    List.any (\( path, _ ) -> hit path) (NE.toList tests)
                        || deciderHits success
                        || deciderHits failure

                Mono.FanOut path edges fallback ->
                    hit path
                        || List.any (\( _, d ) -> deciderHits d) (NE.toList edges)
                        || deciderHits fallback

        exprHits expr =
            Traverse.foldExpr
                (\x found ->
                    found
                        || (case x of
                                Mono.MonoCase _ _ decider _ _ ->
                                    deciderHits decider

                                _ ->
                                    False
                           )
                )
                False
                expr
    in
    if Mono.layoutMapIsEmpty nullable then
        False

    else
        case node of
            Mono.MonoDefine expr _ ->
                exprHits expr

            Mono.MonoTailFunc _ expr _ ->
                exprHits expr

            Mono.MonoPortIncoming expr _ ->
                exprHits expr

            Mono.MonoPortOutgoing expr _ ->
                exprHits expr

            _ ->
                False


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
