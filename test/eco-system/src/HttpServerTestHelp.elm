module HttpServerTestHelp exposing (Handler, Model, Msg, baseUrl, boolString, get, httpErrorToString, program, send, testPort)

{-| Shared helpers for the eco/system HTTP server tests (not a test: no `main`;
plans/eco-system-library.md Phase 7 step 7.4).

Every test starts a server on 127.0.0.1 at the port the harness put in
`ECO_TEST_PORT` (`test/TestPort.hpp`), subscribes to it, and then runs a
client task that talks to the server with **elm/http** (`Http.task`, so the
requests run one after the other). The server's handler returns the lines to
log and the response to send. When the client task ends, the server's lines
(in request order) and then the client's lines are printed to the real
stdout, and the program exits: a listening server keeps it alive otherwise.

-}

import Dict
import Http
import Http.Server as Server exposing (Request, Server)
import Http.Server.Response as Response exposing (Response)
import Stream.Log
import System
import Task exposing (Task)


{-| The port the harness picked, or 0 when it is missing.
-}
testPort : Task x Int
testPort =
    System.getEnvironmentVariables
        |> Task.map
            (\vars ->
                Dict.get "ECO_TEST_PORT" vars
                    |> Maybe.andThen String.toInt
                    |> Maybe.withDefault 0
            )


baseUrl : Int -> String
baseUrl port_ =
    "http://127.0.0.1:" ++ String.fromInt port_


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl u ->
            "BadUrl " ++ u

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "NetworkError"

        Http.BadStatus code ->
            "BadStatus " ++ String.fromInt code

        Http.BadBody b ->
            "BadBody " ++ b


{-| A request whose outcome is described as one line:
`<status> <header-of-interest or -> <body>`, or the error.
-}
send : { method : String, headers : List Http.Header, url : String, body : Http.Body, header : String } -> Task Never String
send r =
    Http.task
        { method = r.method
        , headers = r.headers
        , url = r.url
        , body = r.body
        , resolver =
            Http.stringResolver
                (\response ->
                    case response of
                        Http.GoodStatus_ meta body ->
                            Ok
                                (String.fromInt meta.statusCode
                                    ++ " "
                                    ++ (Dict.get r.header meta.headers |> Maybe.withDefault "-")
                                    ++ " "
                                    ++ body
                                )

                        Http.BadStatus_ meta body ->
                            Ok
                                ("status "
                                    ++ String.fromInt meta.statusCode
                                    ++ " "
                                    ++ (Dict.get r.header meta.headers |> Maybe.withDefault "-")
                                    ++ " "
                                    ++ body
                                )

                        Http.BadUrl_ u ->
                            Err (Http.BadUrl u)

                        Http.Timeout_ ->
                            Err Http.Timeout

                        Http.NetworkError_ ->
                            Err Http.NetworkError
                )
        , timeout = Just 20000
        }
        |> Task.onError (\e -> Task.succeed ("error " ++ httpErrorToString e))


{-| A plain GET described by `send`.
-}
get : String -> Task Never String
get url =
    send { method = "GET", headers = [], url = url, body = Http.emptyBody, header = "content-type" }


type alias Handler =
    Request -> Response -> ( List String, Response )


type Msg
    = Started (Result Server.ServerError ( Server, Int ))
    | GotRequest Request Response
    | ClientDone (List String)
    | Exit


type alias Model =
    { env : System.Environment
    , server : Maybe Server
    , lines : List String
    }


program : { handler : Handler, client : String -> Task Never (List String) } -> System.Program Model Msg
program config =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, server = Nothing, lines = [] }
                , testPort
                    |> Task.andThen
                        (\p ->
                            Server.createServer { host = "127.0.0.1", port_ = p }
                                |> Task.map (\s -> ( s, p ))
                        )
                    |> Task.attempt Started
                )
        , update =
            \msg model ->
                case msg of
                    Started (Ok ( server, p )) ->
                        ( { model | server = Just server }
                        , Task.perform ClientDone (config.client (baseUrl p))
                        )

                    Started (Err (Server.ServerError e)) ->
                        ( model
                        , Task.perform (\_ -> Exit)
                            (Stream.Log.line model.env.stdout ("server error: " ++ e.code ++ " " ++ e.message))
                        )

                    GotRequest request response ->
                        let
                            ( lines, reply ) =
                                config.handler request response
                        in
                        ( { model | lines = model.lines ++ List.map (\l -> "server: " ++ l) lines }
                        , Response.send reply
                        )

                    ClientDone lines ->
                        ( model
                        , Task.perform (\_ -> Exit)
                            (Stream.Log.line model.env.stdout
                                (String.join "\n" (model.lines ++ List.map (\l -> "client: " ++ l) lines))
                            )
                        )

                    Exit ->
                        ( model, System.exit )
        , subscriptions =
            \model ->
                case model.server of
                    Just server ->
                        Server.onRequest server GotRequest

                    Nothing ->
                        Sub.none
        }
