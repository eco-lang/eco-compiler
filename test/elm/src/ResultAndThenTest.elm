module ResultAndThenTest exposing (main)

{-| Checks that `Result.andThen` passes an `Ok` value to the next step and propagates an `Err` unchanged.

`half` returns `Ok (x // 2)` for an even `x` and `Err "odd"` otherwise. Chained onto
`Ok 42` it gives `Ok 21`, onto `Ok 41` it gives `Err "odd"`, and onto `Err "original"` the
error is passed through without calling `half`.
-}

-- CHECK: andThen1: Ok 21
-- CHECK: andThen2: Err "odd"
-- CHECK: andThen3: Err "original"

import Html exposing (text)


half x =
    if modBy 2 x == 0 then
        Ok (x // 2)
    else
        Err "odd"


main =
    let
        _ = Debug.log "andThen1" (Result.andThen half (Ok 42))
        _ = Debug.log "andThen2" (Result.andThen half (Ok 41))
        _ = Debug.log "andThen3" (Result.andThen half (Err "original"))
    in
    text "done"
