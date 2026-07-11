module LssSingletonFastDispatchTest exposing (main)

{-| LSS M3: a recursion-protected HOF called with one lambda literal (with a
capture). Under ECO_MONO_LSS=1 the internal `f acc` call site carries a
singleton lambda set and AbiCloning upgrades it to fast dispatch
(`_call_kind = "singleton_fast"` on the saturating eco.papExtend). Under the
default pipeline this exercises the plain generic-apply path — output must
be identical either way (LSS_005).
-}

-- CHECK: result: 26

import Html exposing (text)


repeatApply : (Int -> Int) -> Int -> Int -> Int
repeatApply f n acc =
    if n <= 0 then
        acc

    else
        repeatApply f (n - 1) (f acc)


main =
    let
        step =
            5

        _ =
            Debug.log "result" (repeatApply (\x -> x + step) 5 1)
    in
    text "done"
