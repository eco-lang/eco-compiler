module TupleProjectedClosureApplyTest exposing (main)

{-| A function taken out of a tuple with `Tuple.first` or `Tuple.second` and applied directly to an `Int` or `Float` argument returns the right result.

`fns` pairs two `Int -> Int` lambdas and `fnsF` two `Float -> Float` lambdas,
both defined at top level; `main` projects a function and applies it in the
same expression.

## eco

A native-backend regression test. Applying a closure projected out of a tuple to
an unboxed `Int` or `Float` used to emit invalid MLIR (`'eco.papExtend' op
operand #0 must be eco.value, but got 'i64'`): the projected closure is an opaque
partial application whose arguments must be boxed, and the argument was passed
unboxed. It happened with monomorphic closures and at top level, but not for
already-boxed arguments or closures reached via `let` or a record field. The
fix boxes the argument at the projected-closure call site
(compiler/src/Compiler/GenerateMlir/Expr.elm).

-}

-- CHECK: a: 2
-- CHECK: b: 4
-- CHECK: f: 5

import Html exposing (text)


fns : ( Int -> Int, Int -> Int )
fns =
    ( \x -> x + 1, \y -> y + 2 )


fnsF : ( Float -> Float, Float -> Float )
fnsF =
    ( \x -> x + 1.0, \y -> y + 2.0 )


main =
    let
        _ =
            Debug.log "a" (Tuple.first fns 1)

        _ =
            Debug.log "b" (Tuple.second fns 2)

        _ =
            Debug.log "f" (round (Tuple.first fnsF 4.0))
    in
    text "done"
