module TestLogic.Monomorphize.ComparableKeyEncodingTest exposing (suite)

{-| A change to the string keys that identify a `MonoType`, to the hashes and
key equalities that must agree with them, or to the hash-consing table built on
the hashes, can change which types the compiler treats as the same, and so
which specializations it creates, without a compile error. These tests pin all
four. The hash-consing table is `Compiler.AST.Intern`: when it already holds a
composite type `==` to the one given, `Intern.hashCons` hands back that stored
copy, so that equal types can share one object.

Each function arrow in a `MonoType` carries a lambda-set annotation, a
`LambdaSetAnno`. Among its forms, `LSet` lists the functions a value of that
arrow type may be, `LVar` is a variable standing for such a set, and `LTop`
marks an arrow widened past any set.

A `MonoType` has two keys. Its _specialization key_ is the string
`Mono.toComparableMonoType` builds, which writes each arrow's lambda-set
annotation. Its _layout key_ is the same string with every arrow written `A(`,
whatever its annotation. The rules of the encoding belong to
`Compiler.AST.Monomorphized`. That module builds only the specialization key as
a string; `eqKeyLayout` and `layoutHashOf` work on the type directly. So this
module carries its own encoder, `referenceKey`, written with an explicit work
stack rather than the recursion `toComparableMonoType` uses: `referenceKey True`
builds the specialization key and `referenceKey False` the layout key. The
tests check `toComparableMonoType` against `referenceKey True`, and take every
layout key from `referenceKey False`.

The fixture is a _corpus_ of 438 types: the 24 types of `goldens`, 14 more
`handwritten` types, and 400 `generated` from fixed seeds. The pair tests use
`pairs`, every ordered pair of the first 90 corpus types, which include every
handwritten type. Only handwritten types carry `LPartial` annotations.

What the tests establish:

  - `toComparableMonoType` equals `referenceKey True` on every corpus type.
  - `toComparableMonoType` gives the literal string `goldens` lists for each of
    its 24 types, so a change made to both `toComparableMonoType` and
    `referenceKey` that alters any of those 23 keys still fails.
  - For one function type annotated `LSet [ 2, 5 ]`, the specialization key is
    `A[2,5](I->S)` and `referenceKey False` gives `A(I->S)`.
  - For one type whose only arrow is `LTop`, `toComparableMonoType` equals
    `referenceKey False`.
  - On every pair with no `LPartial` arrow, `eqKeySpec` is true exactly when
    the specialization keys are equal; on every pair, it is never true when
    they differ (with `LPartial` it is stricter than the key, as
    `Mono.eqKeySpec` documents). `eqKeyLayout` is true exactly when the
    `referenceKey False` keys are equal.
  - On every pair, equal specialization keys give equal `specHashOf` and equal
    layout keys give equal `layoutHashOf`.
  - On every corpus type, `specHashOf` and `layoutHashOf` lie in [0, 2^26).
  - Over the corpus, the number of distinct `specHashOf` values is at least
    90 % of the number of distinct specialization keys.
  - On every corpus type, `Intern.widenSets` with an empty table gives a type
    `eqKeySpec`-equal to `Mono.widenSets`'s.
  - Each corpus type, hash-consed twice in turn through one table, comes back
    `==` to itself, on the misses of the first pass and the hits of the
    second.
  - After hash-consing the whole corpus into one table, hash-consing the
    results again leaves its `size` unchanged, and a `disabled` table returns
    every corpus type `==` to itself.
  - With a read-only view of a table holding the first half of the corpus,
    every corpus type comes back `==` to itself, and the table's `size` is
    unchanged by each probe and by hash-consing the whole corpus through it.
  - `readOnly disabled` has `size` 0 and returns every corpus type `==` to
    itself; `readOnly` applied twice to a populated table keeps its `size`.
  - The corpus holds, somewhere in its types, every constructor of
    `MonoType` (each primitive, a variable of each constraint, a list, tuples
    of two and four elements, a record, a custom type and a function) and
    every form of arrow annotation (`LTop`, `LVar`, `LSet`, `LPartial`), so
    every arm of the encoder runs.
  - On every pair, `Intern.eqExact` agrees with `==`, and on the record pairs
    of `recordProbeCases` both give the expected answer.

Among what is not tested: `eqKeySpec` and `LPartial` beyond the soundness
direction above; how well `layoutHashOf` discriminates; whether a hit returns
the stored object rather than an equal one, which Elm cannot observe; a memo
hit carried over from an earlier `Intern.widenSets` call, and
`Intern.widenSets` on a read-only or disabled table; `Intern.entries`.

-}

import Bitwise
import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono exposing (Constraint(..), LambdaSetAnno(..), MonoType(..))
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Compiler.Data.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Dict
import Expect
import Test exposing (Test)


{-| All the tests of this module, in the order the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "MonoType comparable-key encoding"
        [ Test.test "specialization flavour matches the work-stack reference over the corpus" <|
            \_ ->
                corpus
                    |> List.filter (\t -> Mono.toComparableMonoType t /= referenceKey True t)
                    |> List.map Mono.monoTypeToDebugString
                    |> Expect.equalLists []
        , Test.test "golden keys" <|
            \_ ->
                List.map (\( t, _ ) -> Mono.toComparableMonoType t) goldens
                    |> Expect.equalLists (List.map Tuple.second goldens)
        , Test.test "layout flavour erases the lambda set the specialization flavour keeps" <|
            \_ ->
                let
                    setBearing =
                        Mono.mFunction (LSet [ 2, 5 ]) [ MInt ] MString
                in
                Expect.equal
                    ( "A[2,5](I->S)", "A(I->S)" )
                    ( Mono.toComparableMonoType setBearing
                    , referenceKey False setBearing
                    )
        , Test.test "the flavours agree on all-LTop types (why flag-off cannot see an annoSensitive slip)" <|
            \_ ->
                let
                    ltopOnly =
                        Mono.mFunction (LTop 7) [ Mono.mList MInt ] (Mono.mTuple [ MString, MFloat ])
                in
                Expect.equal
                    (Mono.toComparableMonoType ltopOnly)
                    (referenceKey False ltopOnly)
        , Test.test "K4: eqKeySpec is EXACTLY specialization-key equality (pairs without LPartial)" <|
            \_ ->
                pairs
                    |> List.filter (\( a, b ) -> not (hasPartial a || hasPartial b))
                    |> List.filter
                        (\( a, b ) ->
                            Mono.eqKeySpec a b
                                /= (Mono.toComparableMonoType a == Mono.toComparableMonoType b)
                        )
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K4: eqKeySpec never equates types whose specialization keys differ (all pairs)" <|
            -- With `LPartial` arrows `eqKeySpec` is stricter than the key, as
            -- `Mono.eqKeySpec` documents (`annoKeyEq` has no `LPartial`
            -- case), so only this direction holds on every pair.
            \_ ->
                pairs
                    |> List.filter
                        (\( a, b ) ->
                            Mono.eqKeySpec a b
                                && (Mono.toComparableMonoType a /= Mono.toComparableMonoType b)
                        )
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K4: eqKeyLayout is EXACTLY layout-key equality" <|
            \_ ->
                pairs
                    |> List.filter
                        (\( a, b ) ->
                            Mono.eqKeyLayout a b
                                /= (referenceKey False a == referenceKey False b)
                        )
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K4: equal keys imply equal hashes (the only direction the hash contract claims)" <|
            \_ ->
                pairs
                    |> List.filter
                        (\( a, b ) ->
                            (Mono.toComparableMonoType a == Mono.toComparableMonoType b)
                                && (Mono.specHashOf a /= Mono.specHashOf b)
                                || (referenceKey False a == referenceKey False b)
                                && (Mono.layoutHashOf a /= Mono.layoutHashOf b)
                        )
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K4: hashes stay inside the packing range" <|
            \_ ->
                corpus
                    |> List.filter
                        (\t ->
                            let
                                ( l, s ) =
                                    ( Mono.layoutHashOf t, Mono.specHashOf t )
                            in
                            l < 0 || l >= 67108864 || s < 0 || s >= 67108864
                        )
                    |> List.map Mono.monoTypeToDebugString
                    |> Expect.equalLists []
        , Test.test "K4: the hash discriminates (a degenerate hash would pass the contract but destroy lookup)" <|
            \_ ->
                let
                    distinctSpecHashes =
                        List.length (dedupeInt (List.sort (List.map Mono.specHashOf corpus)))

                    distinctSpecKeys =
                        List.length (dedupe (List.sort (List.map Mono.toComparableMonoType corpus)))
                in
                -- Collisions are allowed; the threshold rules out a hash so
                -- coarse that hash-keyed lookups degenerate into scans.
                if distinctSpecHashes * 10 >= distinctSpecKeys * 9 then
                    Expect.pass

                else
                    Expect.fail
                        ("hash too coarse: "
                            ++ String.fromInt distinctSpecHashes
                            ++ " distinct hashes for "
                            ++ String.fromInt distinctSpecKeys
                            ++ " distinct keys"
                        )
        , Test.test "K6: Intern.widenSets keys identically to Mono.widenSets over the corpus" <|
            -- `Intern.widenSets` is a hand copy of `Mono.widenSets` (Intern
            -- imports Monomorphized, so the copy cannot live there), and
            -- `Mono.widenSets`'s docstring requires the two to compute the
            -- same type. The comparison is `eqKeySpec`, which is coarser than
            -- `==`.
            \_ ->
                corpus
                    |> List.filter
                        (\t ->
                            not
                                (Mono.eqKeySpec
                                    (Tuple.first (Intern.widenSets t Intern.empty))
                                    (Mono.widenSets t)
                                )
                        )
                    |> List.map Mono.monoTypeToDebugString
                    |> Expect.equalLists []
        , Test.test "K6: hash-consing returns a type EQUAL to the one handed in (canonicalisation is not rewriting)" <|
            -- The corpus goes through one table twice, so the first pass runs
            -- the miss path (and the hit path for repeated types) and the
            -- second pass the hit path for every type.
            \_ ->
                (corpus ++ corpus)
                    |> List.foldl
                        (\t ( bad, table ) ->
                            let
                                ( t1, table1 ) =
                                    Intern.hashCons t table
                            in
                            if t1 == t then
                                ( bad, table1 )

                            else
                                ( Mono.monoTypeToDebugString t :: bad, table1 )
                        )
                        ( [], Intern.empty )
                    |> Tuple.first
                    |> Expect.equalLists []
        , Test.test "K6: a disabled table is the identity, and an empty one shares equal structures" <|
            \_ ->
                let
                    ( built, table ) =
                        List.foldl
                            (\t ( acc, i0 ) ->
                                let
                                    ( t1, i1 ) =
                                        Intern.hashCons t i0
                                in
                                ( t1 :: acc, i1 )
                            )
                            ( [], Intern.empty )
                            corpus

                    -- Hash-consing the canonical copies again must add no entry.
                    sizeAfterReplay =
                        Intern.size (List.foldl (\t i -> Tuple.second (Intern.hashCons t i)) table built)
                in
                Expect.equal
                    ( List.length corpus, Intern.size table, True )
                    ( List.length built
                    , sizeAfterReplay
                    , List.all (\t -> Tuple.first (Intern.hashCons t Intern.disabled) == t) corpus
                    )
        , Test.test "K7: a read-only table is transparent on both hit and miss, and never grows" <|
            -- Elm cannot observe object identity, so a hit and a miss look the
            -- same from here: both give back an equal type and a table of the
            -- same size. The two halves are probed separately so that both the
            -- hit path and the miss path run.
            \_ ->
                let
                    ( half, rest ) =
                        ( List.take (List.length corpus // 2) corpus
                        , List.drop (List.length corpus // 2) corpus
                        )

                    populated =
                        List.foldl (\t i -> Tuple.second (Intern.hashCons t i)) Intern.empty half

                    ro =
                        Intern.readOnly populated

                    -- Every composite here is in the table, so its probe hits.
                    hitsAreTransparent =
                        List.all
                            (\t ->
                                let
                                    ( canonical, i1 ) =
                                        Intern.hashCons t ro
                                in
                                (canonical == t) && (Intern.size i1 == Intern.size ro)
                            )
                            half

                    -- Composites here miss unless an equal one is in `half`.
                    missesArePreserved =
                        List.all
                            (\t ->
                                let
                                    ( kept, i1 ) =
                                        Intern.hashCons t ro
                                in
                                (kept == t) && (Intern.size i1 == Intern.size ro)
                            )
                            rest
                in
                Expect.equal
                    ( True, True, Intern.size populated )
                    ( hitsAreTransparent
                    , missesArePreserved
                    , Intern.size (List.foldl (\t i -> Tuple.second (Intern.hashCons t i)) ro corpus)
                    )
        , Test.test "K7: readOnly leaves a disabled table disabled and is idempotent" <|
            \_ ->
                let
                    populated =
                        List.foldl (\t i -> Tuple.second (Intern.hashCons t i)) Intern.empty corpus
                in
                Expect.equal
                    ( 0, Intern.size populated, True )
                    ( Intern.size (Intern.readOnly Intern.disabled)
                    , Intern.size (Intern.readOnly (Intern.readOnly populated))
                    , List.all
                        (\t -> Tuple.first (Intern.hashCons t (Intern.readOnly Intern.disabled)) == t)
                        corpus
                    )
        , Test.test "the corpus exercises every encoder arm (guards the differential tests against passing vacuously)" <|
            \_ ->
                let
                    present =
                        List.concatMap shapeTags corpus
                in
                [ "MInt", "MFloat", "MBool", "MChar", "MString", "MUnit", "MVar CEcoValue", "MVar CNumber", "MList", "MTuple 2", "MTuple 4", "MRecord", "MCustom", "LTop", "LSet", "LVar", "LPartial" ]
                    |> List.filter (\tag -> not (List.member tag present))
                    |> Expect.equalLists []
        , Test.test "K6: Intern.eqExact decides exactly (==) over the pair corpus" <|
            \_ ->
                pairs
                    |> List.filter (\( a, b ) -> Intern.eqExact a b /= (a == b))
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K6: record probes are content-exact and shape-blind" <|
            \_ ->
                recordProbeCases
                    |> List.filter
                        (\( _, ( a, b ), expected ) ->
                            not (Intern.eqExact a b == expected && (a == b) == expected)
                        )
                    |> List.map (\( label, _, _ ) -> label)
                    |> Expect.equalLists []
        ]


{-| Labelled pairs of record types, each with whether the two are equal.

Two of them target a comparison that looks only at hashes or at how the field
`Dict`s were built. Records with the same fields inserted in opposite orders
are equal. The single-field records `ab` and `ba` are not equal but carry the
same packed hash, because `mRecord` hashes a field name by its length only.

-}
recordProbeCases : List ( String, ( MonoType, MonoType ), Bool )
recordProbeCases =
    let
        rec pairsIn =
            Mono.mRecord (Dict.fromList pairsIn)
    in
    [ ( "same fields, opposite insertion order"
      , ( rec [ ( "a", MInt ), ( "b", MFloat ), ( "c", MBool ) ]
        , rec [ ( "c", MBool ), ( "b", MFloat ), ( "a", MInt ) ]
        )
      , True
      )
    , ( "strict subset"
      , ( rec [ ( "a", MInt ) ], rec [ ( "a", MInt ), ( "b", MFloat ) ] )
      , False
      )
    , ( "strict superset"
      , ( rec [ ( "a", MInt ), ( "b", MFloat ) ], rec [ ( "a", MInt ) ] )
      , False
      )
    , ( "one field renamed at equal length"
      , ( rec [ ( "ab", MInt ) ], rec [ ( "ba", MInt ) ] )
      , False
      )
    , ( "same names, one child differs"
      , ( rec [ ( "a", MInt ) ], rec [ ( "a", MFloat ) ] )
      , False
      )
    , ( "nested record, inner value equal but a distinct object"
      , ( rec [ ( "a", rec [ ( "x", MInt ) ] ) ]
        , rec [ ( "a", rec [ ( "x", MInt ) ] ) ]
        )
      , True
      )
    , ( "empty vs empty"
      , ( rec [], rec [] )
      , True
      )
    , ( "empty vs one field"
      , ( rec [], rec [ ( "a", MInt ) ] )
      , False
      )
    ]


{-| Ordered pairs of corpus types for the equality and hash tests: every
ordered pair, each type with itself included, of the first 90 corpus types,
which include all the `handwritten` types.
-}
pairs : List ( MonoType, MonoType )
pairs =
    let
        sample =
            List.take 90 corpus
    in
    List.concatMap (\a -> List.map (\b -> ( a, b )) sample) sample


{-| Returns a tag for each node of `monoType` and each arrow annotation in it:
the constructor's name, with the constraint of a variable and the arity of a
tuple, and `LTop`, `LVar`, `LSet` or `LPartial` for an arrow.
-}
shapeTags : MonoType -> List String
shapeTags monoType =
    case monoType of
        MInt ->
            [ "MInt" ]

        MFloat ->
            [ "MFloat" ]

        MBool ->
            [ "MBool" ]

        MChar ->
            [ "MChar" ]

        MString ->
            [ "MString" ]

        MUnit ->
            [ "MUnit" ]

        MVar _ CEcoValue ->
            [ "MVar CEcoValue" ]

        MVar _ CNumber ->
            [ "MVar CNumber" ]

        MList _ inner ->
            "MList" :: shapeTags inner

        MTuple _ elements ->
            ("MTuple " ++ String.fromInt (List.length elements)) :: List.concatMap shapeTags elements

        MRecord _ fields ->
            "MRecord" :: List.concatMap shapeTags (Dict.values fields)

        MCustom _ _ _ args ->
            "MCustom" :: List.concatMap shapeTags args

        MFunction _ anno args ret ->
            annoTag anno :: List.concatMap shapeTags (ret :: args)


{-| Returns the name of an arrow annotation's form.
-}
annoTag : LambdaSetAnno -> String
annoTag anno =
    case anno of
        LTop _ ->
            "LTop"

        LVar _ ->
            "LVar"

        LSet _ ->
            "LSet"

        LPartial _ ->
            "LPartial"


{-| Returns whether any arrow in `monoType` carries an `LPartial` annotation.
-}
hasPartial : MonoType -> Bool
hasPartial monoType =
    List.member "LPartial" (shapeTags monoType)


{-| Renders a pair as the two types' debug strings separated by `VS`, for
failure messages.
-}
describePair : ( MonoType, MonoType ) -> String
describePair ( a, b ) =
    Mono.monoTypeToDebugString a ++ "  VS  " ++ Mono.monoTypeToDebugString b


{-| Returns `sorted` with each run of equal adjacent values reduced to one,
which leaves one copy of each value when the list is sorted.
-}
dedupeInt : List Int -> List Int
dedupeInt sorted =
    case sorted of
        a :: b :: rest ->
            if a == b then
                dedupeInt (b :: rest)

            else
                a :: dedupeInt (b :: rest)

        other ->
            other


{-| Returns `sorted` with each run of equal adjacent strings reduced to one,
which leaves one copy of each string when the list is sorted.
-}
dedupe : List String -> List String
dedupe sorted =
    case sorted of
        a :: b :: rest ->
            if a == b then
                dedupe (b :: rest)

            else
                a :: dedupe (b :: rest)

        other ->
            other



-- ====== GOLDENS ======


{-| Types paired with the exact specialization key `toComparableMonoType` must
give them.

Between them the strings pin these parts of the encoding: a `CEcoValue`
variable with id 3 keys as `V0\u{0000}ecovalue`, and a `CNumber` variable as
`I`, like `MInt`; tuple elements and custom-type arguments are written last
to first, and record fields in descending name order; an `LTop` arrow is `A(`,
an `LVar n` arrow `Av<n>(`, so `LVar 0` and `LVar 1` key apart, an `LSet`
arrow lists its members in brackets, `A[](` when there are none, and an
`LPartial` arrow is written as the `LSet` with the same members.

-}
goldens : List ( MonoType, String )
goldens =
    [ ( MInt, "I" )
    , ( MFloat, "F" )
    , ( MBool, "B" )
    , ( MChar, "C" )
    , ( MString, "S" )
    , ( MUnit, "U" )
    , ( MVar (mvarId 3) CEcoValue, "V0\u{0000}ecovalue" )
    , ( MVar (mvarId 3) CNumber, "I" )
    , ( Mono.mList MInt, "L(I)" )
    , ( Mono.mList (Mono.mList MString), "L(L(S))" )
    , ( Mono.mTuple [ MInt, MFloat ], "T2(FI)" )
    , ( Mono.mTuple [ MInt, MFloat, MString ], "T3(SFI)" )
    , ( Mono.mRecord (Dict.fromList [ ( "a", MInt ), ( "b", MString ) ]), "R(bSaI)" )
    , ( Mono.mRecord Dict.empty, "R()" )
    , ( Mono.mCustom (ModuleName.Canonical ( "elm", "core" ) "Maybe") "Maybe" [ MInt ]
      , "Xelm\u{0000}core\u{0000}Maybe\u{0000}Maybe(I)"
      )
    , ( Mono.mCustom (ModuleName.Canonical ( "elm", "core" ) "Result") "Result" [ MString, MInt ]
      , "Xelm\u{0000}core\u{0000}Result\u{0000}Result(IS)"
      )
    , ( Mono.mFunction (LTop 7) [ MInt ] MString, "A(I->S)" )
    , ( Mono.mFunction (LVar 0) [ MInt ] MString, "Av0(I->S)" )
    , ( Mono.mFunction (LVar 1) [ MInt ] MString, "Av1(I->S)" )
    , ( Mono.mFunction (LTop 7) [ MInt, MFloat ] MUnit, "A(FI->U)" )
    , ( Mono.mFunction (LTop 7) [] MInt, "A(->I)" )
    , ( Mono.mFunction (LSet [ 1, 2 ]) [ MInt ] MString, "A[1,2](I->S)" )
    , ( Mono.mFunction (LSet []) [] MUnit, "A[](->U)" )
    , ( Mono.mFunction (LPartial [ 1, 2 ]) [ MInt ] MString, "A[1,2](I->S)" )
    ]



-- ====== CORPUS ======


{-| The types every corpus-wide test runs over: the handwritten types followed
by the generated ones.
-}
corpus : List MonoType
corpus =
    handwritten ++ generated


{-| The handwritten part of the corpus: the 24 `goldens` types, then fourteen
more.

The first seven add deep list nesting, a six-element tuple, a four-field
record, a record whose one field is itself a record, a custom type applied to
itself, and two function types with `LSet` annotations, one of them on a
function inside a record field.

The next five are function types that differ from one of those two, or from
each other, only in their annotations: an `LVar` head against an `LSet` head,
an `LVar` against an `LTop` on an inner arrow, inner arrows `LVar 0` against
`LVar 1`, and the record-argument type with `LVar 0` in place of its `LTop`
and `LSet`.

The last two put an inner arrow annotated `LPartial [ 3 ]` against the same
type with `LSet [ 3 ]`, whose keys are equal.

-}
handwritten : List MonoType
handwritten =
    List.map Tuple.first goldens
        ++ [ Mono.mList (Mono.mList (Mono.mList (Mono.mList MChar)))
           , Mono.mTuple [ MInt, MInt, MInt, MInt, MInt, MInt ]
           , Mono.mRecord (Dict.fromList [ ( "z", MInt ), ( "y", MFloat ), ( "x", MString ), ( "w", MUnit ) ])
           , Mono.mRecord (Dict.fromList [ ( "nested", Mono.mRecord (Dict.fromList [ ( "b", Mono.mList MInt ), ( "a", Mono.mTuple [ MBool, MChar ] ) ]) ) ])
           , Mono.mCustom (ModuleName.Canonical ( "author", "project" ) "Deep.Module.Name") "Tree" [ Mono.mCustom (ModuleName.Canonical ( "author", "project" ) "Deep.Module.Name") "Tree" [ MInt ] ]
           , Mono.mFunction (LSet [ 9 ]) [ Mono.mFunction (LTop 7) [ MInt ] MInt ] (Mono.mList (MVar (mvarId 1) CEcoValue))
           , Mono.mFunction (LTop 7) [ Mono.mRecord (Dict.fromList [ ( "f", Mono.mFunction (LSet [ 3, 4, 5 ]) [ MChar ] MBool ) ]) ] MUnit
           , Mono.mFunction (LVar 0) [ Mono.mFunction (LTop 7) [ MInt ] MInt ] (Mono.mList (MVar (mvarId 1) CEcoValue))
           , Mono.mFunction (LSet [ 9 ]) [ Mono.mFunction (LVar 0) [ MInt ] MInt ] (Mono.mList (MVar (mvarId 1) CEcoValue))
           , Mono.mFunction (LVar 0) [ Mono.mFunction (LVar 0) [ MChar ] MBool ] MUnit
           , Mono.mFunction (LVar 0) [ Mono.mFunction (LVar 1) [ MChar ] MBool ] MUnit
           , Mono.mFunction (LVar 0) [ Mono.mRecord (Dict.fromList [ ( "f", Mono.mFunction (LVar 0) [ MChar ] MBool ) ]) ] MUnit
           , Mono.mFunction (LTop 7) [ Mono.mFunction (LPartial [ 3 ]) [ MChar ] MBool ] MUnit
           , Mono.mFunction (LTop 7) [ Mono.mFunction (LSet [ 3 ]) [ MChar ] MBool ] MUnit
           ]


{-| The 400 generated corpus types, each from `genTypeWith True 4` on its own
fixed seed, so every one is a composite with at most four levels of composites.
The seeds are fixed, so every run tests the same types.
-}
generated : List MonoType
generated =
    List.range 1 400
        |> List.map (\i -> Tuple.first (genTypeWith True 4 (nextSeed (i * 7919))))


{-| Generates a type from `seed` as `genTypeWith` does with `compositeOnly`
off, so it may be a leaf at any depth.
-}
genType : Int -> Int -> ( MonoType, Int )
genType depth seed =
    genTypeWith False depth seed


{-| Generates a pseudo-random type from `seed0`, and returns it with the seed
to continue from.

At `depth` 0 or below the type is a leaf: one of the six primitives, or a
`CEcoValue` or `CNumber` variable with one of three ids. Above that,
`compositeOnly` restricts the choice to the five composites, and without it
leaves are possible too. The composites are a list, a tuple of one to four
elements, a record of one to four fields named from `fieldNames`, a custom type
of up to two arguments, and a function of up to two arguments. Children are
generated one level shallower with `compositeOnly` off.

-}
genTypeWith : Bool -> Int -> Int -> ( MonoType, Int )
genTypeWith compositeOnly depth seed0 =
    let
        seed =
            nextSeed seed0

        arm =
            if depth <= 0 then
                modBy 8 (seed // 11)

            else if compositeOnly then
                8 + modBy 5 (seed // 11)

            else
                modBy 13 (seed // 11)
    in
    case arm of
        0 ->
            ( MInt, seed )

        1 ->
            ( MFloat, seed )

        2 ->
            ( MBool, seed )

        3 ->
            ( MChar, seed )

        4 ->
            ( MString, seed )

        5 ->
            ( MUnit, seed )

        6 ->
            ( MVar (mvarId (modBy 3 seed)) CEcoValue, seed )

        7 ->
            ( MVar (mvarId (modBy 3 seed)) CNumber, seed )

        8 ->
            let
                ( inner, s ) =
                    genType (depth - 1) seed
            in
            ( Mono.mList inner, s )

        9 ->
            let
                ( els, s ) =
                    genTypes (modBy 4 seed + 1) (depth - 1) seed
            in
            ( Mono.mTuple els, s )

        10 ->
            let
                ( els, s ) =
                    genTypes (modBy 4 seed + 1) (depth - 1) seed
            in
            ( Mono.mRecord (Dict.fromList (List.map2 Tuple.pair fieldNames els)), s )

        11 ->
            let
                ( args, s ) =
                    genTypes (modBy 3 (seed // 97)) (depth - 1) seed
            in
            ( Mono.mCustom (canonicalAt (seed // 7)) (nameAt (seed // 13)) args, s )

        _ ->
            let
                ( args, s1 ) =
                    genTypes (modBy 3 (seed // 97)) (depth - 1) seed

                ( ret, s2 ) =
                    genType (depth - 1) s1
            in
            ( Mono.mFunction (annoAt (seed // 5)) args ret, s2 )


{-| Generates `n` types at `depth` with `genType`, passing the seed from each to
the next, and returns them with the last seed; `[]` when `n` is 0 or less.
-}
genTypes : Int -> Int -> Int -> ( List MonoType, Int )
genTypes n depth seed =
    if n <= 0 then
        ( [], seed )

    else
        let
            ( t, s1 ) =
                genType depth seed

            ( rest, s2 ) =
                genTypes (n - 1) depth s1
        in
        ( t :: rest, s2 )


{-| Returns the pseudo-random value that follows `seed`, in [0, 2^31 - 2].

Two multiply-and-reduce steps are interleaved with xor-shifts. Without the
shifts the step would be affine, and would turn the evenly spaced seeds
`generated` starts from into evenly spaced values. For a seed below 2^31 in
magnitude every product stays below 2^53, so the arithmetic is exact.

-}
nextSeed : Int -> Int
nextSeed seed =
    let
        a =
            Bitwise.xor seed (Bitwise.shiftRightZfBy 13 seed)

        b =
            modBy 2147483647 (a * 1103515 + 12345)

        c =
            Bitwise.xor b (Bitwise.shiftRightZfBy 7 b)
    in
    modBy 2147483647 (c * 48271 + 2654435)


{-| The field names generated records use, in the order they are inserted.
They are not in ascending order, so a record with two or more of them is
inserted out of `Dict` order.
-}
fieldNames : List String
fieldNames =
    [ "b", "a", "d", "c" ]


{-| Picks one of three modules from `seed`: `elm/core` `Maybe`,
`author/project` `Some.Nested.Module`, or `eco/kernel` `Eco.Kernel`.
-}
canonicalAt : Int -> ModuleName.Canonical
canonicalAt seed =
    case modBy 3 seed of
        0 ->
            ModuleName.Canonical ( "elm", "core" ) "Maybe"

        1 ->
            ModuleName.Canonical ( "author", "project" ) "Some.Nested.Module"

        _ ->
            ModuleName.Canonical ( "eco", "kernel" ) "Eco.Kernel"


{-| Picks one of three type names from `seed`: `Maybe`, `Tree` or `Wrapper`.
`genTypeWith` hands it and `canonicalAt` different parts of its seed, so a
name is not tied to one module, and the argument count is drawn from a third
part, so a name is not tied to one arity either.
-}
nameAt : Int -> String
nameAt seed =
    case modBy 3 seed of
        0 ->
            "Maybe"

        1 ->
            "Tree"

        _ ->
            "Wrapper"


{-| Picks an arrow annotation from `seed`: `LTop` with a provenance code from 0
to 7, `LSet []`, `LSet [ 7 ]`, `LSet [ 1, 2, 3 ]`, or `LVar` 0, 1 or 2. It never
gives `LPartial`.

The provenance code and the `LVar` number are taken from a different part of
the seed than the choice of form, so generated `LTop` arrows can differ in
their code (which the keys and hashes ignore) and every `LVar` number occurs. `LVar` is included so that
generated types, and not only the handwritten ones, carry set variables into
the key, equality and hash tests.

-}
annoAt : Int -> LambdaSetAnno
annoAt seed =
    case modBy 5 seed of
        0 ->
            LTop (modBy 8 (seed // 5))

        1 ->
            LSet []

        2 ->
            LSet [ 7 ]

        3 ->
            LVar (modBy 3 (seed // 5))

        _ ->
            LSet [ 1, 2, 3 ]


{-| Returns the `MVarId` `n` steps after `TypeIds.firstMVarId`, or
`firstMVarId` itself when `n` is 0 or less.
-}
mvarId : Int -> MVarId
mvarId n =
    List.foldl (\_ id -> Id.succ id) TypeIds.firstMVarId (List.range 1 n)



-- ====== REFERENCE ENCODER ======


{-| One entry on the reference encoder's work stack.

`WorkType` is a type still to be encoded. `WorkMarker` is a fragment written
out unchanged when it is popped: a closing bracket, the `->` between a
function's arguments and its result, or a record field name.

-}
type WorkItem
    = WorkType MonoType
    | WorkMarker String


{-| Builds the specialization key of `monoType` when `annoSensitive` is `True`,
and its layout key, with every arrow written `A(`, when it is `False`.
-}
referenceKey : Bool -> MonoType -> String
referenceKey annoSensitive monoType =
    referenceHelper annoSensitive [ WorkType monoType ] []
        |> List.reverse
        |> String.concat


{-| Runs the work stack `work` until it is empty, and returns `acc` with every
fragment written consed on, newest first.

A leaf writes its fragment at once. A composite writes its opening fragment
and pushes its children and its other markers: the closing `)`, a function's
`->` and a record's field names. Children are pushed with
`List.foldl`, so they are popped, and written, last to first; a record's fields
come out in descending name order, each name just before its type. With
`annoSensitive` an `LPartial` arrow is written exactly as an `LSet` with the
same members.

-}
referenceHelper : Bool -> List WorkItem -> List String -> List String
referenceHelper annoSensitive work acc =
    case work of
        [] ->
            acc

        (WorkMarker s) :: rest ->
            referenceHelper annoSensitive rest (s :: acc)

        (WorkType mt) :: rest ->
            case mt of
                MInt ->
                    referenceHelper annoSensitive rest ("I" :: acc)

                MFloat ->
                    referenceHelper annoSensitive rest ("F" :: acc)

                MBool ->
                    referenceHelper annoSensitive rest ("B" :: acc)

                MChar ->
                    referenceHelper annoSensitive rest ("C" :: acc)

                MString ->
                    referenceHelper annoSensitive rest ("S" :: acc)

                MUnit ->
                    referenceHelper annoSensitive rest ("U" :: acc)

                MVar _ constraint ->
                    case constraint of
                        CEcoValue ->
                            referenceHelper annoSensitive
                                rest
                                ("ecovalue" :: "\u{0000}" :: "0" :: "V" :: acc)

                        CNumber ->
                            referenceHelper annoSensitive rest ("I" :: acc)

                MList _ inner ->
                    referenceHelper annoSensitive
                        (WorkType inner :: WorkMarker ")" :: rest)
                        ("L(" :: acc)

                MTuple _ elementTypes ->
                    let
                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) elementTypes
                    in
                    referenceHelper annoSensitive newWork ("(" :: String.fromInt (List.length elementTypes) :: "T" :: acc)

                MRecord _ fields ->
                    let
                        newWork =
                            List.foldl
                                (\( name, ty ) w -> WorkMarker name :: WorkType ty :: w)
                                (WorkMarker ")" :: rest)
                                (Dict.toList fields)
                    in
                    referenceHelper annoSensitive newWork ("R(" :: acc)

                MCustom _ canonical name args ->
                    let
                        (ModuleName.Canonical ( author, project ) modName) =
                            canonical

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) args
                    in
                    referenceHelper annoSensitive newWork ("(" :: name :: "\u{0000}" :: modName :: "\u{0000}" :: project :: "\u{0000}" :: author :: "X" :: acc)

                MFunction _ anno args ret ->
                    let
                        annoKey =
                            if annoSensitive then
                                case anno of
                                    LTop _ ->
                                        "A("

                                    LVar n ->
                                        "Av" ++ String.fromInt n ++ "("

                                    LSet members ->
                                        "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                                    LPartial members ->
                                        "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                            else
                                "A("

                        newWork =
                            List.foldl (\t w -> WorkType t :: w)
                                (WorkMarker "->" :: WorkType ret :: WorkMarker ")" :: rest)
                                args
                    in
                    referenceHelper annoSensitive newWork (annoKey :: acc)
