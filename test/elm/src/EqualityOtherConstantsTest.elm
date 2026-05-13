module EqualityOtherConstantsTest exposing (main)

{-| Regression guard for the broader embedded-constant equality story.

These cases involve embedded constants other than Bool (Nil, Nothing,
EmptyString, Unit). They are *currently* correct — either by accident
(both arms resolve to the same nullptr) or because one arm is a real
heap pointer that the `if (!a || !b) return false` short-circuit
catches. The test pins them so a Bool-equality fix does not silently
regress these adjacent cases.
-}

-- CHECK: emptyEmpty: True
-- CHECK: emptyNonEmpty: False
-- CHECK: nonEmptyEmpty: False
-- CHECK: nilNil: True
-- CHECK: nilCons: False
-- CHECK: consNil: False
-- CHECK: nothingNothing: True
-- CHECK: nothingJust: False
-- CHECK: justNothing: False
-- CHECK: unitUnit: True

import Html exposing (text)


main =
    let
        emptyStr : String
        emptyStr = ""

        emptyInts : List Int
        emptyInts = []

        noInt : Maybe Int
        noInt = Nothing

        _ = Debug.log "emptyEmpty" (emptyStr == "")
        _ = Debug.log "emptyNonEmpty" (emptyStr == "x")
        _ = Debug.log "nonEmptyEmpty" ("x" == emptyStr)

        _ = Debug.log "nilNil" (emptyInts == [])
        _ = Debug.log "nilCons" (emptyInts == [ 1 ])
        _ = Debug.log "consNil" ([ 1 ] == emptyInts)

        _ = Debug.log "nothingNothing" (noInt == Nothing)
        _ = Debug.log "nothingJust" (noInt == Just 1)
        _ = Debug.log "justNothing" (Just 1 == noInt)

        _ = Debug.log "unitUnit" (() == ())
    in
    text "done"
