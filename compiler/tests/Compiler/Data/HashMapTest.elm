module Compiler.Data.HashMapTest exposing (suite)

{-| Tests for `HashMap.getBy`, the lookup that finds a stored key from a probe
of a different type.

`getBy` answers a lookup by hashing the probe to pick a bucket, the group of
entries whose keys share a hash, and then scanning that bucket for the first
key that the supplied equality matches with the probe. With one entry per
bucket, a scan that returned the bucket's entry without consulting the equality
would find every stored key, so a scan that is wrong only when keys collide
could go unnoticed. These tests use a hash with three values, so that every
bucket holds several entries. The contract `getBy` relies on is stated in its
own docstring in `Data.HashMap`.

The fixture is `populated`, a map from `( String, Int )` keys to the upper-case
form of the string. The probe is the bare string. The key's equality compares
only the string, so the `Int` plays the part of data a stored key carries and a
probe does not. The ten names fall into all three buckets: `ccc` and `ggg` in
one; `a`, `dddd`, `e`, `hhhh` and `j` in the second; `bb`, `ff` and `iiiii` in
the third.

The tests establish:

  - Every name in the fixture is found through its probe, with its value.
  - For every name in the fixture, `getBy` with the probe gives the same
    result as `get` with the stored key. `get` is `getBy` called with the
    key's own hash and equality, so this compares the probe's pair with the
    key's pair on the same map.
  - The probes `z`, `zz`, `zzz` and `zzzz`, which are not in the map, give
    `Nothing`. Each of them hashes to a bucket that holds entries.
  - A probe into the empty map gives `Nothing`.
  - After `insert` with a key equal to a stored one, the probe finds the new
    value.
  - After `bb` is removed, its probe gives `Nothing` and the probe `ff`, from
    the same bucket, still finds its value.

Among what is not tested: `member`, `getHashed`, `insertNew`, `size` and
iteration order; removing the last entry of a bucket; and a probe that hashes
differently from the key it should match.

-}

import Data.HashMap as HashMap
import Expect
import Test exposing (Test)


{-| Returns the hash of a stored key: the length of its string modulo 3, so that
there are only three buckets.
-}
hashKey : ( String, Int ) -> Int
hashKey ( name, _ ) =
    modBy 3 (String.length name)


{-| Returns the hash of a probe, which agrees with `hashKey` on the key whose
string is the probe.
-}
hashProbe : String -> Int
hashProbe name =
    modBy 3 (String.length name)


{-| Returns whether two stored keys are equal, comparing their strings and
ignoring their `Int`s.
-}
eqKey : ( String, Int ) -> ( String, Int ) -> Bool
eqKey ( a, _ ) ( b, _ ) =
    a == b


{-| Returns whether a probe matches a stored key, which is when it equals the
key's string.
-}
eqProbe : String -> ( String, Int ) -> Bool
eqProbe probe ( name, _ ) =
    probe == name


{-| The names stored in the fixture map. Their lengths put at least two of them
in each of the three buckets.
-}
names : List String
names =
    [ "a", "bb", "ccc", "dddd", "e", "ff", "ggg", "hhhh", "iiiii", "j" ]


{-| The fixture map. Each name is stored under the key pairing it with its
position in `names`, with its upper-case form as the value.
-}
populated : HashMap.HashMap ( String, Int ) String
populated =
    List.foldl
        (\( i, name ) m ->
            HashMap.insert hashKey eqKey ( name, i ) (String.toUpper name) m
        )
        HashMap.empty
        (List.indexedMap Tuple.pair names)


{-| The tests of `HashMap.getBy` listed in the module docstring.
-}
suite : Test
suite =
    Test.describe "Data.HashMap.getBy"
        [ Test.test "finds every stored key through a bare probe" <|
            \_ ->
                names
                    |> List.filter
                        (\name ->
                            HashMap.getBy hashProbe eqProbe name populated
                                /= Just (String.toUpper name)
                        )
                    |> Expect.equalLists []
        , Test.test "agrees with get on every stored key" <|
            \_ ->
                names
                    |> List.indexedMap Tuple.pair
                    |> List.filter
                        (\( i, name ) ->
                            HashMap.getBy hashProbe eqProbe name populated
                                /= HashMap.get hashKey eqKey ( name, i ) populated
                        )
                    |> List.map Tuple.second
                    |> Expect.equalLists []
        , Test.test "misses in a POPULATED bucket return Nothing" <|
            \_ ->
                [ "z", "zz", "zzz", "zzzz" ]
                    |> List.filter
                        (\name -> HashMap.getBy hashProbe eqProbe name populated /= Nothing)
                    |> Expect.equalLists []
        , Test.test "a miss in an EMPTY map returns Nothing" <|
            \_ ->
                HashMap.getBy hashProbe eqProbe "a" HashMap.empty
                    |> Expect.equal Nothing
        , Test.test "the probe sees the newest value after a replace" <|
            \_ ->
                populated
                    |> HashMap.insert hashKey eqKey ( "ccc", 99 ) "REPLACED"
                    |> HashMap.getBy hashProbe eqProbe "ccc"
                    |> Expect.equal (Just "REPLACED")
        , Test.test "the probe stops finding a removed key, and finds its bucket neighbours" <|
            \_ ->
                let
                    without =
                        HashMap.remove hashKey eqKey ( "bb", 1 ) populated
                in
                ( HashMap.getBy hashProbe eqProbe "bb" without
                , HashMap.getBy hashProbe eqProbe "ff" without
                )
                    |> Expect.equal ( Nothing, Just "FF" )
        ]
