module LocalMultiNonTailRecTest exposing (main)

{-| Regression: a NON-tail-recursive let-bound polymorphic function used at
two types (Int and Float).

Each specialisation after the first is a copy named `sumL$1`, ..., but its
recursive call kept the bare name `sumL`, so it targeted the first instance
(at the other type). Self-references are now renamed with
MonoTraverse.renameLocal in both engines (MonoSolver.Translate.buildLocalDefs
and Specialize.renameMonoDef), as tail defs already were.

-}

import Html exposing (text)


-- CHECK: sumInt: 6
-- CHECK: sumFloat: 4


main =
    let
        sumL xs =
            case xs of
                [] ->
                    0

                x :: rest ->
                    x + sumL rest

        a =
            sumL [ 1, 2, 3 ]

        b =
            sumL [ 0.5, 1.5, 2.0 ]

        _ =
            Debug.log "sumInt" a

        _ =
            Debug.log "sumFloat" b
    in
    text "done"
