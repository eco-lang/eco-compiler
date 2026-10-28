module CaseCharEscapedDuplicateTest exposing (main)

{-| A `case` on Char with two patterns for the same character written
differently ('a' and '\u{0061}').

Reproduces: Compiler.AST.DecisionTree.Test.testToComparable keys IsChr (and
IsStr) by the escaped literal TEXT, and Nitpick.PatternMatches compares
literals by text too, so the second pattern is not seen as redundant and the
decision tree gets two edges for the same value. The MLIR eco.case then has a
duplicate tag ([97, 97, 98, 0]) and lowering fails with
"'scf.index_switch' op has duplicate case value: 97".

EXPECTED TO FAIL until the bug is fixed.

-}

-- CHECK: a: 1
-- CHECK: b: 3
-- CHECK: z: 4

import Html exposing (text)


classify c =
    case c of
        'a' -> 1
        '\u{0061}' -> 2
        'b' -> 3
        _ -> 4


main =
    let
        _ = Debug.log "a" (classify 'a')
        _ = Debug.log "b" (classify 'b')
        _ = Debug.log "z" (classify 'z')
    in
    text "done"
