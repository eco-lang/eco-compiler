module EntryAuxWithMain exposing (greeting, main)

{-| Helper module for EntryMainOfRootModuleTest: an imported module that also
defines a top-level `main`. Its key sorts before the root module's, so the
entry-point lookup by name (EntryPrep) picks THIS `main`. Run alone it is
an ordinary program.
-}

import Html exposing (text)


greeting : String
greeting =
    "hello"


main =
    let
        _ =
            Debug.log "which" "helper"
    in
    text "helper"
