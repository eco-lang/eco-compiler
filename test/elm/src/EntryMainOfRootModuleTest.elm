module EntryMainOfRootModuleTest exposing (main)

{-| Bug: Compiler.Monomorphize.EntryPrep (insertFlagsDecoderNode and
findEntryPointId) find the entry point by the name `main` alone, taking the
first `main` in graph key order across ALL modules. The imported module
EntryAuxWithMain also defines `main` and sorts first, so the compiled program
runs the helper's `main` instead of this module's.

EXPECTED TO FAIL until the bug is fixed.

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
