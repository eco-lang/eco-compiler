module Compiler.Data.BitSetTest exposing (suite)

{-| Tests that `BitSet.count` and `BitSet.remove` give the right answers,
including on the words where the two back ends disagree about the number a word
holds.

A `BitSet` keeps its bits in 32-bit words, and `count` adds up the set bits of
each word with bitwise arithmetic. A word with bit 31 set by `insert` is a
negative `Int` on the JavaScript back end, where `Bitwise.or` and
`Bitwise.shiftLeftBy` give signed 32-bit results, and a positive one on the
native back end, where `Int` is 64 bits wide. A word written through `setWord`
keeps the sign it was given, so the `-1` one test writes is negative on both.
These tests check `count` on words with bit 31 set, which is where the two
readings differ; a run checks the reading of the back end it runs on. They also
check `remove` on bits that share a word with other set bits.

Each test builds its own set, mostly with `BitSet.fromSize`, so that every word
the set can use exists from the start. `insertAll` inserts a list of indices.

What the tests establish:

  - `count` is 0 for `BitSet.empty` and for a 100-bit set with nothing
    inserted.
  - `count` is 4 after inserting 0, 5, 63 and 99, and 1 after inserting 7 three
    times.
  - `count` is 1 when bit 31 alone is set, 32 for a word with bits 0 to 31
    inserted, and 32 for a word written as `-1` through `BitSet.setWord`.
  - `count` is 3 after inserting 31, 32 and 33, which span two words, and 100
    after inserting every index of a 100-bit set.
  - Inserting 8, 100 and -1 into an 8-bit set adds nothing to `count`.
  - After a `remove`, `member` is `False` for the removed index; removing 40
    from 39, 40 and 41 leaves 39 and 41 members and a `count` of 2; and a
    removed index can be inserted again.
  - Removing an absent index, or the out-of-range indices 64 and -1 from an
    8-bit set, leaves `count` at 1.
  - Removing bits 0 and 30 from a full word leaves bit 31 a member and a
    `count` of 30.
  - `count` equals the number of indices for which `member` is `True` on a
    40,000-bit set holding every multiple of 7 and every index that leaves 3
    when divided by 31, and on a 5,000-bit set that was full before every
    multiple of 3 was removed. `member` reads one bit at a time, so this checks
    `count` on many more word patterns than the hand-computed cases.
  - Removing 0 to 149 from a full 200-bit set leaves a `count` of 50, with 149
    absent and 150 present.

Among what is not tested: `BitSet.emptyWithSize`, `BitSet.insertGrowing` and
`BitSet.removeGrowing`; `count` on a set whose words were added by `insert`
rather than by `fromSize`; `setWord` with any word other than `-1` or with an
index outside the set; and `member` on an index outside the set.

-}

import Compiler.Data.BitSet as BitSet
import Expect
import Test exposing (Test)


{-| Inserts each index in `bits` into `set`. An index outside the set's size is
skipped, as `BitSet.insert` skips it.
-}
insertAll : List Int -> BitSet.BitSet -> BitSet.BitSet
insertAll bits set =
    List.foldl BitSet.insert set bits


{-| The `BitSet` tests, grouped as `count`, `remove`, `count` against `member`,
and a long run of removals from a full set.
-}
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
