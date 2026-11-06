module CompilerIssue1979ImportOpaqueConstructorsTest exposing (..)

{-| Importing `Opaque(..)` from a module that exposes `Opaque` without its constructors is accepted.

<https://github.com/elm/compiler/issues/1979>

`CompilerIssue1979OpaqueHelper` exposes only `Opaque`, but Elm 0.19.1 accepts
`exposing (Opaque(..))` without complaint. Exposing constructors that the module does not expose
should be an import error.

-}

-- COMPILE-ERROR: the imported module does not expose Opaque's constructors
-- CHECK: {{-- [A-Z ]+ -}}

import CompilerIssue1979OpaqueHelper exposing (Opaque(..))
import Html


a : Opaque
a =
    CompilerIssue1979OpaqueHelper.make


main =
    Html.text ""
