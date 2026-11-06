module DictFromListToListRoundtripTest exposing (main)

{-| `Dict.fromList (Dict.toList d)` is equal under `==` to `d`, and two dicts holding the same
entries are equal, whatever order the entries were inserted in.

The tests use the keys 1 to 8, each mapped to ten times itself, inserted in a mixed order,
in descending order and in ascending order. The round trip is checked for the mixed and
descending dicts, and the descending dict is compared with the ascending one.

-}

-- CHECK: roundtripMixed: True
-- CHECK: roundtripDesc: True
-- CHECK: descEqualsAsc: True

import Dict exposing (Dict)
import Html exposing (text)


mixedInserts : Dict Int Int
mixedInserts =
    Dict.fromList [ ( 5, 50 ), ( 3, 30 ), ( 8, 80 ), ( 1, 10 ), ( 7, 70 ), ( 2, 20 ), ( 4, 40 ), ( 6, 60 ) ]


descInserts : Dict Int Int
descInserts =
    List.foldl (\i d -> Dict.insert i (i * 10) d) Dict.empty (List.reverse (List.range 1 8))


ascInserts : Dict Int Int
ascInserts =
    List.foldl (\i d -> Dict.insert i (i * 10) d) Dict.empty (List.range 1 8)


main =
    let
        _ = Debug.log "roundtripMixed" (mixedInserts == Dict.fromList (Dict.toList mixedInserts))
        _ = Debug.log "roundtripDesc"  (descInserts  == Dict.fromList (Dict.toList descInserts))
        _ = Debug.log "descEqualsAsc"  (descInserts  == ascInserts)
    in
    text "done"
