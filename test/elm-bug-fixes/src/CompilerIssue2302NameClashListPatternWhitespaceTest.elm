module CompilerIssue2302NameClashListPatternWhitespaceTest exposing (main)

{-| The NAME CLASH report for a list pattern `[ a, a ]` prints 65532 spaces.

<https://github.com/elm/compiler/issues/2302>

The report should underline the two `a`s on the code line. Elm 0.19.1 prints the first caret,
then 65532 spaces before the second one.

Fixed in Elm 0.19.2.

-}

-- COMPILE-ERROR: NAME CLASH with a readable code excerpt
-- CHECK: -- NAME CLASH -
-- CHECK-NOT: {{ {200}[ ]}}

import Html exposing (text)


failingCode : List () -> List ()
failingCode list =
    case list of
        [ a, a ] ->
            list

        _ ->
            list


main =
    text "done"
