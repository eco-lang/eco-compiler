module Compiler.Data.BitSetTest exposing (suite)

{-| Tests for `BitSet.count` and `BitSet.remove`.

`count` carries the real risk. It popcounts a 32-bit word, and a word with bit
31 set is a NEGATIVE `Int` on the JS backend (`Bitwise.or` yields a signed
result) but a positive one below 2^32 on the native backend, where `Int` is
64-bit. The SWAR halving has to give the same answer either way, so the
word-boundary and full-word cases below are the point of this suite, not
padding.

-}

import Compiler.Data.BitSet as BitSet
import Expect
import Test exposing (Test)


insertAll : List Int -> BitSet.BitSet -> BitSet.BitSet
insertAll bits set =
    List.foldl BitSet.insert set bits


suite : Test
suite =
    Test.describe "BitSet"
        [ Test.describe "count"
            [ Test.test "empty is 0" <|
                \_ ->
                    BitSet.count BitSet.empty
                        |> Expect.equal 0
            , Test.test "allocated but unset is 0" <|
                \_ ->
                    BitSet.count (BitSet.fromSize 100)
                        |> Expect.equal 0
            , Test.test "counts distinct bits" <|
                \_ ->
                    BitSet.fromSize 100
                        |> insertAll [ 0, 5, 63, 99 ]
                        |> BitSet.count
                        |> Expect.equal 4
            , Test.test "re-inserting a bit does not double count" <|
                \_ ->
                    BitSet.fromSize 100
                        |> insertAll [ 7, 7, 7 ]
                        |> BitSet.count
                        |> Expect.equal 1
            , Test.test "bit 31 alone counts as 1 (word is negative on JS)" <|
                \_ ->
                    BitSet.fromSize 64
                        |> BitSet.insert 31
                        |> BitSet.count
                        |> Expect.equal 1
            , Test.test "a full word counts as 32" <|
                \_ ->
                    BitSet.fromSize 32
                        |> insertAll (List.range 0 31)
                        |> BitSet.count
                        |> Expect.equal 32
            , Test.test "an all-ones word written directly counts as 32" <|
                \_ ->
                    -- -1 forces the negative-word representation on every
                    -- backend, which is the case the multiply-free SWAR exists
                    -- to survive.
                    BitSet.fromSize 32
                        |> BitSet.setWord 0 -1
                        |> BitSet.count
                        |> Expect.equal 32
            , Test.test "counts across a word boundary" <|
                \_ ->
                    BitSet.fromSize 96
                        |> insertAll [ 31, 32, 33 ]
                        |> BitSet.count
                        |> Expect.equal 3
            , Test.test "a fully set multi-word set counts every bit" <|
                \_ ->
                    BitSet.fromSize 100
                        |> insertAll (List.range 0 99)
                        |> BitSet.count
                        |> Expect.equal 100
            , Test.test "out-of-range inserts are not counted" <|
                \_ ->
                    BitSet.fromSize 8
                        |> insertAll [ 3, 8, 100, -1 ]
                        |> BitSet.count
                        |> Expect.equal 1
            ]
        , Test.describe "remove"
            [ Test.test "removes membership" <|
                \_ ->
                    BitSet.fromSize 64
                        |> BitSet.insert 40
                        |> BitSet.remove 40
                        |> BitSet.member 40
                        |> Expect.equal False
            , Test.test "leaves neighbouring bits alone" <|
                \_ ->
                    let
                        set =
                            BitSet.fromSize 64
                                |> insertAll [ 39, 40, 41 ]
                                |> BitSet.remove 40
                    in
                    ( BitSet.member 39 set, BitSet.member 41 set, BitSet.count set )
                        |> Expect.equal ( True, True, 2 )
            , Test.test "removing an absent bit is a no-op" <|
                \_ ->
                    BitSet.fromSize 64
                        |> BitSet.insert 5
                        |> BitSet.remove 6
                        |> BitSet.count
                        |> Expect.equal 1
            , Test.test "removing out of range is a no-op" <|
                \_ ->
                    BitSet.fromSize 8
                        |> BitSet.insert 3
                        |> BitSet.remove 64
                        |> BitSet.remove -1
                        |> BitSet.count
                        |> Expect.equal 1
            , Test.test "a removed bit can be re-inserted" <|
                \_ ->
                    BitSet.fromSize 64
                        |> BitSet.insert 12
                        |> BitSet.remove 12
                        |> BitSet.insert 12
                        |> BitSet.member 12
                        |> Expect.equal True
            , Test.test "bit 31 survives removal of its word-mates" <|
                \_ ->
                    -- Clearing through `Bitwise.complement` on a 64-bit Int
                    -- sets every high bit; bit 31 must not be collateral.
                    BitSet.fromSize 32
                        |> insertAll (List.range 0 31)
                        |> BitSet.remove 0
                        |> BitSet.remove 30
                        |> (\set -> ( BitSet.member 31 set, BitSet.count set ))
                        |> Expect.equal ( True, 30 )
            ]
        , Test.describe "count agrees with member"
            [ Test.test "on an irregular pattern at CsePurity scale" <|
                \_ ->
                    -- Differential check: popcount against the already-trusted
                    -- `member`, at the ~40k width `CsePurity.analyze` actually
                    -- allocates. Hand-computed constants cannot catch a SWAR
                    -- step that only misbehaves on some word patterns; this
                    -- can, because the two implementations share nothing.
                    let
                        n =
                            40000

                        bits =
                            List.filter (\i -> modBy 7 i == 0 || modBy 31 i == 3)
                                (List.range 0 (n - 1))

                        set =
                            insertAll bits (BitSet.fromSize n)

                        byMember =
                            List.length
                                (List.filter (\i -> BitSet.member i set)
                                    (List.range 0 (n - 1))
                                )
                    in
                    BitSet.count set
                        |> Expect.equal byMember
            , Test.test "still agrees after removals" <|
                \_ ->
                    let
                        n =
                            5000

                        set =
                            BitSet.fromSize n
                                |> insertAll (List.range 0 (n - 1))
                                |> (\s -> List.foldl BitSet.remove s (List.filter (\i -> modBy 3 i == 0) (List.range 0 (n - 1))))

                        byMember =
                            List.length
                                (List.filter (\i -> BitSet.member i set)
                                    (List.range 0 (n - 1))
                                )
                    in
                    BitSet.count set
                        |> Expect.equal byMember
            ]
        , Test.describe "monotone removal, the CsePurity fixpoint shape"
            [ Test.test "seed then poison converges to the surviving bits" <|
                \_ ->
                    let
                        seeded =
                            BitSet.fromSize 200
                                |> insertAll (List.range 0 199)

                        poisoned =
                            List.foldl BitSet.remove seeded (List.range 0 149)
                    in
                    ( BitSet.count poisoned
                    , BitSet.member 149 poisoned
                    , BitSet.member 150 poisoned
                    )
                        |> Expect.equal ( 50, False, True )
            ]
        ]
