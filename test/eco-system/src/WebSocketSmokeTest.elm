module WebSocketSmokeTest exposing (main)

{-| Smoke test of phase WS0 (plans/eco-system-websockets.md §4 WS0, updated for WS4): `WebSocket`
and the new `Http.Server` items compile and link on both backends; requests carry `version` and
`upgrade` through the new C.1 tagger layout; the WebSocket URL parser accepts and rejects URLs (an
accepted one is dialled: port 1 refuses the connection); `createServerWith` works (WS2);
`Http.Server.upgradeRequest` on a request that does not ask for a WebSocket fails `EINVAL` (WS5:
`HttpServerWebSocketTest` covers real upgrades) and leaves its `Response` usable; `closeServer`
completes.
-}

-- CHECK: request: GET /ws-smoke version Http1_1 upgrade Nothing
-- CHECK: upgradeRequest: EINVAL: upgradeRequest EINVAL: the request does not ask for a WebSocket handshakeFailed False status Nothing
-- CHECK: serverPort: True
-- CHECK: get: 200 ok
-- CHECK: createServerWith: ok
-- CHECK: createServerWith http2: EINVAL: createServerWith: http2 requires tls
-- CHECK: connect ws: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:1
-- CHECK: connect scheme: EINVAL: invalid WebSocket URL http://127.0.0.1/: the scheme must be ws or wss
-- CHECK: connect fragment: EINVAL: invalid WebSocket URL ws://127.0.0.1/#x: fragments are not allowed
-- CHECK: connect userinfo: EINVAL: invalid WebSocket URL wss://u@127.0.0.1/: user information is not allowed
-- CHECK: connect port: EINVAL: invalid WebSocket URL ws://127.0.0.1:65536/: invalid port
-- CHECK: connect header: EINVAL: invalid or reserved header Sec-WebSocket-Key
-- CHECK: defaults: 16777216 Just 30000 threshold 64 accept 16777216 server 16777216 65536 5000 60000 300000 Nothing Nothing
-- CHECK: closeServer: ok
-- EXIT: 0

import Dict
import Http
import Http.Server as Server exposing (HttpVersion(..))
import Http.Server.Response as Response
import Socket
import Socket.Address as Address exposing (Family(..))
import Stream.Log
import System
import Task exposing (Task)
import WebSocket


type Msg
    = Started (Result Server.ServerError ( Server.Server, Int ))
    | GotRequest Server.Request Response.Response
    | GotUpgrade String
    | ClientDone (List String)
    | Closed
    | Exit


type alias Model =
    { env : System.Environment
    , server : Maybe Server.Server
    , serverLines : List String
    , clientLines : Maybe (List String)
    }


testPort : Task x Int
testPort =
    System.getEnvironmentVariables
        |> Task.map (Dict.get "ECO_TEST_PORT" >> Maybe.andThen String.toInt >> Maybe.withDefault 0)


versionString : HttpVersion -> String
versionString version =
    case version of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


maybeIntString : Maybe Int -> String
maybeIntString m =
    case m of
        Just n ->
            "Just " ++ String.fromInt n

        Nothing ->
            "Nothing"


{-| One labelled outcome of a task that fails with a `Socket.Error`.
-}
outcome : String -> Task Socket.Error a -> Task Never String
outcome label task =
    task
        |> Task.map (\_ -> label ++ ": ok")
        |> Task.onError (\e -> Task.succeed (label ++ ": " ++ errorText e))


{-| Just the code for the stubs' "not implemented yet", the full text otherwise.
-}
errorText : Socket.Error -> String
errorText e =
    if Socket.errorCode e == "ENOTSUP" then
        "ENOTSUP"

    else
        Socket.errorToString e


connectTo : String -> Task Socket.Error (WebSocket.WebSocket WebSocket.Whole)
connectTo url =
    WebSocket.connect (WebSocket.defaultConnectOptions url)


defaultsLine : String
defaultsLine =
    let
        c =
            WebSocket.defaultConnectOptions "ws://127.0.0.1/"

        a =
            WebSocket.defaultAcceptOptions

        s =
            Server.defaultServerOptions (Address.loopback IPv4) 0
    in
    String.join " "
        [ "defaults:"
        , String.fromInt c.maxMessageSize
        , maybeIntString c.timeout
        , "threshold"
        , c.compression |> Maybe.map (.threshold >> String.fromInt) |> Maybe.withDefault "-"
        , "accept"
        , String.fromInt a.maxMessageSize
        , "server"
        , String.fromInt s.maxBodySize
        , String.fromInt s.maxHeaderSize
        , String.fromInt s.keepAliveTimeout
        , String.fromInt s.headersTimeout
        , String.fromInt s.requestTimeout
        , maybeIntString s.maxConnections
        , maybeIntString s.maxConcurrentStreams
        ]


client : Int -> Task Never (List String)
client port_ =
    let
        base =
            "127.0.0.1:" ++ String.fromInt port_

        get =
            Http.task
                { method = "GET"
                , headers = []
                , url = "http://" ++ base ++ "/ws-smoke"
                , body = Http.emptyBody
                , resolver =
                    Http.stringResolver
                        (\response ->
                            case response of
                                Http.GoodStatus_ meta body ->
                                    Ok (String.fromInt meta.statusCode ++ " " ++ body)

                                _ ->
                                    Err "bad response"
                        )
                , timeout = Just 20000
                }
                |> Task.map (\line -> "get: " ++ line)
                |> Task.onError (\e -> Task.succeed ("get: error " ++ e))

        createWith label options =
            Server.createServerWith options
                |> Task.map (\_ -> label ++ ": ok")
                |> Task.onError
                    (\(Server.ServerError e) ->
                        Task.succeed
                            (label
                                ++ ": "
                                ++ (if e.code == "ENOTSUP" then
                                        "ENOTSUP"

                                    else
                                        e.code ++ ": " ++ e.message
                                   )
                            )
                    )

        plain =
            Server.defaultServerOptions (Address.loopback IPv4) 0

        badHeader =
            WebSocket.defaultConnectOptions ("ws://" ++ base ++ "/")
                |> (\o -> { o | headers = [ ( "Sec-WebSocket-Key", "x" ) ] })
    in
    [ get
    , createWith "createServerWith" plain
    , createWith "createServerWith http2" { plain | http2 = True }
    , outcome "connect ws" (connectTo "WS://127.0.0.1:1/chat?room=1")
    , outcome "connect scheme" (connectTo "http://127.0.0.1/")
    , outcome "connect fragment" (connectTo "ws://127.0.0.1/#x")
    , outcome "connect userinfo" (connectTo "wss://u@127.0.0.1/")
    , outcome "connect port" (connectTo "ws://127.0.0.1:65536/")
    , outcome "connect header" (WebSocket.connect badHeader)
    , Task.succeed defaultsLine
    ]
        |> Task.sequence


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, server = Nothing, serverLines = [], clientLines = Nothing }
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
                        ( { model
                            | server = Just server
                            , serverLines = [ "serverPort: " ++ boolString (Server.serverPort server == p) ]
                          }
                        , Task.perform ClientDone (client p)
                        )

                    Started (Err (Server.ServerError e)) ->
                        ( model
                        , Task.perform (\_ -> Exit)
                            (Stream.Log.line model.env.stdout ("server error: " ++ e.code ++ " " ++ e.message))
                        )

                    GotRequest request response ->
                        ( { model
                            | serverLines =
                                ("request: "
                                    ++ Server.methodToString request.method
                                    ++ " "
                                    ++ request.url.path
                                    ++ " version "
                                    ++ versionString request.version
                                    ++ " upgrade "
                                    ++ Maybe.withDefault "Nothing" (Maybe.map (\u -> "Just " ++ u) request.upgrade)
                                )
                                    :: model.serverLines
                          }
                        , Cmd.batch
                            [ Server.upgradeRequest request response
                                |> Task.map (\_ -> "upgradeRequest: ok")
                                |> Task.onError
                                    (\e ->
                                        Task.succeed
                                            ("upgradeRequest: "
                                                ++ errorText e
                                                ++ " handshakeFailed "
                                                ++ boolString (WebSocket.errorIsHandshakeFailed e)
                                                ++ " status "
                                                ++ maybeIntString (WebSocket.handshakeStatus e)
                                            )
                                    )
                                |> Task.perform GotUpgrade
                            , response |> Response.setBody "ok" |> Response.send
                            ]
                        )

                    GotUpgrade line ->
                        finish { model | serverLines = model.serverLines ++ [ line ] }

                    ClientDone lines ->
                        finish { model | clientLines = Just lines }

                    Closed ->
                        ( model
                        , Task.perform (\_ -> Exit)
                            (Stream.Log.line model.env.stdout
                                (String.join "\n"
                                    (List.sortBy order model.serverLines
                                        ++ Maybe.withDefault [] model.clientLines
                                        ++ [ "closeServer: ok" ]
                                    )
                                )
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


{-| The server lines in a fixed order: the request, the upgrade attempt, the port check.
-}
order : String -> Int
order line =
    if String.startsWith "request:" line then
        0

    else if String.startsWith "upgradeRequest:" line then
        1

    else
        2


{-| Close the server once the client is done and the upgrade attempt reported (both are needed:
they complete in either order).
-}
finish : Model -> ( Model, Cmd Msg )
finish model =
    case ( model.clientLines, model.server, List.any (String.startsWith "upgradeRequest:") model.serverLines ) of
        ( Just _, Just server, True ) ->
            ( model, Task.perform (\_ -> Closed) (Server.closeServer server) )

        _ ->
            ( model, Cmd.none )
