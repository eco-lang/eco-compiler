module ContainerCompareStringTest exposing (main)

{-| Ordering of String-containing Tuple2, Tuple3, and List values via
    `compare` and the relational operators.

    String compare is lexicographic by code unit, so: the empty string is
    the least string, a prefix is less than any proper extension, and
    uppercase ASCII letters sort before lowercase.
-}

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
