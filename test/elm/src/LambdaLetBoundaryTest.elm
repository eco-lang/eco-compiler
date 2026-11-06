module LambdaLetBoundaryTest exposing (main)

{-| Checks functions that bind values in a `let` and then return a lambda for their remaining arguments.

  - `basic` and `partial` call `letSeparated`, once with both arguments and
    once by binding a partial application and then applying it.
  - `capturing` calls `letCapturing`, whose lambda uses both the `let`
    binding and the function's own parameter.
  - `multi_let` calls `multiLet`, which has two `let` bindings, the second
    using the first.
  - `nested` calls `nestedLet`, which returns a lambda containing another
    `let` and another lambda, so three arguments pass through two such
    stages.

-}

-- CHECK: basic: 15
-- CHECK: capturing: 19
-- CHECK: multi_let: 20
-- CHECK: nested: 42
-- CHECK: partial: 25

import Html exposing (text)


{-| Binds `y` to `a + 5` in a `let`, then returns a lambda adding `y` to its
argument.
-}
letSeparated : Int -> Int -> Int
letSeparated a =
    let
        y = a + 5
    in
    \z -> y + z


{-| Binds `y` to `a * 2` in a `let`, then returns a lambda that also uses `a`.
-}
letCapturing : Int -> Int -> Int
letCapturing a =
    let
        y = a * 2
    in
    \z -> y + z + a


{-| Binds two values in a `let`, the second using the first, then returns a
lambda using both.
-}
multiLet : Int -> Int -> Int
multiLet a =
    let
        x = a + 1
        y = x * 2
    in
    \z -> x + y + z


{-| Returns a lambda, after a `let`, that itself has a `let` and returns
another lambda.
-}
nestedLet : Int -> Int -> Int -> Int
nestedLet a =
    let
        x = a + 1
    in
    \b ->
        let
            y = b + x
        in
        \c -> x + y + c


main =
    let
        _ = Debug.log "basic" (letSeparated 5 5)

        _ = Debug.log "capturing" (letCapturing 3 10)

        _ = Debug.log "multi_let" (multiLet 4 5)

        _ = Debug.log "nested" (nestedLet 10 15 5)

        partial = letSeparated 10
        _ = Debug.log "partial" (partial 10)
    in
    text "done"
