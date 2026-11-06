module ErrorMessagesIssue356UnicodeEscapeBadSuggestionTest exposing (main)

{-| For the too-short unicode escape `"\u{01}"` the compiler suggests `\u{001}`, which is
also too short (and for `\u{001}` it suggests `\u{01}` back).

<https://github.com/elm/error-message-catalog/issues/356>

Elm 0.19.1 reports BAD UNICODE ESCAPE ("Every code point needs at least four digits") and then
says "Try \u{001} instead?". The suggestion must have at least four digits: `\u{0001}`.

-}

-- COMPILE-ERROR: two-digit unicode escape
-- CHECK: -- BAD UNICODE ESCAPE -
-- CHECK-NOT: Try \u{001} instead

import Html exposing (text)


s =
    "\u{01}"


main =
    text s
