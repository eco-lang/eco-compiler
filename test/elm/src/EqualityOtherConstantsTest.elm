module EqualityOtherConstantsTest exposing (main)

{-| `==` on empty and non-empty values of `String`, `List Int`, `Maybe Int` and `()` gives the right answer in both argument orders.

Each empty value (`""`, `[]`, `Nothing`) is held in an annotated local and compared with an equal literal, which is `True`, and with a non-empty value on either side, which is `False`. `() == ()` is `True`.
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
