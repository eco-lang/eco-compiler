module SingleCtorPairUnitIntTest exposing (main)

{-| Two single-constructor types: WrapUnit ((), boxed/constant) and WrapInt (Int, i64 unboxed).
Tests that case-matching on WrapUnit doesn't use WrapInt's unboxed layout.
-}

-- CHECK: unwrap_unit: ()
-- CHECK: unwrap_int: 77
-- CHECK: match_unit: "got_unit"

import Html exposing (text)


type WrapUnit
    = WrapUnit ()


type WrapInt
    = WrapInt Int


unwrapUnit : WrapUnit -> ()
unwrapUnit w =
    case w of
        WrapUnit u ->
            u


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchUnit : () -> String
matchUnit u =
    let
        w =
            WrapUnit u
    in
    case w of
        WrapUnit _ ->
            "got_unit"


main =
    let
        _ = Debug.log "unwrap_unit" (unwrapUnit (WrapUnit ()))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 77))
        _ = Debug.log "match_unit" (matchUnit ())
    in
    text "done"
