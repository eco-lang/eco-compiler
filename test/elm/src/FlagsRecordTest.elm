module FlagsRecordTest exposing (main)

{-| A `Platform.worker` whose flags are a record of an `Int`, a `String` and a `Bool` receives the decoded record in `init`.

The `FLAGS` directive supplies the JSON `{"count":42,"label":"native-flags","enabled":true}`. `init` logs `label`, `count + 1` and `enabled`.
-}

-- SKIP-AOT: needs `-- FLAGS:` JSON, which only the JIT harness can inject (eco_entry.cpp reads no flags)
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
