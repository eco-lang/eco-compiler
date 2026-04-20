module ContainerEqualityCharTest exposing (main)

{-| Equality of Char-containing Tuple2, Tuple3, and List values.

    Char equality is code-point equality, so the interesting cases are case
    sensitivity (`'A' /= 'a'`) and non-ASCII BMP code points.
-}

-- CHECK: pairEqual: True
-- CHECK: pairFirstDiff: False
-- CHECK: pairSecondDiff: False
-- CHECK: pairCaseDiff: False
-- CHECK: pairDigits: True
-- CHECK: pairUnicode: True
-- CHECK: pairUnicodeDiff: False
-- CHECK: tripleEqual: True
-- CHECK: tripleMidDiff: False
-- CHECK: tripleMixedCase: True
-- CHECK: tripleUnicode: True
-- CHECK: listEqual: True
-- CHECK: listLenDiff: False
-- CHECK: listEmpty: True
-- CHECK: listCaseDiff: False
-- CHECK: listUnicode: True

import Html exposing (text)


main =
    let
        emptyChars : List Char
        emptyChars = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairEqual" (('a', 'b') == ('a', 'b'))
        _ = Debug.log "pairFirstDiff" (('a', 'b') == ('c', 'b'))
        _ = Debug.log "pairSecondDiff" (('a', 'b') == ('a', 'c'))
        _ = Debug.log "pairCaseDiff" (('A', 'b') == ('a', 'b'))
        _ = Debug.log "pairDigits" (('0', '9') == ('0', '9'))
        _ = Debug.log "pairUnicode" (('\u{03BB}', '\u{20AC}') == ('\u{03BB}', '\u{20AC}'))
        _ = Debug.log "pairUnicodeDiff" (('\u{03BB}', '\u{20AC}') == ('\u{03BC}', '\u{20AC}'))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleEqual" (('a', 'b', 'c') == ('a', 'b', 'c'))
        _ = Debug.log "tripleMidDiff" (('a', 'b', 'c') == ('a', 'x', 'c'))
        _ = Debug.log "tripleMixedCase" (('A', 'b', 'C') == ('A', 'b', 'C'))
        _ = Debug.log "tripleUnicode" (('\u{03B1}', '\u{03B2}', '\u{03B3}') == ('\u{03B1}', '\u{03B2}', '\u{03B3}'))

        -- List -----------------------------------------------------------
        _ = Debug.log "listEqual" (['a', 'b', 'c'] == ['a', 'b', 'c'])
        _ = Debug.log "listLenDiff" (['a', 'b'] == ['a', 'b', 'c'])
        _ = Debug.log "listEmpty" (emptyChars == [])
        _ = Debug.log "listCaseDiff" (['a', 'b'] == ['A', 'b'])
        _ = Debug.log "listUnicode" (['\u{03BB}', '\u{20AC}', 'x'] == ['\u{03BB}', '\u{20AC}', 'x'])
    in
    text "done"
