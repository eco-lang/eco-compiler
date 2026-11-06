module PartialAppCaptureTypesTest exposing (main)

{-| Tests partial applications that hold a bound `Float`, `Char`, `Bool` or
`String` argument and return it when later given the remaining arguments.

`first3` returns its first of three arguments, so each partial application
logs the value it was given. A last case partially applies `addFloat` to
`1.5` and adds `2.0`.

-}

-- CHECK: float_cap: 1.5
-- CHECK: char_cap: 'x'
-- CHECK: bool_cap: True
-- CHECK: string_cap: "hello"
-- CHECK: combined: 3.5

import Html exposing (text)


first3 a b c =
    a


addFloat a b =
    a + b


main =
    let
        pFloat = first3 1.5
        pChar = first3 'x'
        pBool = first3 True
        pStr = first3 "hello"
        _ = Debug.log "float_cap" (pFloat 2 3)
        _ = Debug.log "char_cap" (pChar 2 3)
        _ = Debug.log "bool_cap" (pBool 2 3)
        _ = Debug.log "string_cap" (pStr 2 3)
        partialAdd = addFloat 1.5
        _ = Debug.log "combined" (partialAdd 2.0)
    in
    text "done"
