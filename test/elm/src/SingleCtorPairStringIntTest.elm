module SingleCtorPairStringIntTest exposing (main)

{-| Two single-constructor types: WrapString (String, boxed) and WrapInt (Int, i64 unboxed).
Tests that case-matching on WrapString doesn't use WrapInt's unboxed i64 layout.
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
