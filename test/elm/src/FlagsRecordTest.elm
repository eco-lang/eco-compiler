module FlagsRecordTest exposing (main)

{-| End-to-end flags test (Phase 5, plans/native-ports-and-embedding.md).

The FLAGS directive below is picked up by the test harness
(extractFlagsDirective in test/ElmE2ETestBase.hpp) and stashed as JSON via
PlatformRuntime::setPendingFlagsJson; initWorker decodes it with this
program's compiler-generated flags decoder and hands the record to `init`.

-}

-- FLAGS: {"count":42,"label":"native-flags","enabled":true}
-- CHECK: FlagsRecordTest label: "native-flags"
-- CHECK: FlagsRecordTest count: 43
-- CHECK: FlagsRecordTest enabled: True

import Platform


type alias Flags =
    { count : Int
    , label : String
    , enabled : Bool
    }


init : Flags -> ( (), Cmd msg )
init flags =
    let
        _ =
            Debug.log "FlagsRecordTest label" flags.label

        _ =
            Debug.log "FlagsRecordTest count" (flags.count + 1)

        _ =
            Debug.log "FlagsRecordTest enabled" flags.enabled
    in
    ( (), Cmd.none )


main : Program Flags () msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
