module EntryMainOfRootModuleTest exposing (main)

{-| A program's entry point is the `main` of the module being compiled, even
when an imported module also defines and exposes a `main`.

The imported `EntryAuxWithMain` exposes its own `main`, which logs `which:
"helper"`. This module's `main` logs `which: "root"` and then `greeting`, a
string taken from the imported module, so the output shows which `main` ran and
that the import still works.

-}

-- CHECK: which: "root"
-- CHECK: greeting: "hello"

import EntryAuxWithMain
import Html exposing (text)


main =
    let
        _ =
            Debug.log "which" "root"

        _ =
            Debug.log "greeting" EntryAuxWithMain.greeting
    in
    text "done"
