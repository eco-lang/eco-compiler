module FunctionValueChoiceTest exposing (main)

{-| The programs of findings F14 and F15, run end to end.

F14: `chooseIf` and `chooseElse` are top-level values, not functions, each
defined by an `if` choosing between two lambdas, and each is both called and
passed to `List.foldl`. The two uses demanded the value at types differing only
in lambda sets, and before the fix the monomorphizer gave one (global, type)
key two specializations (MONO\_005).

F15: `chooseC` returns a pair of `Int`s from an `if`, built as a value
aggregate on its result spine and destructured by the caller, along both
branches. The case alternatives define values of the same names, which an
operand type check scoped per function used to report (CGEN\_040).

-}

-- CHECK: chooseIf called: 12
-- CHECK: chooseIf folded: 6
-- CHECK: chooseElse called: -1
-- CHECK: chooseElse folded: 2
-- CHECK: chooseC then: 7
-- CHECK: chooseC else: (4,3)
-- CHECK: chooseC sum: 17

import Html exposing (text)


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


chooseIf : Int -> Int -> Int
chooseIf =
    if sumTo 10 > 20 then
        \a b -> a * b

    else
        \a b -> a - b


chooseElse : Int -> Int -> Int
chooseElse =
    if sumTo 3 > 20 then
        \a b -> a * b

    else
        \a b -> a - b


chooseC : Int -> Int -> Int -> ( Int, Int )
chooseC n f g =
    if n > 0 then
        ( f, g )

    else
        ( g, f )


main =
    let
        _ =
            Debug.log "chooseIf called" (chooseIf 3 4)

        _ =
            Debug.log "chooseIf folded" (List.foldl chooseIf 1 [ 1, 2, 3 ])

        _ =
            Debug.log "chooseElse called" (chooseElse 3 4)

        _ =
            Debug.log "chooseElse folded" (List.foldl chooseElse 0 [ 1, 2, 3 ])

        ( p, q ) =
            chooseC 1 3 4

        _ =
            Debug.log "chooseC then" (p + q)

        _ =
            Debug.log "chooseC else" (chooseC 0 3 4)

        ( r, t ) =
            chooseC -1 7 10

        _ =
            Debug.log "chooseC sum" (r + t)
    in
    text "done"
