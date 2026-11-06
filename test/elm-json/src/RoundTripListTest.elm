module RoundTripListTest exposing (main)

{-| The list `[ 1, 2, 3 ]` encoded with `Json.Encode.list` decodes back to the same list with `Json.Decode.list`.
-}

-- CHECK: rt_list: Ok [1,2,3]

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode

main =
    let
        _ = Debug.log "rt_list" (Decode.decodeString (Decode.list Decode.int) (Encode.encode 0 (Encode.list Encode.int [1, 2, 3])))
    in
    text "done"
