module SingleCtorPairStringIntTest exposing (main)

{-| Values are extracted correctly from two single-constructor types in one module, one wrapping a `String` and one wrapping an `Int`.

`unwrapString` and `unwrapInt` return the wrapped `"hello"` and `99`.
`matchString` wraps a `String`, matches it back out and builds `"found_hello"`.

-}

-- CHECK: unwrap_str: "hello"
-- CHECK: unwrap_int: 99
-- CHECK: match_str: "found_hello"

import Html exposing (text)


type WrapString
    = WrapString String


type WrapInt
    = WrapInt Int


unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s ->
            s


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchString : String -> String
matchString s =
    let
        w =
            WrapString s
    in
    case w of
        WrapString x ->
            "found_" ++ x


main =
    let
        _ = Debug.log "unwrap_str" (unwrapString (WrapString "hello"))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 99))
        _ = Debug.log "match_str" (matchString "hello")
    in
    text "done"
