module CovForeignTypesTest exposing (main)

{-| Uses two values of another module of the project in ways that only a
second module reaches in the type checker: `secretValue`, whose annotation
names an alias its module does not expose, and `config.x`, a field access on a
value referred to through its module name.

-}

-- CHECK: CovForeignTypesTest: 42

import CovForeignTypesHelper
import Html exposing (text)


main =
    let
        _ =
            Debug.log "CovForeignTypesTest" (CovForeignTypesHelper.secretValue + CovForeignTypesHelper.config.x)
    in
    text "done"
