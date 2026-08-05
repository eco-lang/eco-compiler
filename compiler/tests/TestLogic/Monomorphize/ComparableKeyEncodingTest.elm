module TestLogic.Monomorphize.ComparableKeyEncodingTest exposing (suite)

{-| Encoding gate for `toComparableMonoType` / `toComparableLayoutKey`.

Those two strings are specialization identity (MONO\_005/017/024) and the key
of every layout-intent dictionary in codegen, so a change to *how* a key is
built must leave the emitted bytes untouched. This suite pins that two ways:

  - **Differential.** `referenceKey` below is the previous explicit-work-stack
    encoder, kept verbatim as an oracle. Every type in a deterministic corpus
    must key identically under the oracle and the shipping implementation, in
    both flavours.
  - **Golden.** A handful of literal expected strings, so the oracle cannot
    drift silently alongside the implementation it is meant to check.

Both flavours are exercised on purpose. Flag-off graphs are all-`LTop`, where
the two functions agree byte-for-byte, so an `annoSensitive` regression is
invisible unless a lambda-set-bearing type is tested (§6 of
`plans/mono-comparable-key-optimization.md`).

-}

import Compiler.AST.Intern as Intern
import Compiler.AST.Monomorphized as Mono exposing (Constraint(..), LambdaSetAnno(..), MonoType(..))
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Bitwise
import Compiler.Data.Id as Id
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoType comparable-key encoding"
        [ Test.test "specialization flavour matches the work-stack reference over the corpus" <|
            \_ ->
                corpus
                    |> List.filter (\t -> Mono.toComparableMonoType t /= referenceKey True t)
                    |> List.map Mono.monoTypeToDebugString
                    |> Expect.equalLists []
        , Test.test "layout flavour matches the work-stack reference over the corpus" <|
            \_ ->
                corpus
                    |> List.filter (\t -> Mono.toComparableLayoutKey t /= referenceKey False t)
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
                    , Mono.toComparableLayoutKey setBearing
                    )
        , Test.test "the flavours agree on all-LTop types (why flag-off cannot see an annoSensitive slip)" <|
            \_ ->
                let
                    ltopOnly =
                        Mono.mFunction LTop [ Mono.mList MInt ] (Mono.mTuple [ MString, MFloat ])
                in
                Expect.equal
                    (Mono.toComparableMonoType ltopOnly)
                    (Mono.toComparableLayoutKey ltopOnly)
        , Test.test "K4: eqKeySpec is EXACTLY specialization-key equality" <|
            \_ ->
                pairs
                    |> List.filter
                        (\( a, b ) ->
                            Mono.eqKeySpec a b
                                /= (Mono.toComparableMonoType a == Mono.toComparableMonoType b)
                        )
                    |> List.map describePair
                    |> Expect.equalLists []
        , Test.test "K4: eqKeyLayout is EXACTLY layout-key equality" <|
            \_ ->
                pairs
                    |> List.filter
                        (\( a, b ) ->
                            Mono.eqKeyLayout a b
                                /= (Mono.toComparableLayoutKey a == Mono.toComparableLayoutKey b)
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
                                || (Mono.toComparableLayoutKey a == Mono.toComparableLayoutKey b)
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
                -- Collisions are legal, but the hash must recover most of the
                -- key's discrimination or every bucket degenerates to a scan.
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
            -- The interned twin is a hand-copy of `Mono.widenSets` living in
            -- `Compiler.AST.Intern` (that module cannot be imported by
            -- `Monomorphized`, which it imports). An arm-for-arm divergence would
            -- silently change the SPEC-REGISTRY KEY and therefore specialization
            -- identity, with no compile error — this is the gate for that.
            -- Key equality, not `==`: the threaded form rebuilds a record's field
            -- dict by ascending insert where `Dict.map` preserves the input tree
            -- shape, a difference `==` sees and `eqKeySpec` (which compares
            -- `Dict.toList`) correctly does not.
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
            \_ ->
                corpus
                    |> List.filter (\t -> Tuple.first (Intern.hashCons t Intern.empty) /= t)
                    |> List.map Mono.monoTypeToDebugString
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

                    -- Re-consing an already-canonical corpus must add nothing.
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
            -- The two properties `TypeSubst.applySubstPureRO` relies on:
            -- whatever comes back is EQUAL to what went in (so substituting the
            -- canonical object for a fresh one cannot change emitted code), and
            -- the table is returned unchanged whether the probe hit or missed.
            -- The second is what removes the need for state threading at any
            -- call site, and what keeps `Engine.withIntern`'s did-the-table-grow
            -- guard from ever firing for a read-only probe.
            --
            -- Physical sharing itself is deliberately NOT asserted here: Elm has
            -- no way to observe object identity, so the hit case and the miss
            -- case are indistinguishable from inside the language. The
            -- registered half and the unregistered half are exercised separately
            -- so both code paths run.
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

                    -- The registered half: every probe HITS.
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

                    -- The unregistered half: every probe MISSES.
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
                    allKeys =
                        String.concat
                            (List.map Mono.toComparableMonoType corpus
                                ++ List.map Mono.toComparableLayoutKey corpus
                            )
                in
                [ "I", "F", "B", "C", "S", "U", "V0\u{0000}ecovalue", "L(", "T2(", "T4(", "R(", "X", "A(", "A[", "->" ]
                    |> List.filter (\marker -> not (String.contains marker allKeys))
                    |> Expect.equalLists []
        ]


{-| All ordered pairs over a prefix of the corpus, plus every pair drawn from
the handwritten shapes (where near-misses — same shape, different lambda set or
`MVar` constraint — are concentrated).
-}
pairs : List ( MonoType, MonoType )
pairs =
    let
        sample =
            List.take 90 corpus
    in
    List.concatMap (\a -> List.map (\b -> ( a, b )) sample) sample
        ++ List.concatMap (\a -> List.map (\b -> ( a, b )) handwritten) handwritten


describePair : ( MonoType, MonoType ) -> String
describePair ( a, b ) =
    Mono.monoTypeToDebugString a ++ "  VS  " ++ Mono.monoTypeToDebugString b


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

    -- Children are emitted LAST-TO-FIRST (the work stack popped them reversed).
    , ( Mono.mTuple [ MInt, MFloat ], "T2(FI)" )
    , ( Mono.mTuple [ MInt, MFloat, MString ], "T3(SFI)" )

    -- Record fields likewise, in DESCENDING field-name order.
    , ( Mono.mRecord (Dict.fromList [ ( "a", MInt ), ( "b", MString ) ]), "R(bSaI)" )
    , ( Mono.mRecord Dict.empty, "R()" )
    , ( Mono.mCustom (IO.Canonical ( "elm", "core" ) "Maybe") "Maybe" [ MInt ]
      , "Xelm\u{0000}core\u{0000}Maybe\u{0000}Maybe(I)"
      )
    , ( Mono.mCustom (IO.Canonical ( "elm", "core" ) "Result") "Result" [ MString, MInt ]
      , "Xelm\u{0000}core\u{0000}Result\u{0000}Result(IS)"
      )
    , ( Mono.mFunction LTop [ MInt ] MString, "A(I->S)" )
    , ( Mono.mFunction LTop [ MInt, MFloat ] MUnit, "A(FI->U)" )
    , ( Mono.mFunction LTop [] MInt, "A(->I)" )
    , ( Mono.mFunction (LSet [ 1, 2 ]) [ MInt ] MString, "A[1,2](I->S)" )
    , ( Mono.mFunction (LSet []) [] MUnit, "A[](->U)" )
    ]



-- ====== CORPUS ======


corpus : List MonoType
corpus =
    handwritten ++ generated


handwritten : List MonoType
handwritten =
    List.map Tuple.first goldens
        ++ [ Mono.mList (Mono.mList (Mono.mList (Mono.mList MChar)))
           , Mono.mTuple [ MInt, MInt, MInt, MInt, MInt, MInt ]
           , Mono.mRecord (Dict.fromList [ ( "z", MInt ), ( "y", MFloat ), ( "x", MString ), ( "w", MUnit ) ])
           , Mono.mRecord (Dict.fromList [ ( "nested", Mono.mRecord (Dict.fromList [ ( "b", Mono.mList MInt ), ( "a", Mono.mTuple [ MBool, MChar ] ) ]) ) ])
           , Mono.mCustom (IO.Canonical ( "author", "project" ) "Deep.Module.Name") "Tree" [ Mono.mCustom (IO.Canonical ( "author", "project" ) "Deep.Module.Name") "Tree" [ MInt ] ]
           , Mono.mFunction (LSet [ 9 ]) [ Mono.mFunction LTop [ MInt ] MInt ] (Mono.mList (MVar (mvarId 1) CEcoValue))
           , Mono.mFunction LTop [ Mono.mRecord (Dict.fromList [ ( "f", Mono.mFunction (LSet [ 3, 4, 5 ]) [ MChar ] MBool ) ]) ] MUnit
           ]


{-| A deterministic pseudo-random corpus: enough structural variety (nesting,
breadth, both constraints, both annotations, record field orders that differ
from insertion order) that an ordering slip in any arm shows up. Deterministic
rather than fuzzed because the suite runs at `--fuzz 1`.
-}
generated : List MonoType
generated =
    List.range 1 400
        |> List.map (\i -> Tuple.first (genTypeWith True 4 (nextSeed (i * 7919))))


genType : Int -> Int -> ( MonoType, Int )
genType depth seed =
    genTypeWith False depth seed


{-| `compositeOnly` forces a container arm, which is what the roots want: a
corpus dominated by bare `MInt`s would spend its 400 entries comparing the
seven trivial leaf keys.
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
                    genTypes (modBy 3 seed) (depth - 1) seed
            in
            ( Mono.mCustom (canonicalAt seed) (nameAt seed) args, s )

        _ ->
            let
                ( args, s1 ) =
                    genTypes (modBy 3 seed) (depth - 1) seed

                ( ret, s2 ) =
                    genType (depth - 1) s1
            in
            ( Mono.mFunction (annoAt seed) args ret, s2 )


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


{-| A xorshift-flavoured mix, NOT a plain LCG. An LCG is affine, so it maps the
arithmetic progression of starting seeds below onto another arithmetic
progression, and `modBy <arms>` of that is periodic — the first cut of this
generator built 428 types holding only 156 distinct keys. The shifts break the
affinity. Products stay under 2^53 so the arithmetic is exact.
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


{-| Deliberately NOT in sorted order: a record built from these has an
insertion order different from its `Dict` order.
-}
fieldNames : List String
fieldNames =
    [ "b", "a", "d", "c" ]


canonicalAt : Int -> IO.Canonical
canonicalAt seed =
    case modBy 3 seed of
        0 ->
            IO.Canonical ( "elm", "core" ) "Maybe"

        1 ->
            IO.Canonical ( "author", "project" ) "Some.Nested.Module"

        _ ->
            IO.Canonical ( "eco", "kernel" ) "Eco.Kernel"


nameAt : Int -> String
nameAt seed =
    case modBy 3 seed of
        0 ->
            "Maybe"

        1 ->
            "Tree"

        _ ->
            "Wrapper"


annoAt : Int -> LambdaSetAnno
annoAt seed =
    case modBy 4 seed of
        0 ->
            LTop

        1 ->
            LSet []

        2 ->
            LSet [ 7 ]

        _ ->
            LSet [ 1, 2, 3 ]


mvarId : Int -> MVarId
mvarId n =
    List.foldl (\_ id -> Id.succ id) TypeIds.firstMVarId (List.range 1 n)



-- ====== REFERENCE ORACLE (the previous explicit-work-stack encoder) ======


type WorkItem
    = WorkType MonoType
    | WorkMarker String


referenceKey : Bool -> MonoType -> String
referenceKey annoSensitive monoType =
    referenceHelper annoSensitive [ WorkType monoType ] []
        |> List.reverse
        |> String.concat


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
                        (IO.Canonical ( author, project ) modName) =
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
                                    LTop ->
                                        "A("

                                    LSet members ->
                                        "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                            else
                                "A("

                        newWork =
                            List.foldl (\t w -> WorkType t :: w)
                                (WorkMarker "->" :: WorkType ret :: WorkMarker ")" :: rest)
                                args
                    in
                    referenceHelper annoSensitive newWork (annoKey :: acc)
