module Compiler.GlobalOpt.Borrow.DsuTest exposing (suite)

{-| Borrow-inference Phase 1 (§U1.3): union-find laws, path-compression
idempotence, rank sanity, grow, and a randomized agreement test against a
naive Dict reference.
-}

import Array
import Compiler.GlobalOpt.Borrow.Dsu as Dsu exposing (Dsu)
import Dict exposing (Dict)
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Borrow.Dsu"
        [ lawsTests
        , compressionTest
        , rankTests
        , growTest
        , modelTest
        ]



-- LAWS


lawsTests : Test
lawsTests =
    Test.describe "union-find laws"
        [ Test.test "empty n: every i is its own root" <|
            \_ ->
                let
                    d =
                        Dsu.empty 5
                in
                Expect.equal True
                    (List.all (\i -> Dsu.findRoot i d == i) (List.range 0 4))
        , Test.test "union a b then findRoot a == findRoot b" <|
            \_ ->
                let
                    d =
                        Dsu.union 1 3 (Dsu.empty 5)
                in
                Expect.equal (Dsu.findRoot 1 d) (Dsu.findRoot 3 d)
        , Test.test "union commutative in induced partition" <|
            \_ ->
                let
                    dAB =
                        Dsu.union 1 3 (Dsu.empty 5)

                    dBA =
                        Dsu.union 3 1 (Dsu.empty 5)
                in
                Expect.equal True
                    (sameClass 1 3 dAB && sameClass 1 3 dBA)
        , Test.test "union idempotent in partition" <|
            \_ ->
                let
                    d1 =
                        Dsu.union 1 3 (Dsu.empty 5)

                    d2 =
                        Dsu.union 1 3 d1
                in
                Expect.equal True (sameClass 1 3 d2)
        , Test.test "transitive chaining: union 0 1, union 1 2 ⇒ 0 ~ 2" <|
            \_ ->
                let
                    d =
                        Dsu.union 1 2 (Dsu.union 0 1 (Dsu.empty 5))
                in
                Expect.equal True (sameClass 0 2 d)
        , Test.test "distinct classes stay distinct" <|
            \_ ->
                let
                    d =
                        Dsu.union 0 1 (Dsu.union 2 3 (Dsu.empty 5))
                in
                Expect.equal False (sameClass 0 2 d)
        ]



-- PATH COMPRESSION


compressionTest : Test
compressionTest =
    Test.test "find: idempotent, parent[x] points at root after find" <|
        \_ ->
            let
                d0 =
                    List.foldl (\( a, b ) d -> Dsu.union a b d)
                        (Dsu.empty 8)
                        [ ( 0, 1 ), ( 1, 2 ), ( 2, 3 ) ]

                ( r1, d1 ) =
                    Dsu.find 0 d0

                ( r2, d2 ) =
                    Dsu.find 0 d1
            in
            Expect.equal
                { sameRoot = True, unchanged = True, parentIsRoot = True }
                { sameRoot = r1 == r2
                , unchanged = d2.parent == d1.parent
                , parentIsRoot = Array.get 0 d1.parent == Just r1
                }



-- RANK SANITY


rankTests : Test
rankTests =
    Test.describe "rank sanity"
        [ Test.test "balanced pairwise unions keep rank ≤ ceil(log2 n)" <|
            \_ ->
                let
                    d =
                        List.foldl (\( a, b ) dd -> Dsu.union a b dd)
                            (Dsu.empty 8)
                            [ ( 0, 1 ), ( 2, 3 ), ( 4, 5 ), ( 6, 7 ), ( 0, 2 ), ( 4, 6 ), ( 0, 4 ) ]
                in
                Expect.atMost 3 (maxRank d)
        , Test.fuzz opsFuzzer "arbitrary ops keep max rank ≤ ceil(log2 12) = 4" <|
            \ops ->
                Expect.atMost 4 (maxRank (applyOps 12 ops))
        ]


maxRank : Dsu -> Int
maxRank d =
    Array.foldl max 0 d.rank



-- GROW


growTest : Test
growTest =
    Test.test "grow: no-op below capacity, preserves partition, new indices are singletons and unionable" <|
        \_ ->
            let
                d0 =
                    Dsu.union 0 1 (Dsu.empty 4)

                noop =
                    Dsu.grow 3 d0

                d1 =
                    Dsu.grow 6 d0

                d2 =
                    Dsu.union 1 5 d1
            in
            Expect.equal
                { noopSame = True, stillUnioned = True, newSingleton = True, crossUnion = True }
                { noopSame = noop.parent == d0.parent
                , stillUnioned = sameClass 0 1 d1
                , newSingleton = Dsu.findRoot 5 d1 == 5
                , crossUnion = sameClass 0 5 d2
                }



-- RANDOMIZED MODEL TEST


modelTest : Test
modelTest =
    Test.fuzz opsFuzzer "Dsu agrees with a naive Dict reference on all 12×12 pairs" <|
        \ops ->
            let
                dsu =
                    applyOps 12 ops

                naive =
                    List.foldl (\( a, b ) d -> naiveUnion a b d) (naiveInit 12) ops

                mismatches =
                    List.filter
                        (\( i, j ) ->
                            sameClass i j dsu /= naiveSame i j naive
                        )
                        allPairs
            in
            Expect.equal [] mismatches


opsFuzzer : Fuzzer (List ( Int, Int ))
opsFuzzer =
    Fuzz.listOfLengthBetween 0 24
        (Fuzz.pair (Fuzz.intRange 0 11) (Fuzz.intRange 0 11))


applyOps : Int -> List ( Int, Int ) -> Dsu
applyOps n ops =
    List.foldl (\( a, b ) d -> Dsu.union a b d) (Dsu.empty n) ops


allPairs : List ( Int, Int )
allPairs =
    List.concatMap
        (\i -> List.map (\j -> ( i, j )) (List.range (i + 1) 11))
        (List.range 0 11)



-- HELPERS


sameClass : Int -> Int -> Dsu -> Bool
sameClass a b d =
    Dsu.findRoot a d == Dsu.findRoot b d


naiveInit : Int -> Dict Int Int
naiveInit n =
    Dict.fromList (List.map (\i -> ( i, i )) (List.range 0 (n - 1)))


naiveUnion : Int -> Int -> Dict Int Int -> Dict Int Int
naiveUnion a b d =
    let
        ra =
            Maybe.withDefault a (Dict.get a d)

        rb =
            Maybe.withDefault b (Dict.get b d)

        keep =
            min ra rb

        drop =
            max ra rb
    in
    Dict.map
        (\_ v ->
            if v == drop then
                keep

            else
                v
        )
        d


naiveSame : Int -> Int -> Dict Int Int -> Bool
naiveSame a b d =
    Dict.get a d == Dict.get b d
