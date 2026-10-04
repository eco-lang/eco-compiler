module Compiler.GlobalOpt.Borrow.DsuTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.Borrow.Dsu`, the union-find that borrow
inference uses to group integer keys into classes. None of its operations
returns a `Maybe` or a `Result`, so a wrong `union` or `find` would silently
put keys in the wrong class; these tests check the operations directly.

A union-find (disjoint-set structure) divides the keys `0` to `n - 1` into
classes. Each class has one key, its root, that every member leads to through
the `parent` array. `union` merges the classes of two keys, `findRoot` returns
a key's root without changing anything, and `find` returns the root and also
points every key on the way straight at it (path compression). Each root has a
`rank`, which `union` uses to decide which of two roots stays a root.

There is no shared fixture. Each test builds a small structure with `empty`
and a few unions. The two fuzz tests apply a random list of up to 24 unions,
each between keys from `0` to `11`, to a structure of capacity 12. The model
test compares against a reference built from a `Dict` that maps each key to the
smallest key in its class. The tests read the `parent` and `rank` arrays
directly, which they can because `Dsu` is a record alias.

What the tests establish:

  - In `empty 5` each of the keys `0` to `4` is its own root.
  - After `union 1 3`, keys `1` and `3` have the same root, whether the union
    is written `union 1 3` or `union 3 1`, and still after the same union is
    applied twice.
  - Unions of `0` with `1` and `1` with `2` put `0` and `2` in one class.
  - Unions of `2` with `3` and `0` with `1` leave `0` and `2` in different
    classes.
  - Calling `find 0` twice returns the same root both times, the second call
    leaves `parent` unchanged, and after the first call `parent` at `0` is the
    root.
  - Seven unions that pair up the eight keys of `empty 8` into one class leave
    no rank above 3, and the random unions on 12 keys leave no rank above 4.
  - `grow` to a smaller capacity leaves `parent` unchanged; `grow` to a larger
    one keeps `0` and `1` in one class, adds `5` as its own root, and lets `5`
    be joined to the existing class by a later `union`.
  - After the random unions, the structure and the reference agree on whether
    `i` and `j` share a class, for every pair of keys with
    `0 <= i < j <= 11`.

Among what is not tested: keys outside the capacity, `size`, the `rank`
array after `grow`, which of two roots `union` keeps, and path compression of
a key below its root. The `find` test queries key `0`, which the unions before
it leave as the root, so no pointer is moved there.

-}

import Array
import Compiler.GlobalOpt.Borrow.Dsu as Dsu exposing (Dsu)
import Dict exposing (Dict)
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test)


{-| Collects every test in this module under one `Borrow.Dsu` group.
-}
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


{-| Checks the union-find laws on structures of capacity 5: every key starts
as its own root, and `union` joins two keys, joins them whichever way round it
is written or however often it is repeated, chains through a shared key, and
leaves keys it did not join apart.
-}
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


{-| Checks that repeating `find 0` gives the same root and no further change to
`parent`, and that after one `find 0` the `parent` entry for `0` is that root.

The unions `0`-`1`, `1`-`2`, `2`-`3` make `0` the root and point the other three
keys straight at it, so `0` is already its own parent and the test does not
exercise moving a pointer.

-}
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


{-| Checks that ranks stay small: at most 3 after balanced unions that join
eight keys into one class, and at most 4 after each generated list of unions on 12
keys.
-}
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


{-| Returns the largest rank held by any key of `d`, or 0 when `d` has no keys.
-}
maxRank : Dsu -> Int
maxRank d =
    Array.foldl max 0 d.rank



-- GROW


{-| Checks `grow` on a capacity-4 structure in which `0` and `1` are joined.
Growing to 3 leaves `parent` unchanged. Growing to 6 keeps `0` and `1` in one
class, makes the new key `5` its own root, and lets a later `union 1 5` put `5`
in the class of `0`.
-}
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


{-| Checks, for a random list of unions, that the structure built by `union`
and the `Dict` reference built by `naiveUnion` agree on whether each pair of
keys `i < j` from `0` to `11` shares a class. The test fails with the list of
pairs on which they disagree.
-}
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


{-| A generator of lists of between 0 and 24 unions, each a pair of keys from
`0` to `11`.
-}
opsFuzzer : Fuzzer (List ( Int, Int ))
opsFuzzer =
    Fuzz.listOfLengthBetween 0
        24
        (Fuzz.pair (Fuzz.intRange 0 11) (Fuzz.intRange 0 11))


{-| Returns a structure of capacity `n` with every pair in `ops` joined by
`union`, applied in list order.
-}
applyOps : Int -> List ( Int, Int ) -> Dsu
applyOps n ops =
    List.foldl (\( a, b ) d -> Dsu.union a b d) (Dsu.empty n) ops


{-| Every pair of keys `( i, j )` with `0 <= i < j <= 11`, the 66 pairs the
model test compares.
-}
allPairs : List ( Int, Int )
allPairs =
    List.concatMap
        (\i -> List.map (\j -> ( i, j )) (List.range (i + 1) 11))
        (List.range 0 11)



-- HELPERS


{-| Returns whether `a` and `b` have the same root in `d`, using `findRoot` so
that `d` is not changed.
-}
sameClass : Int -> Int -> Dsu -> Bool
sameClass a b d =
    Dsu.findRoot a d == Dsu.findRoot b d


{-| Returns the reference model for keys `0` to `n - 1` with every key in a
class of its own. The model maps each key to a label, the smallest key in its
class, and two keys share a class exactly when they share a label.
-}
naiveInit : Int -> Dict Int Int
naiveInit n =
    Dict.fromList (List.map (\i -> ( i, i )) (List.range 0 (n - 1)))


{-| Returns the reference model with the classes of `a` and `b` merged: every
key labelled with the larger of the two labels is relabelled with the smaller,
so each label remains the smallest key in its class.
-}
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


{-| Returns whether `a` and `b` have the same label in the reference model.
-}
naiveSame : Int -> Int -> Dict Int Int -> Bool
naiveSame a b d =
    Dict.get a d == Dict.get b d
