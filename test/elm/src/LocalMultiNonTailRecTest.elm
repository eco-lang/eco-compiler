module LocalMultiNonTailRecTest exposing (main)

{-| Regression: a NON-tail-recursive let-bound polymorphic function used at
two types (Int and Float).

Specialize.renameMonoDef renames self-references only for MonoTailDef, so the
second specialisation's recursive call still targets the first instance (at
the other type).

EXPECTED TO FAIL until the bug is fixed.

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
