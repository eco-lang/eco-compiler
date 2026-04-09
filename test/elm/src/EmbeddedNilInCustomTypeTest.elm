module EmbeddedNilInCustomTypeTest exposing (main)

{-| Test empty list stored in a custom type, extracted, and checked.
-}

-- CHECK: isEmpty: True
-- CHECK: len: 0

import Html exposing (text)


type Holder a
    = Hold a
    | Empty


main =
    let
        h =
            Hold []

        list =
            case h of
                Hold xs ->
                    xs

                Empty ->
                    []

        _ = Debug.log "isEmpty" (List.isEmpty list)
        _ = Debug.log "len" (List.length list)
    in
    text "done"
