module TupleProjectedClosureApplyTest exposing (main)

{-| Regression test (native/AOT backend) for a SEPARATE codegen bug, unrelated
to `number` defaulting, found while probing polymorphism.

Applying a function that was projected out of a tuple (`Tuple.first fns` /
`Tuple.second fns`) to an UNBOXED primitive argument emits invalid MLIR:

    error: 'eco.papExtend' op operand #0 must be eco.value, but got 'i64'

The projected closure is an opaque PAP whose arguments must be boxed, but the
unboxed `i64`/`f64` argument is passed without boxing. This is NOT a
mis-specialization and NOT polymorphism-dependent:

  - it reproduces with fully MONOMORPHIC closures (`\x -> x + 1`),
  - it reproduces at top level (no `let`),
  - it reproduces for Int and Float arguments.

It does NOT occur when the argument is already boxed (e.g. a `String`), nor for
a closure reached via a bare `let` binding or a record field — only via tuple
projection. The fix must box the argument at the projected-PAP call site.

-}

-- CHECK: a: 2
-- CHECK: b: 4
-- CHECK: f: 5

import Html exposing (text)


fns : ( Int -> Int, Int -> Int )
fns =
    ( \x -> x + 1, \y -> y + 2 )


-- Same bug with an UNBOXED Float argument (`f64`), not just Int.
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
