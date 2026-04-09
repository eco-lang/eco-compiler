module EmbeddedResultErrOkTest exposing (main)

{-| Test Err and Ok values flowing through Result.andThen callbacks.
-}

-- CHECK: chain1: Ok 11
-- CHECK: chain2: Err "bad"
-- CHECK: chain3: Err "negative"

import Html exposing (text)


validate : Int -> Result String Int
validate x =
    if x > 0 then
        Ok x

    else
        Err "negative"


increment : Int -> Result String Int
increment x =
    Ok (x + 1)


main =
    let
        chain1 =
            Ok 10
                |> Result.andThen validate
                |> Result.andThen increment

        chain2 =
            Err "bad"
                |> Result.andThen validate
                |> Result.andThen increment

        chain3 =
            Ok -5
                |> Result.andThen validate
                |> Result.andThen increment

        _ = Debug.log "chain1" chain1
        _ = Debug.log "chain2" chain2
        _ = Debug.log "chain3" chain3
    in
    text "done"
