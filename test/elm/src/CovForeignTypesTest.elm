module CovForeignTypesTest exposing (main)

{-| Checks the use of two values from another module of the same project:
`secretValue`, whose annotation names a type alias that its module does not
expose, and a field of `config`, read through the module name as
`CovForeignTypesHelper.config.x`. Their sum, 42, is logged.
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
