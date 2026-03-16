module SingleCtorPairCharIntTest exposing (main)

{-| Two single-constructor types: WrapChar (Char, i16 unboxed) and WrapInt (Int, i64 unboxed).
Both have unboxed fields but different widths (i16 vs i64).
findSingleCtorUnboxedField could return the wrong width, causing truncation or garbage.
-}

-- CHECK: unwrap_char: 'A'
-- CHECK: unwrap_int: 256
-- CHECK: match_char: "got_A"

import Html exposing (text)


type WrapChar
    = WrapChar Char


type WrapInt
    = WrapInt Int


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchChar : Char -> String
matchChar c =
    let
        w =
            WrapChar c
    in
    case w of
        WrapChar x ->
            "got_" ++ String.fromChar x


main =
    let
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'A'))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 256))
        _ = Debug.log "match_char" (matchChar 'A')
    in
    text "done"
