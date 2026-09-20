module Compiler.Data.HashMapTest exposing (suite)

{-| Tests for `HashMap.getBy`, the probe-typed lookup.

`getBy` frees the PROBE's type from the stored key's type, so a caller can store
keys that carry precomputed auxiliary data and still look them up with a bare
probe. The contract it has to honour is the one `get` already has — the probe
and the key it should find must hash equal and compare equal — and the risk is
entirely in the bucket scan, so every case below forces COLLISIONS with a
deliberately terrible hash (`modBy 3`). Without collisions a broken scan still
passes.

The stored key here is `( String, Int )`: the string is the identity and the Int
is the "precomputed" part the probe does not have. The probe is the bare string.

-}

import Data.HashMap as HashMap
import Expect
import Test exposing (Test)


{-| Deliberately terrible: three buckets, so every bucket holds several entries
and the scan is always exercised.
-}
hashKey : ( String, Int ) -> Int
hashKey ( name, _ ) =
    modBy 3 (String.length name)


hashProbe : String -> Int
hashProbe name =
    modBy 3 (String.length name)


eqKey : ( String, Int ) -> ( String, Int ) -> Bool
eqKey ( a, _ ) ( b, _ ) =
    a == b


eqProbe : String -> ( String, Int ) -> Bool
eqProbe probe ( name, _ ) =
    probe == name


names : List String
names =
    [ "a", "bb", "ccc", "dddd", "e", "ff", "ggg", "hhhh", "iiiii", "j" ]


populated : HashMap.HashMap ( String, Int ) String
populated =
    List.foldl
        (\( i, name ) m ->
            HashMap.insert hashKey eqKey ( name, i ) (String.toUpper name) m
        )
        HashMap.empty
        (List.indexedMap Tuple.pair names)


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
                -- "zz" collides with "bb"/"ff" (length 2), "z" with the length-1
                -- entries, "zzz" with the length-3 ones: the scan must walk a
                -- non-empty bucket and still answer Nothing.
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
