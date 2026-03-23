module CaseSharedBranchTest exposing (main)

{-| Outer case on constructor with nested case on String inside a branch.
The nested string case forces eco.case to survive EcoControlFlowToSCF,
reaching CaseOpLowering in EcoToLLVM where Bug 1 triggers.
-}

-- CHECK: r1: "greeting"
-- CHECK: r2: "farewell"
-- CHECK: r3: "unknown cmd"
-- CHECK: r4: "fixed"

import Html exposing (text)


type Wrapper
    = Named String
    | Fixed


describe : Wrapper -> String
describe w =
    case w of
        Named name ->
            case name of
                "hello" ->
                    "greeting"

                "bye" ->
                    "farewell"

                _ ->
                    "unknown cmd"

        Fixed ->
            "fixed"


main =
    let
        _ = Debug.log "r1" (describe (Named "hello"))
        _ = Debug.log "r2" (describe (Named "bye"))
        _ = Debug.log "r3" (describe (Named "other"))
        _ = Debug.log "r4" (describe Fixed)
    in
    text "done"
