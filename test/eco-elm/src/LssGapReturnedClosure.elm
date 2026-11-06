module LssGapReturnedClosure exposing (main)

{-| A function that returns a lambda capturing its argument, and a function argument passed on to `List.foldl`, are both called correctly.

`adder 3` returns `\y -> 3 + y`, and `applyIt` applies it to 4, logging 7. `sumWith (+) [ 1, 2, 3 ]`
passes the operator `(+)` to `List.foldl` with a starting value of 0, logging 6.

## eco

Exercises two arrow positions that lambda-set specialization (LSS,
plans/lss-lambda-set-specialization.md) does not stamp, isolated in one module. Run with
`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1` and grep `^pos|` to read the census rows
(path syntax: `a<n>` is argument n, `r` is the result).

The returned closure: `adder` has declared arity 1, so spine injection (LSS_013 in
design_docs/invariants.csv) stamps only its head arrow; the arrow at `/r` belongs to the lambda
`adder` produces. That slot is written only if the body-to-signature tie carries the fact, and
otherwise zonks to an unwritten set variable, labelled `var` (recoverable) rather than top.

The kernel-adjacent head: the `List.foldl` head reads top, from two sources in the monomorphizer.
`deriveKernelAbiTypeWith` (compiler/src/Compiler/Monomorphize/Solver/Translate.elm) rebuilds the
kernel type from the canonical type with top on every arrow, and the occurrence-keyed demand and
body slots differ, so joining the stamped set with the unwritten slot gives top.

-}

-- CHECK: returnedClosure: 7
-- CHECK: kernelAliasHead: 6

import Html exposing (text)


{-| Returns a function that adds `x` to its argument.
-}
adder : Int -> (Int -> Int)
adder x =
    \y -> x + y


{-| Applies `f` to `n`.
-}
applyIt : (Int -> Int) -> Int -> Int
applyIt f n =
    f n


{-| Folds `xs` from the left with `f`, starting from 0.
-}
sumWith : (Int -> Int -> Int) -> List Int -> Int
sumWith f xs =
    List.foldl f 0 xs


main =
    let
        _ =
            Debug.log "returnedClosure" (applyIt (adder 3) 4)

        _ =
            Debug.log "kernelAliasHead" (sumWith (+) [ 1, 2, 3 ])
    in
    text "hello"
