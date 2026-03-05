module ClosureCapture03Test exposing (main)

{-| Test closure captures Result variable used only in case destruct.

Uses explicit lambda return to force nested Function nodes.
The inner lambda captures `r`, which appears only as the root of
destruct paths. Tests a two-constructor type where both carry payloads.
-}

-- CHECK: ok: 42
-- CHECK: err: -1

import Html exposing (text)


type MyResult a b
    = Ok a
    | Err b


resultToInt : MyResult Int String -> (Int -> Int)
resultToInt r =
    \dummy ->
        case r of
            Ok n ->
                n

            Err _ ->
                -1


main =
    let
        _ = Debug.log "ok" (resultToInt (Ok 42) 0)
        _ = Debug.log "err" (resultToInt (Err "bad") 0)
    in
    text "done"
