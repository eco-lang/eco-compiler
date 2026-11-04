module HttpEmptyPostTest exposing (main)

{-| DEAD-18 (plans/kernel-lib-bug-fixes.md): a regression pin, not an expected
failure. eco-kernel Http.cpp's `fetch` sets `req.body = ""` and
`req.contentType = ""` for a `POST`, which only repeats the defaults of
`HttpService::Request`; the fix deletes those assignments. What they claim to
protect is that a body-less POST reaches the server with `Content-Length: 0`
(a server may refuse one without it, 411). `HttpService` sends that header
itself (CURLOPT_POSTFIELDSIZE 0), so this test passes before and after the
deletion.

The test server's `/anything` route echoes the method and the request headers
(lower-cased names) as JSON.
-}

-- CHECK: HttpEmptyPostTest method: True
-- CHECK: HttpEmptyPostTest content-length 0: True
-- CHECK: HttpEmptyPostTest empty body: True

import Eco.Http
import Platform
import Task
import TestServerConfig


type Msg
    = Got (Result String String)


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , TestServerConfig.server
        |> Task.andThen (\server -> Eco.Http.fetch "POST" (server.baseUrl ++ "/anything") [])
        |> Task.map (Result.mapError (\_ -> "fetch failed"))
        |> Task.perform Got
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok body) ->
            let
                _ =
                    Debug.log "HttpEmptyPostTest method" (String.contains "\"method\":\"POST\"" body)

                _ =
                    Debug.log "HttpEmptyPostTest content-length 0" (String.contains "\"content-length\":\"0\"" body)

                _ =
                    Debug.log "HttpEmptyPostTest empty body" (String.contains "\"body\":\"\"" body)
            in
            ( model, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "HttpEmptyPostTest error" e
            in
            ( model, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
