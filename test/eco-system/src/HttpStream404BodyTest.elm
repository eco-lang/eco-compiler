module HttpStream404BodyTest exposing (main)

{-| `expectStreamResponse` exposes the error body stream of a 404
(plans/eco-system-library.md Phase 8 step 8.3, E.6): the response is
`BadStatus_` with the real metadata, and its body stream reads the server's
text.
-}

-- CHECK: BadStatus_ 404 Status
-- CHECK: body: status 404
-- CHECK: content-type: text/plain
-- EXIT: 0

import Bytes exposing (Bytes)
import Dict
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Stream.Log
import System
import Task
import TestServerConfig


type Msg
    = Got (Result String ( Http.Metadata, Stream.Readable Bytes ))
    | GotServer TestServerConfig.Server
    | Logged


main : System.Program System.Environment Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( env
                , Task.perform GotServer TestServerConfig.server
                )
        , update =
            \msg env ->
                case msg of
                    GotServer server ->
                        ( env
                        , Http.Stream.request
                            { method = "GET"
                            , headers = []
                            , url = H.url server "/status/404"
                            , body = Http.Stream.emptyBody
                            , expect =
                                Http.Stream.expectStreamResponse Got
                                    (\r ->
                                        case r of
                                            Http.BadStatus_ meta body ->
                                                Ok ( meta, body )
        
                                            _ ->
                                                Err "not BadStatus_"
                                    )
                            , timeout = Nothing
                            }
                        )

                    Got (Ok ( meta, body )) ->
                        ( env
                        , H.readAllString body
                            |> Task.map (\s -> "body: " ++ s)
                            |> Task.onError (\e -> Task.succeed ("read error: " ++ Stream.errorToString e))
                            |> Task.andThen
                                (\line ->
                                    Stream.Log.line env.stdout
                                        (String.join "\n"
                                            [ "BadStatus_ " ++ String.fromInt meta.statusCode ++ " " ++ meta.statusText
                                            , line
                                            , "content-type: " ++ Maybe.withDefault "-" (Dict.get "content-type" meta.headers)
                                            ]
                                        )
                                )
                            |> Task.perform (\_ -> Logged)
                        )

                    Got (Err e) ->
                        ( env, Task.perform (\_ -> Logged) (Stream.Log.line env.stdout ("error: " ++ e)) )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
