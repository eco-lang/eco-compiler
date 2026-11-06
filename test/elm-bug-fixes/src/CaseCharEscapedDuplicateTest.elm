module CaseCharEscapedDuplicateTest exposing (main)

{-| A `case` on Char with two patterns for the same character written differently ('a' and
'\u{0061}'): the second can never match, so it is a redundant pattern.

Fixed in Elm 0.19.2. Elm 0.19.1 compares Char patterns by their source text, so it accepts this
program, and the second branch is dead code.

-}

-- COMPILE-ERROR: REDUNDANT PATTERN, the same Char written two ways
-- CHECK: -- REDUNDANT PATTERN -

import Html exposing (text)


classify c =
    case c of
        'a' -> 1
        '\u{0061}' -> 2
        'b' -> 3
        _ -> 4


main =
    text (String.fromInt (classify 'a'))
