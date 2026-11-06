module LargeDispatchCaseTest exposing (main)

{-| Checks a `case` on a list of custom-type values whose branches contain a nested `case` on a String.

`dispatch` matches a one-element and a two-element list of `VInt`, then
chooses an operation by name. The checks take the `"add"`, `"sub"` and
`"negate"` branches and the outer default branch, reached with an empty list.
The other names, the inner default branches and the `VStr` and `VNone`
constructors are not used.

-}

-- CHECK: r1: 3
-- CHECK: r2: -1
-- CHECK: r3: -5
-- CHECK: r4: 42

import Html exposing (text)


type Value
    = VInt Int
    | VStr String
    | VNone


dispatch : List Value -> String -> Int
dispatch args name =
    case args of
        [ VInt a ] ->
            case name of
                "negate" ->
                    negate a

                "abs" ->
                    abs a

                _ ->
                    0

        [ VInt a, VInt b ] ->
            case name of
                "add" ->
                    a + b

                "sub" ->
                    a - b

                "mul" ->
                    a * b

                "max" ->
                    max a b

                _ ->
                    0

        _ ->
            42


main =
    let
        _ = Debug.log "r1" (dispatch [ VInt 1, VInt 2 ] "add")
        _ = Debug.log "r2" (dispatch [ VInt 1, VInt 2 ] "sub")
        _ = Debug.log "r3" (dispatch [ VInt 5 ] "negate")
        _ = Debug.log "r4" (dispatch [] "whatever")
    in
    text "done"
