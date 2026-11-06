module ContainerCompareCharTest exposing (main)

{-| Ordering of pairs, triples and lists of `Char` with `compare` and the
relational operators.

`Char` values compare by code point, so uppercase ASCII letters sort before
lowercase ones (`'A'` is 65, `'a'` is 97), digits sort before letters, and
`'\u{03B1}'` (α) sorts before `'\u{03B2}'` (β). Containers compare position by
position, a list that is a prefix of another is less, and the empty list is
less than any other list.

-}

-- CHECK: pairLt: LT
-- CHECK: pairGt: GT
-- CHECK: pairEq: EQ
-- CHECK: pairSecondDecides: LT
-- CHECK: pairUpperBeforeLower: LT
-- CHECK: pairUnicode: LT
-- CHECK: tripleFirstDecides: LT
-- CHECK: tripleThirdDecides: GT
-- CHECK: tripleEq: EQ
-- CHECK: tripleDigitsBeforeLetters: LT
-- CHECK: listLt: LT
-- CHECK: listShorterIsLess: LT
-- CHECK: listEq: EQ
-- CHECK: listEmptyIsLeast: LT
-- CHECK: listUnicodeCmp: LT
-- CHECK: pairLtOp: True
-- CHECK: pairGeOp: True
-- CHECK: tripleLtOp: True
-- CHECK: listGtOp: True

import Html exposing (text)


main =
    let
        emptyChars : List Char
        emptyChars = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairLt" (compare ('a', 'b') ('a', 'c'))
        _ = Debug.log "pairGt" (compare ('b', 'a') ('a', 'z'))
        _ = Debug.log "pairEq" (compare ('x', 'y') ('x', 'y'))
        _ = Debug.log "pairSecondDecides" (compare ('a', 'b') ('a', 'd'))
        _ = Debug.log "pairUpperBeforeLower" (compare ('A', 'z') ('a', 'a'))
        _ = Debug.log "pairUnicode" (compare ('\u{03B1}', 'x') ('\u{03B2}', 'x'))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleFirstDecides" (compare ('a', 'z', 'z') ('b', 'a', 'a'))
        _ = Debug.log "tripleThirdDecides" (compare ('a', 'b', 'd') ('a', 'b', 'c'))
        _ = Debug.log "tripleEq" (compare ('a', 'b', 'c') ('a', 'b', 'c'))
        _ = Debug.log "tripleDigitsBeforeLetters" (compare ('0', '1', '2') ('A', 'B', 'C'))

        -- List -----------------------------------------------------------
        _ = Debug.log "listLt" (compare ['a', 'b'] ['a', 'c'])
        _ = Debug.log "listShorterIsLess" (compare ['a', 'b'] ['a', 'b', 'a'])
        _ = Debug.log "listEq" (compare ['a', 'b', 'c'] ['a', 'b', 'c'])
        _ = Debug.log "listEmptyIsLeast" (compare emptyChars ['\u{0000}'])
        _ = Debug.log "listUnicodeCmp" (compare ['\u{03B1}'] ['\u{03B2}'])

        -- Relational operators ------------------------------------------
        _ = Debug.log "pairLtOp" (('a', 'b') < ('a', 'c'))
        _ = Debug.log "pairGeOp" (('x', 'y') >= ('x', 'y'))
        _ = Debug.log "tripleLtOp" (('a', 'b', 'c') < ('a', 'b', 'd'))
        _ = Debug.log "listGtOp" (['b', 'a'] > ['a', 'z'])
    in
    text "done"
