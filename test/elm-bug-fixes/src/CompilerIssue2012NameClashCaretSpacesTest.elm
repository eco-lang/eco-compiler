module CompilerIssue2012NameClashCaretSpacesTest exposing (..)

{-| The NAME CLASH report underlines with the wrong carets and hundreds of trailing spaces.

<https://github.com/elm/compiler/issues/2012>

For `f x x =` the report should underline both `x`s (`^ ^` under columns 3 and 5). Elm 0.19.1
prints a single `^` under the wrong column followed by a long run of spaces.

Fixed in Elm 0.19.2.

-}

-- COMPILE-ERROR: duplicate argument x
-- CHECK: -- NAME CLASH -
-- CHECK: ^ ^
-- CHECK-NOT: {{\^\s\s\s\s\s\s\s\s\s\s}}

import Html


f x x =
    x


main =
    Html.text ""
