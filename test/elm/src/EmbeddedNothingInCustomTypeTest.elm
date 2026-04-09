module EmbeddedNothingInCustomTypeTest exposing (main)

{-| Test Nothing stored in a custom type field, extracted, and pattern-matched.
-}

-- CHECK: result: -1

import Html exposing (text)


type Box a
    = Box a
    | BoxEmpty


main =
    let
        b =
            Box Nothing

        inner =
            case b of
                Box x ->
                    x

                BoxEmpty ->
                    Nothing

        result =
            case inner of
                Just x ->
                    x

                Nothing ->
                    -1

        _ = Debug.log "result" result
    in
    text "done"
