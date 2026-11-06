module ContainerCompareStringTest exposing (main)

{-| Ordering of pairs, triples and lists of `String` with `compare` and the
relational operators.

The cases rely on how strings compare: the empty string is less than any other
string, a prefix is less than a longer string that extends it, uppercase ASCII
letters sort before lowercase, and `"\u{03B1}"` (α) sorts before
`"\u{03B2}"` (β).

## eco

Exercises eco's structural `compare` on String-containing Tuple2, Tuple3
and List values: the container comparison walks the elements and defers to
string comparison, which is lexicographic by UTF-16 code unit. The TEXT-MLIR
directive also routes this program through the MLIR text printer
(compiler/src/Mlir/Pretty.elm) so that printer stays covered end to end.

-}

-- TEXT-MLIR: also keeps the MLIR text printer (Mlir.Pretty) covered and checked end to end
-- CHECK: pairLt: LT
-- CHECK: pairGt: GT
-- CHECK: pairEq: EQ
-- CHECK: pairSecondDecides: LT
-- CHECK: pairEmptyFirst: LT
-- CHECK: pairPrefixIsLess: LT
-- CHECK: pairUpperBeforeLower: LT
-- CHECK: tripleFirstDecides: LT
-- CHECK: tripleThirdDecides: GT
-- CHECK: tripleEq: EQ
-- CHECK: tripleUnicode: LT
-- CHECK: listLt: LT
-- CHECK: listShorterIsLess: LT
-- CHECK: listEq: EQ
-- CHECK: listEmptyIsLeast: LT
-- CHECK: listEmptyStringIsLeast: LT
-- CHECK: pairLtOp: True
-- CHECK: pairGeOp: True
-- CHECK: tripleLtOp: True
-- CHECK: listGtOp: True

import Html exposing (text)


main =
    let
        emptyStrings : List String
        emptyStrings = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairLt" (compare ("apple", "x") ("banana", "x"))
        _ = Debug.log "pairGt" (compare ("zebra", "a") ("apple", "z"))
        _ = Debug.log "pairEq" (compare ("hello", "world") ("hello", "world"))
        _ = Debug.log "pairSecondDecides" (compare ("a", "b") ("a", "c"))
        _ = Debug.log "pairEmptyFirst" (compare ("", "z") ("a", ""))
        _ = Debug.log "pairPrefixIsLess" (compare ("app", "x") ("apple", "x"))
        _ = Debug.log "pairUpperBeforeLower" (compare ("Apple", "x") ("apple", "x"))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleFirstDecides" (compare ("a", "z", "z") ("b", "a", "a"))
        _ = Debug.log "tripleThirdDecides" (compare ("a", "b", "d") ("a", "b", "c"))
        _ = Debug.log "tripleEq" (compare ("a", "b", "c") ("a", "b", "c"))
        _ = Debug.log "tripleUnicode" (compare ("\u{03B1}", "x", "y") ("\u{03B2}", "x", "y"))

        -- List -----------------------------------------------------------
        _ = Debug.log "listLt" (compare ["a", "b"] ["a", "c"])
        _ = Debug.log "listShorterIsLess" (compare ["a", "b"] ["a", "b", "a"])
        _ = Debug.log "listEq" (compare ["a", "b", "c"] ["a", "b", "c"])
        _ = Debug.log "listEmptyIsLeast" (compare emptyStrings [""])
        _ = Debug.log "listEmptyStringIsLeast" (compare [""] ["a"])

        -- Relational operators ------------------------------------------
        _ = Debug.log "pairLtOp" (("a", "b") < ("a", "c"))
        _ = Debug.log "pairGeOp" (("x", "y") >= ("x", "y"))
        _ = Debug.log "tripleLtOp" (("a", "b", "c") < ("a", "b", "d"))
        _ = Debug.log "listGtOp" (["b", "a"] > ["a", "z"])
    in
    text "done"
