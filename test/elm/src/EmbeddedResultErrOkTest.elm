module EmbeddedResultErrOkTest exposing (main)

{-| `Result.andThen` passes an `Ok` value to its callback, passes an `Err`
through untouched, and stops at the first callback that returns `Err`.

Each chain applies `validate` (which returns `Err "negative"` unless its
argument is positive) and then `increment`. Starting from `Ok 10` gives `Ok 11`;
starting from `Err "bad"` keeps that error; starting from `Ok -5` gives `Err
"negative"` from `validate`.

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
