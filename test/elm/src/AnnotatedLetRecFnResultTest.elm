module AnnotatedLetRecFnResultTest exposing (main)

{-| Bug: Compiler.LocalOpt.Typed.Expression.optimizePotentialTailCallDef, Can.TypedDef
arm, passes the annotation RESULT type (TypedDef stored type) instead of the
whole function type, so an annotated recursive let def becomes a TailDef typed
with its result type. Monomorphize.Specialize treats the TailDef type as the
whole function type (MonoTailFunc), so the local function gets a non-function
mono type. The same program without the let annotation works.
Unit test: compiler/tests/Compiler/LocalOpt/Typed/ExpressionTest.elm.
EXPECTED TO FAIL until fixed.
Observed: the compiler itself dies with "RangeError: Maximum call stack size
exceeded" (no .mlir written).
-}

-- CHECK: AnnotatedLetRecFnResultTest: 16

import Html exposing (text)


twice : Int -> Int
twice m =
    let
        go : Int -> (a -> a) -> (a -> a)
        go n f =
            if n <= 0 then
                f

            else
                go (n - 1) (f >> f)
    in
    go m (\x -> x + 1) 0


main =
    let
        _ =
            Debug.log "AnnotatedLetRecFnResultTest" (twice 4)
    in
    text "done"
