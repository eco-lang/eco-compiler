module FunctionValueChoiceTest exposing (main)

{-| Top-level values defined by an `if` that picks between two lambdas can be both called directly and passed to `List.foldl`, and a function returning a tuple from an `if` can be destructured.

`chooseIf` and `chooseElse` have no parameters of their own: each is an `if`
on `sumTo`, choosing multiplication or subtraction. `chooseIf` picks
multiplication, so `chooseIf 3 4` is 12 and `List.foldl chooseIf 1 [ 1, 2, 3 ]`
is 6. `chooseElse` picks subtraction, so `chooseElse 3 4` is -1 and
`List.foldl chooseElse 0 [ 1, 2, 3 ]` is 2 (`foldl` passes the element first,
then the accumulator).

`chooseC` returns its last two `Int` arguments as a pair, swapped when its first
argument is not positive. The test destructures it in a `let` along the `then`
branch (3 + 4 = 7) and the `else` branch (10 + 7 = 17), and logs the swapped
pair `(4,3)` directly.

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
