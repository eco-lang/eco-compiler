module LetNumberResultMapTest exposing (main)

{-| Probe: a `number` boxed in `Result`, mapped at `Float`. Extends the existing
tuple/record/list/Maybe boxed cases to `Result`. Correct: 1.5*30 = 45.

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
