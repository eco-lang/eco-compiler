module CompilerIssue2147NameClashWhitespaceTest exposing (main)

{-| The NAME CLASH report for a pattern that binds the same name twice prints tens of thousands
of spaces.

<https://github.com/elm/compiler/issues/2147>

For `( T t, T t )` the report should underline the two `t`s. Elm 0.19.1 puts the second caret
about 65000 columns to the right (a negative column offset wrapped to 16 bits), so the report
contains a line of tens of thousands of spaces.

Fixed in Elm 0.19.2.

-}

-- COMPILE-ERROR: NAME CLASH with a readable code excerpt
-- CHECK: -- NAME CLASH -
-- CHECK-NOT: {{ {200}[ ]}}

import Html exposing (text)


type T
    = T Int


break : T -> T -> T
break a b =
    case ( a, b ) of
        ( T t, T t ) ->
            T 0


main =
    text "done"
