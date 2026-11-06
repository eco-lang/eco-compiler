module CovInlineSimplifyInlineIntoBodiesThatReuseAParameterNameInALambdaOrLocTest exposing (..)

{-| Checks that a program compiles in which a function's parameter name is
reused for a lambda parameter or a local function's parameter in a function it
calls.

`f` passes its parameter `x` to `g`, whose body has a lambda `\x -> x + y`.
`f2` passes its `x` to `h`, whose local function `go` also names its parameter
`x`. `testValue` also applies a lambda directly to `Just k`.

`testValue` takes two arguments and is logged without being called, so the
output is `<function>` and none of its body runs.

## eco

Taken from the program "Inline into bodies that reuse a parameter name in a lambda or local function" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k xs =
    ( f k xs
    , f2 k
    , (\t ->
        let
            z =
                k * 2
        in
        case t of
            Just 1 ->
                z

            Just 2 ->
                1

            _ ->
                z + 2
      )
        (Just k)
    )


f2 : Int -> Int
f2 x =
    h x + 1


h : Int -> Int
h y =
    let
        go x =
            if x <= 0 then
                y

            else
                go (x - 1)
    in
    go 3


f : Int -> List Int -> List Int
f x xs =
    g x xs


g : Int -> List Int -> List Int
g y xs =
    List.map (\x -> x + y) xs


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
