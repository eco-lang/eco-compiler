module EmbeddedNothingInRecordTest exposing (main)

{-| Test Nothing stored in a record field, extracted, and pattern-matched.
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
