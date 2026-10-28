module AccessorFunctionFieldInListTest exposing (main)

{-| Bug: Compiler.Monomorphize.ResolveAccessorValues leaves a MonoAccessorValue
in place when its expected type is unknown. List literal elements (and call
arguments, record-update values) are rewritten with no expected type, and an
accessor whose field is itself a function is always deferred, so `.op` placed
in a list literal survives to Compiler.Generate.MLIR.Expr, which crashes on any
MonoAccessorValue.

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, item 3.7); the text
below describes the old behaviour.

-}

-- CHECK: results: [11, 20]

import Html exposing (text)


type alias Ops =
    { op : Int -> Int, op2 : Int -> Int }


main =
    let
        ops : Ops
        ops =
            { op = \n -> n + 1, op2 = \n -> n * 2 }

        getters : List (Ops -> Int -> Int)
        getters =
            [ .op, .op2 ]

        _ =
            Debug.log "results" (List.map (\g -> g ops 10) getters)
    in
    text "done"
