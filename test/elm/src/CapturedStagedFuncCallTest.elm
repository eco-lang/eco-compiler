module CapturedStagedFuncCallTest exposing (main)

{-| A function parameter captured by a local helper and applied to two arguments works when the function passed in takes one argument and returns a function.

`makeAdder` is defined as `String -> (Int -> Int)`, returning a lambda. Passed to
`applyBoth` as `f : String -> Int -> Int` and called as `f a b` inside a local
function, it must receive both arguments, giving the same 15 as the direct
call.
-}

-- CHECK: direct: 15
-- CHECK: viaCapture: 15

import Html exposing (text)


{-| Takes one argument and returns a function adding the key's length to its input. -}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Applies `f` to `a` and `b` from inside a local function.
-}
applyBoth : (String -> Int -> Int) -> String -> Int -> Int
applyBoth f a b =
    let
        go () =
            f a b
    in
    go ()


main =
    let
        _ =
            Debug.log "direct" (makeAdder "hello" 10)

        _ =
            Debug.log "viaCapture" (applyBoth makeAdder "hello" 10)
    in
    text "done"
