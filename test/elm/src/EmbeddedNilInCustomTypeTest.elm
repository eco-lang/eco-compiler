module EmbeddedNilInCustomTypeTest exposing (main)

{-| An empty list stored in a custom type constructor and taken back out by a
`case` is still empty, with length 0.
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
