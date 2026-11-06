module CompilerIssue1985ImportOrderTypeAmbiguityTest exposing (..)

{-| Two imports exposing the same type name: the last one silently wins.

<https://github.com/elm/compiler/issues/1985>

`TheType` is exposed both by `CompilerIssue1985SomeTypeHelper` (`TheType a`) and by
`CompilerIssue1985MyTypeHelper` (an alias of `TheType Int`). Elm 0.19.1 picks the last import, so
this compiles and the reordered program does not. An unqualified `TheType` is ambiguous and should
be reported as such, whatever the import order.

-}

-- COMPILE-ERROR: ambiguous type name TheType
-- CHECK: {{-- [A-Z ]+ -}}

import CompilerIssue1985SomeTypeHelper exposing (TheType(..))
import CompilerIssue1985MyTypeHelper exposing (TheType)
import Html


type alias Model =
    { val : TheType
    }


init : Model
init =
    { val = Boxed 5 }


main =
    Html.text ""
