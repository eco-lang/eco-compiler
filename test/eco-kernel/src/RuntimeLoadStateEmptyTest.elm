module RuntimeLoadStateEmptyTest exposing (main)

{-| `Eco.Runtime.loadState` before any `saveState`. Its doc and its JavaScript twin
(Eco/Kernel/Runtime.js: `_Runtime_replState = null`) give JSON `null` when nothing has
been saved, so the Value must decode with `Json.Decode.null` and encode as `null`.
Then a saved state comes back unchanged.
-}

-- CHECK: empty encodes: "null"
-- CHECK: empty decodes as null: True
-- CHECK: empty is not a string: True
-- CHECK: saved: "{\"a\":1}"

import Eco.Runtime as Runtime
import Json.Decode as D
import Json.Encode as E
import Platform
import Task


type Msg
    = Loaded E.Value
    | Reloaded E.Value


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Loaded Runtime.loadState )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Loaded v ->
            let
                _ =
                    Debug.log "empty encodes" (E.encode 0 v)

                _ =
                    Debug.log "empty decodes as null" (D.decodeValue (D.null ()) v == Ok ())

                _ =
                    Debug.log "empty is not a string" (Result.toMaybe (D.decodeValue D.string v) == Nothing)
            in
            ( model
            , Runtime.saveState (E.object [ ( "a", E.int 1 ) ])
                |> Task.andThen (\_ -> Runtime.loadState)
                |> Task.perform Reloaded
            )

        Reloaded v ->
            let
                _ =
                    Debug.log "saved" (E.encode 0 v)
            in
            ( model, Cmd.none )
