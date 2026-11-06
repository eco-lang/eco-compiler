module ContainerEqualityStringTest exposing (main)

{-| Checks `==` on pairs, triples and lists of `String`.

The cases that matter are empty strings, letter case, one string being a prefix
of another, and characters outside ASCII.

  - Pairs: equal, differing in either position, empty strings, differing only
    in case, `"app"` against `"apple"`, and non-ASCII contents.
  - Triples: equal, differing in the middle, containing empty strings, and
    Greek letters.
  - Lists: equal, different lengths, two empty lists, lists of empty strings,
    differing in case, and non-ASCII contents.

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
