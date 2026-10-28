module CaseCharEscapedDuplicateTest exposing (main)

{-| A `case` on Char with two patterns for the same character written
differently ('a' and '\u{0061}').

Compiler.AST.DecisionTree.Test.testToComparable used to key IsChr (and IsStr)
by the escaped literal TEXT, so the decision tree got two edges for the same
value; the MLIR eco.case then had a duplicate tag ([97, 97, 98, 0]) and
lowering failed with "'scf.index_switch' op has duplicate case value: 97".
Tests are now keyed by the value the literal denotes
(Compiler.Elm.String.valueKey), so the eco.case is [97, 98, 0] and the second
'a' pattern is never reached. Nitpick.PatternMatches still compares literals
by text, so the second pattern is not reported as redundant (as in upstream
Elm). Also covered by compiler/tests/Compiler/AST/DecisionTree/TestKeyTest.elm.

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
