module InlineVarCollisionTest exposing (main)

{-| A function that destructures its argument into a variable named `n`, called twice on a caller's own variable `n`, gives the right result both times.

`useTwice n` calls `extract n` twice, where `extract (Wrapped n) = n`. The
pattern variable `n` in `extract` and the parameter `n` in `useTwice` are
different variables. `useTwice (Wrapped 42)` is 42 + 42 = 84.

## eco

Exercises variable naming after inlining
(compiler/src/Compiler/MonoOpt/InlineSimplify.elm). Once `extract` is inlined,
its destructured binding `n` used to overwrite the caller's `n` in the MLIR
generator's variable mappings, so the second `extract n` received the `i64`
field instead of the `!eco.value` wrapper. The shape mirrors the original
self-compile bug, where `Index.toMachine` (`toMachine (ZeroBased index) = index`)
was inlined twice next to a caller variable named `index`.

-}

-- CHECK: result: 84

import Html exposing (text)


type Wrapped
    = Wrapped Int


{-| Returns the Int inside a `Wrapped`, binding it to a pattern variable named
`n`, the same name as the parameter of `useTwice`.
-}
extract : Wrapped -> Int
extract (Wrapped n) =
    n


{-| Returns the sum of its two arguments.
-}
helper : Int -> Int -> Int
helper a b =
    a + b


{-| Returns twice the Int inside `n`, by passing `extract n` as both arguments
of `helper`.
-}
useTwice : Wrapped -> Int
useTwice n =
    helper (extract n) (extract n)


main =
    let
        w =
            Wrapped 42

        _ =
            Debug.log "result" (useTwice w)
    in
    text "done"
