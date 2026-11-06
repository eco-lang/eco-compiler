module EmbeddedNothingInRecordTest exposing (main)

{-| A `Nothing` stored in a record field and read back with `.value` matches the
`Nothing` pattern.
-}

-- CHECK: result: "nothing"

import Html exposing (text)


type alias MyRecord =
    { value : Maybe Int
    , label : String
    }


main =
    let
        r =
            { value = Nothing, label = "test" }

        result =
            case r.value of
                Just _ ->
                    "just"

                Nothing ->
                    "nothing"

        _ = Debug.log "result" result
    in
    text "done"
