module SingleCtorPairUnitIntTest exposing (main)

{-| Pattern matching works on two single-constructor types in one module, one wrapping the unit value `()` and one wrapping an `Int`.

`unwrapUnit` returns the wrapped `()`, and `unwrapInt` the wrapped `77`.
`matchUnit` wraps `()` and matches it with a wildcard pattern, giving
`"got_unit"`.

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
