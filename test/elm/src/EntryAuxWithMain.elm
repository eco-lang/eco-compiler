module EntryAuxWithMain exposing (greeting, main)

{-| Supplies `EntryMainOfRootModuleTest` with an imported module that defines
and exposes its own `main`, so that the test can show which `main` runs.

This `main` logs `which: "helper"`, while the importing test expects the
`which: "root"` line from its own `main`, the entry point. Compiled on its own,
this module is an ordinary program.

-}

import Html exposing (text)


{-| The string `"hello"`, which the importing test logs to show the import works.
-}
greeting : String
greeting =
    "hello"


{-| Logs `which: "helper"` and shows the text "helper".
-}
main =
    let
        _ =
            Debug.log "which" "helper"
    in
    text "helper"
