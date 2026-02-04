module LambdaLetBoundaryTest exposing (main)

{-| Test lambda boundary normalization for let expressions.

This tests that `\a -> let y = expr1 in \z -> expr2` is correctly
optimized by pulling the inner lambda across the let boundary:
`\a z -> let y = expr1 in expr2`

This reduces staging boundaries and closure allocation.
-}

-- CHECK: basic: 15
-- CHECK: capturing: 19
-- CHECK: multi_let: 20
-- CHECK: nested: 42
-- CHECK: partial: 25

import Html exposing (text)


{-| Basic let-separated staging: \a -> let y = ... in \z -> y + z
After normalization: \a z -> let y = ... in y + z
-}
letSeparated : Int -> Int -> Int
letSeparated a =
    let
        y = a + 5
    in
    \z -> y + z


{-| Let capturing outer variable: \a -> let y = a * 2 in \z -> y + z + a
After normalization: \a z -> let y = a * 2 in y + z + a
-}
letCapturing : Int -> Int -> Int
letCapturing a =
    let
        y = a * 2
    in
    \z -> y + z + a


{-| Multiple let bindings before inner lambda.
-}
multiLet : Int -> Int -> Int
multiLet a =
    let
        x = a + 1
        y = x * 2
    in
    \z -> x + y + z


{-| Nested let expressions with lambdas.
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
        -- Basic let-separated staging
        _ = Debug.log "basic" (letSeparated 5 5)

        -- Let capturing outer variable
        _ = Debug.log "capturing" (letCapturing 3 10)

        -- Multiple let bindings
        _ = Debug.log "multi_let" (multiLet 4 5)

        -- Nested let expressions
        _ = Debug.log "nested" (nestedLet 10 15 5)

        -- Test partial application still works
        partial = letSeparated 10
        _ = Debug.log "partial" (partial 10)
    in
    text "done"
