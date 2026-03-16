module SingleCtorPairCharFloatTest exposing (main)

{-| Two single-constructor types: WrapChar (Char, i16 unboxed) and WrapFloat (Float, f64 unboxed).
Both have unboxed fields but completely different types (i16 vs f64).
findSingleCtorUnboxedField could return the wrong type entirely.
-}

-- CHECK: unwrap_char: 'Z'
-- CHECK: unwrap_float: 1.5
-- CHECK: match_char: "got_Z"

import Html exposing (text)


type WrapChar
    = WrapChar Char


type WrapFloat
    = WrapFloat Float


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


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
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'Z'))
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 1.5))
        _ = Debug.log "match_char" (matchChar 'Z')
    in
    text "done"
