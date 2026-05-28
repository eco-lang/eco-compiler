module HttpsGetTest exposing (main)

{-| HTTPS GET with real peer verification. The in-process server serves TLS with
a throwaway self-signed cert (SAN IP:127.0.0.1); curl verifies it against that
cert via CURL_CA_BUNDLE (set by the test harness). Exercises the OpenSSL path.
-}

-- CHECK: https: True

import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), get )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : Cmd Msg
get =
    Http.get
        { url = TestServerConfig.httpsBaseUrl ++ "/anything"
        , expect = Http.expectString Got
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
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
