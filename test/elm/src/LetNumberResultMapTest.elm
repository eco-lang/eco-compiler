module LetNumberResultMapTest exposing (main)

{-| An integer literal inside `Ok`, mapped by `Result.map`, is used as a `Float`:
`Result.map (\x -> round (x * 1.5)) (Ok 30)`, unwrapped by a `case`, logs 45.
-}

-- CHECK: result: 45

import Html exposing (text)


main =
    let
        res =
            Ok 30

        mapped =
            Result.map (\x -> round (x * 1.5)) res

        result =
            case mapped of
                Ok v ->
                    v

                Err _ ->
                    0

        _ =
            Debug.log "result" result
    in
    text "done"
