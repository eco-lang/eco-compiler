module HttpsGetTest exposing (main)

{-| HTTPS GET with real peer verification. The in-process server serves TLS with
a throwaway self-signed cert (SAN IP:127.0.0.1); curl verifies it against that
cert via CURL_CA_BUNDLE (set by the test harness). Exercises the OpenSSL path.
-}

-- CHECK: https: True

import Http
import Platform
import TestServerConfig
import Task


type Msg
    = Got (Result Http.Error String)
    | GotServer TestServerConfig.Server


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.get
        { url = server.httpsBaseUrl ++ "/anything"
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        Got (Ok body) ->
            let
                _ =
                    Debug.log "https" (String.contains "\"method\":\"GET\"" body)
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "https" False
            in
            ( model, Cmd.none )
