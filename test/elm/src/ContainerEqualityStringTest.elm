module ContainerEqualityStringTest exposing (main)

{-| Equality of String-containing Tuple2, Tuple3, and List values.

    Interesting cases: empty strings, case sensitivity, strings where one is
    a prefix of another, and non-ASCII BMP content.
-}

-- CHECK: pairEqual: True
-- CHECK: pairFirstDiff: False
-- CHECK: pairSecondDiff: False
-- CHECK: pairEmpty: True
-- CHECK: pairCaseDiff: False
-- CHECK: pairPrefixDiff: False
-- CHECK: pairUnicode: True
-- CHECK: tripleEqual: True
-- CHECK: tripleMidDiff: False
-- CHECK: tripleWithEmpty: True
-- CHECK: tripleUnicode: True
-- CHECK: listEqual: True
-- CHECK: listLenDiff: False
-- CHECK: listEmpty: True
-- CHECK: listEmptyStrings: True
-- CHECK: listCaseDiff: False
-- CHECK: listUnicode: True

import Html exposing (text)


main =
    let
        emptyStrings : List String
        emptyStrings = []

        -- Tuple2 ---------------------------------------------------------
        _ = Debug.log "pairEqual" (("apple", "banana") == ("apple", "banana"))
        _ = Debug.log "pairFirstDiff" (("apple", "banana") == ("cherry", "banana"))
        _ = Debug.log "pairSecondDiff" (("apple", "banana") == ("apple", "cherry"))
        _ = Debug.log "pairEmpty" (("", "") == ("", ""))
        _ = Debug.log "pairCaseDiff" (("Apple", "banana") == ("apple", "banana"))
        _ = Debug.log "pairPrefixDiff" (("app", "x") == ("apple", "x"))
        _ = Debug.log "pairUnicode" (("\u{03BB}x", "\u{20AC}y") == ("\u{03BB}x", "\u{20AC}y"))

        -- Tuple3 ---------------------------------------------------------
        _ = Debug.log "tripleEqual" (("a", "b", "c") == ("a", "b", "c"))
        _ = Debug.log "tripleMidDiff" (("a", "b", "c") == ("a", "x", "c"))
        _ = Debug.log "tripleWithEmpty" (("", "b", "") == ("", "b", ""))
        _ = Debug.log "tripleUnicode" (("\u{03B1}", "\u{03B2}", "\u{03B3}") == ("\u{03B1}", "\u{03B2}", "\u{03B3}"))

        -- List -----------------------------------------------------------
        _ = Debug.log "listEqual" (["a", "b", "c"] == ["a", "b", "c"])
        _ = Debug.log "listLenDiff" (["a", "b"] == ["a", "b", "c"])
        _ = Debug.log "listEmpty" (emptyStrings == [])
        _ = Debug.log "listEmptyStrings" (["", "", ""] == ["", "", ""])
        _ = Debug.log "listCaseDiff" (["Hello"] == ["hello"])
        _ = Debug.log "listUnicode" (["\u{03BB}", "\u{20AC}", "x"] == ["\u{03BB}", "\u{20AC}", "x"])
    in
    text "done"
