module HttpSubMapTest exposing (main)

{-| `Sub.map` over `Http.track` (plans/http-cmdmap-native-crash.md): the progress of a tracked
request must reach the app through the subscription's tagger, as stock elm/http's
`subMap func (MySub tracker toMsg) = MySub tracker (toMsg >> func)` does. The request itself
goes through `Cmd.map` too.
-}

-- CHECK: progress: True

import Http
import Platform
import Task
import TestServerConfig


type Msg
    = GotProgress Http.Progress
    | Got (Result Http.Error String)


type Outer
    = GotServer TestServerConfig.Server
    | Inner Msg


main : Program () Bool Outer
main =
    Platform.worker
        { init = \_ -> ( False, Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.map Inner (Http.track "p" GotProgress)
        }


update : Outer -> Bool -> ( Bool, Cmd Outer )
update msg seen =
    case msg of
        GotServer server ->
            ( seen
            , Cmd.map Inner
                (Http.request
                    { method = "GET", headers = [], url = server.baseUrl ++ "/drip?bytes=2048&ms=400"
                    , body = Http.emptyBody, expect = Http.expectString Got, timeout = Nothing, tracker = Just "p" })
            )

        Inner (GotProgress _) ->
            ( True, Cmd.none )

        Inner (Got _) ->
            let
                _ = Debug.log "progress" seen
            in
            ( seen, Cmd.none )
