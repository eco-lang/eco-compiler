module HttpServerWebSocketHelp exposing
    ( Config, program
    , tcp, tlsRaw, pipelined, declined, clientCase, keptCase
    )

{-| Shared helpers for the `Http.Server.upgradeRequest` tests (not a test: no `main`;
plans/eco-system-websockets.md §4 WS5).

The program creates one server with `createServerWith` on 127.0.0.1, port 0 (with TLS when
asked), answers ordinary requests itself and upgrades every request whose `upgrade` is
`Just "websocket"` (except `/declined`, answered 426) with `Http.Server.upgradeRequest`, then:

  - sends the request's `Response` anyway (it must be ignored: nothing may reach the client),
  - tries `upgradeRequest` a second time (it must fail: the key was consumed),
  - accepts the WebSocket with the default options and echoes it until it ends.

`/slow` is answered after 300 ms (to show that a pipelined upgrade waits for it), `/declined`
with 426, `/plain` with its name; on `/plain` the program also tries `upgradeRequest` (it must
fail: no upgrade asked). The client task runs in the same program; when it is done and every
server task has finished, the server's lines (sorted: they come from concurrent connections)
and then the client's lines are printed, and the program exits.

-}

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Http.Server as Server exposing (HttpVersion(..), Request, Server)
import Http.Server.Response as Response exposing (Response)
import HttpServerRawHelp as H
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Socket.Tls
import SocketTlsHelp as T
import Stream.Log
import System
import Task exposing (Task)
import TlsFixtures as Fx
import WebSocket
import WebSocketTestHelp as W


type alias Config =
    { tls : Bool
    , client : Server -> Task String (List String)
    }


type Msg
    = Started (Result Server.ServerError Server)
    | GotRequest Request Response
    | SendLater Response
    | Upgraded String Request Response (Result Socket.Error WebSocket.Upgrade)
    | ServerDone (List String)
    | ClientDone (Result String (List String))
    | Exit


type alias Model =
    { env : System.Environment
    , server : Maybe Server
    , lines : List String
    , running : Int
    , client : Maybe (List String)
    }


program : Config -> System.Program Model Msg
program config =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, server = Nothing, lines = [], running = 0, client = Nothing }
                , Server.defaultServerOptions (Address.loopback IPv4) 0
                    |> (\o ->
                            if config.tls then
                                { o | tls = Just (T.server []) }

                            else
                                o
                       )
                    |> Server.createServerWith
                    |> Task.attempt Started
                )
        , update = update config
        , subscriptions =
            \model ->
                case model.server of
                    Just server ->
                        Server.onRequest server GotRequest

                    Nothing ->
                        Sub.none
        }


versionString : HttpVersion -> String
versionString v =
    case v of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


targetOf : Request -> String
targetOf request =
    request.url.path ++ (request.url.query |> Maybe.map ((++) "?") |> Maybe.withDefault "")


schemeOf : Request -> String
schemeOf request =
    if String.contains " https://" (Server.requestInfo request) then
        "https"

    else
        "http"


errorString : Socket.Error -> String
errorString e =
    Socket.errorCode e


update : Config -> Msg -> Model -> ( Model, Cmd Msg )
update config msg model =
    case msg of
        Started (Ok server) ->
            ( { model | server = Just server }
            , config.client server |> Task.attempt ClientDone
            )

        Started (Err (Server.ServerError e)) ->
            ( model
            , Task.perform (\_ -> Exit) (Stream.Log.line model.env.stdout ("server error: " ++ e.code ++ " " ++ e.message))
            )

        GotRequest request response ->
            let
                target =
                    targetOf request
            in
            if request.url.path == "/declined" then
                ( model
                , response
                    |> Response.setStatus 426
                    |> Response.setHeader "Upgrade" "websocket"
                    |> Response.setBody "declined"
                    |> Response.send
                )

            else if request.upgrade == Just "websocket" then
                ( { model
                    | lines = model.lines ++ [ "upgrade " ++ schemeOf request ++ " " ++ target ++ " " ++ versionString request.version ]
                    , running = model.running + 1
                  }
                , Server.upgradeRequest request response |> Task.attempt (Upgraded target request response)
                )

            else if request.url.path == "/slow" then
                ( model, Process.sleep 300 |> Task.perform (\_ -> SendLater (response |> Response.setBody "slow")) )

            else if request.url.path == "/plain" then
                ( { model | running = model.running + 1 }
                , Cmd.batch
                    [ Server.upgradeRequest request response
                        |> Task.map (\_ -> "upgraded?")
                        |> Task.onError (\e -> Task.succeed (errorString e))
                        |> Task.perform (\r -> ServerDone [ "not an upgrade " ++ target ++ ": " ++ r ])
                    , response |> Response.setBody "plain" |> Response.send
                    ]
                )

            else
                ( model, response |> Response.setBody (String.dropLeft 1 request.url.path) |> Response.send )

        SendLater response ->
            ( model, Response.send response )

        Upgraded target request response (Ok up) ->
            ( { model | lines = model.lines ++ [ "taken " ++ target ++ ": upgradeTarget " ++ WebSocket.upgradeTarget up ] }
            , Cmd.batch
                [ -- The Response was used up by upgradeRequest: this must write nothing.
                  response |> Response.setBody "after upgrade" |> Response.send
                , Server.upgradeRequest request response
                    |> Task.map (\_ -> "taken twice?")
                    |> Task.onError (\e -> Task.succeed (errorString e))
                    |> Task.andThen
                        (\again ->
                            WebSocket.accept WebSocket.defaultAcceptOptions up
                                |> Task.mapError W.wsErr
                                |> Task.andThen W.echo
                                |> Task.onError (\e -> Task.succeed ("accept failed: " ++ e))
                                |> Task.map (\end -> [ "again " ++ target ++ ": " ++ again, "echo " ++ target ++ ": " ++ end ])
                        )
                    |> Task.perform ServerDone
                ]
            )

        Upgraded target _ _ (Err e) ->
            update config (ServerDone [ "upgrade failed " ++ target ++ ": " ++ Socket.errorToString e ]) model

        ServerDone lines ->
            maybeFinish { model | lines = model.lines ++ lines, running = model.running - 1 }

        ClientDone (Ok lines) ->
            maybeFinish { model | client = Just lines }

        ClientDone (Err e) ->
            maybeFinish { model | client = Just [ "client failed: " ++ e ] }

        Exit ->
            ( model, System.exit )


maybeFinish : Model -> ( Model, Cmd Msg )
maybeFinish model =
    case model.client of
        Just clientLines ->
            if model.running <= 0 then
                ( model
                , Stream.Log.line model.env.stdout
                    (String.join "\n"
                        (List.map ((++) "server: ") (List.sort model.lines)
                            ++ List.map ((++) "client: ") clientLines
                        )
                    )
                    |> Task.perform (\_ -> Exit)
                )

            else
                ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )



-- CLIENTS


crlf : String
crlf =
    "\u{000D}\n"


{-| A raw TCP connection to the server.
-}
tcp : Server -> Task String Socket.Connection
tcp =
    H.connect


{-| A raw TLS connection to the server (the test CA, server name `localhost`).
-}
tlsRaw : Server -> Task String Socket.Connection
tlsRaw server =
    Socket.Tls.connect (T.trusted "localhost" [])
        (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (Server.serverPort server))
        |> Task.mapError Socket.errorToString


bytesOf : String -> Bytes
bytesOf s =
    E.encode (E.string s)


emptyBytes : Bytes
emptyBytes =
    E.encode (E.sequence [])


{-| A valid opening request for `target` with the RFC 6455 sample key.
-}
upgradeText : String -> String
upgradeText target =
    String.join crlf
        [ "GET " ++ target ++ " HTTP/1.1"
        , "Host: localhost"
        , "Upgrade: websocket"
        , "Connection: Upgrade"
        , "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
        , "Sec-WebSocket-Version: 13"
        ]
        ++ crlf
        ++ crlf


{-| `k` HTTP responses (status line, lower-cased headers, body by Content-Length; 1xx have none)
at the start of `bytes`, then the frames after them; Nothing while incomplete.
-}
parseRaw : Int -> Bytes -> Maybe ( List ( String, List ( String, String ), String ), List ( Int, List Int ) )
parseRaw k bytes =
    let
        s =
            W.latin1 bytes

        go n offset acc =
            if n == 0 then
                Just ( List.reverse acc, offset )

            else
                case List.head (String.indexes (crlf ++ crlf) (String.dropLeft offset s)) of
                    Nothing ->
                        Nothing

                    Just i ->
                        let
                            lines =
                                String.split crlf (String.slice offset (offset + i) s)

                            statusLine =
                                List.head lines |> Maybe.withDefault ""

                            headers =
                                List.drop 1 lines
                                    |> List.filterMap
                                        (\line ->
                                            case String.indexes ":" line of
                                                c :: _ ->
                                                    Just ( String.toLower (String.left c line), String.trim (String.dropLeft (c + 1) line) )

                                                [] ->
                                                    Nothing
                                        )

                            len =
                                if String.startsWith "HTTP/1.1 1" statusLine then
                                    0

                                else
                                    headers
                                        |> List.filter (\( name, _ ) -> name == "content-length")
                                        |> List.head
                                        |> Maybe.andThen (Tuple.second >> String.toInt)
                                        |> Maybe.withDefault 0

                            bodyStart =
                                offset + i + 4
                        in
                        if String.length s < bodyStart + len then
                            Nothing

                        else
                            go (n - 1) (bodyStart + len) (( statusLine, headers, String.slice bodyStart (bodyStart + len) s ) :: acc)
    in
    go k 0 []
        |> Maybe.map (\( resps, off ) -> ( resps, W.parseFrames (W.bytesOfList (List.drop off (W.listOfBytes bytes))) ))


{-| Read until `done` holds for what arrived so far (fails if the connection ends first).
-}
readUntil : (Bytes -> Bool) -> Socket.Connection -> Bytes -> Task String Bytes
readUntil done conn acc =
    if done acc then
        Task.succeed acc

    else
        W.rawRead conn
            |> Task.mapError (\e -> "connection ended (" ++ e ++ ") after " ++ String.fromInt (Bytes.width acc) ++ " bytes: " ++ String.left 80 (W.latin1 acc))
            |> Task.andThen (\chunk -> readUntil done conn (W.concatBytes acc chunk))


header : String -> List ( String, String ) -> String
header name headers =
    headers |> List.filter (\( n, _ ) -> n == name) |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault "-"


describeResponse : ( String, List ( String, String ), String ) -> String
describeResponse ( statusLine, headers, body ) =
    let
        status =
            String.split " " statusLine |> List.drop 1 |> List.head |> Maybe.withDefault "?"
    in
    if status == "101" then
        "101 upgrade "
            ++ header "upgrade" headers
            ++ " connection "
            ++ header "connection" headers
            ++ " accept "
            ++ (if header "sec-websocket-accept" headers == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" then
                    "ok"

                else
                    "bad"
               )

    else
        status ++ " " ++ header "connection" headers ++ " " ++ body


{-| One write: a GET of `/slow` (answered after 300 ms), an opening request for `/ws?x=1`, and a
masked text frame right behind it. The 200 comes first, then the 101, then the echo of the
early frame; after our Close the server echoes it and closes. Everything after the 101 must be
frames (the `Response` sent after the upgrade writes nothing).
-}
pipelined : String -> Task String Socket.Connection -> Task String (List String)
pipelined label connect =
    connect
        |> Task.andThen
            (\conn ->
                W.rawWrite
                    (E.encode
                        (E.sequence
                            [ E.bytes (bytesOf ("GET /slow HTTP/1.1" ++ crlf ++ "Host: localhost" ++ crlf ++ crlf))
                            , E.bytes (bytesOf (upgradeText "/ws?x=1"))
                            , E.bytes (W.maskedFrame True 0 1 (bytesOf "early"))
                            ]
                        )
                    )
                    conn
                    |> Task.andThen
                        (\_ ->
                            readUntil
                                (\b -> parseRaw 2 b |> Maybe.map (\( _, frames ) -> not (List.isEmpty frames)) |> Maybe.withDefault False)
                                conn
                                emptyBytes
                        )
                    |> Task.andThen
                        (\first ->
                            W.rawWrite (W.maskedFrame True 0 8 (W.closePayload 1000 "")) conn
                                |> Task.andThen (\_ -> W.rawReadAll conn)
                                |> Task.andThen (\more -> Socket.close conn |> Task.map (\_ -> W.concatBytes first more))
                        )
                    |> Task.map
                        (\all ->
                            case parseRaw 2 all of
                                Just ( resps, frames ) ->
                                    List.map (\r -> label ++ ": " ++ describeResponse r) resps
                                        ++ [ label ++ ": frames " ++ W.framesString frames ]

                                Nothing ->
                                    [ label ++ ": unparsable " ++ String.left 80 (W.latin1 all) ]
                        )
            )


{-| An opening request the program declines (426): answered with `Connection: close`, then the
connection is closed.
-}
declined : Server -> Task String (List String)
declined server =
    H.connect server
        |> Task.andThen (H.exchange (upgradeText "/declined") 1 True)
        |> Task.map (List.map ((++) "declined: "))


wsUrl : String -> Server -> String -> String
wsUrl scheme server path =
    scheme ++ "://localhost:" ++ String.fromInt (Server.serverPort server) ++ path


connectWs : String -> Server -> String -> Task String (WebSocket.WebSocket WebSocket.Whole)
connectWs scheme server path =
    WebSocket.defaultConnectOptions (wsUrl scheme server path)
        |> (\o -> { o | verification = Socket.Tls.TrustedCertificates Fx.caPem })
        |> WebSocket.connect
        |> Task.mapError W.wsErr


closeWs : WebSocket.WebSocket WebSocket.Whole -> Task String WebSocket.CloseInfo
closeWs ws =
    WebSocket.close WebSocket.Normal "" ws
        |> Task.mapError W.wsErr
        |> Task.andThen (\_ -> WebSocket.closed ws)


{-| A `WebSocket.connect` client (`ws` or `wss`): echo of a text and a binary message; while it
is open, an ordinary request on another connection to the same port is served.
-}
clientCase : String -> Server -> Task String Socket.Connection -> Task String (List String)
clientCase scheme server connect =
    connectWs scheme server "/chat"
        |> Task.andThen
            (\ws ->
                W.sendAll [ W.text "hello", W.binary [ 1, 2, 3 ] ] ws
                    |> Task.andThen (\_ -> W.readMessages 2 ws)
                    |> Task.andThen
                        (\got ->
                            connect
                                |> Task.andThen (H.exchange ("GET /plain HTTP/1.1" ++ crlf ++ "Host: localhost" ++ crlf ++ crlf) 1 False)
                                |> Task.andThen (\plain -> closeWs ws |> Task.map (\info -> ( got, plain, info )))
                        )
                    |> Task.map
                        (\( got, plain, info ) ->
                            (scheme ++ " client: " ++ String.join " | " (List.map W.messageString got ++ [ W.closeInfoString info ]))
                                :: List.map ((++) "plain while open: ") plain
                        )
            )


{-| `closeServerWithin 100`: the port is closed, but a WebSocket upgraded from the server stays
open past the deadline and still echoes.
-}
keptCase : String -> Server -> Task String (List String)
keptCase scheme server =
    connectWs scheme server "/kept"
        |> Task.andThen
            (\ws ->
                Server.closeServerWithin 100 server
                    |> Task.andThen (\_ -> H.sleep 500)
                    |> Task.andThen (\_ -> H.connectCode (Server.serverPort server))
                    |> Task.andThen
                        (\code ->
                            W.sendAll [ W.text "still open" ] ws
                                |> Task.andThen (\_ -> W.readMessages 1 ws)
                                |> Task.andThen (\got -> closeWs ws |> Task.map (\info -> ( code, got, info )))
                        )
                    |> Task.map
                        (\( code, got, info ) ->
                            [ "after closeServer: new connection " ++ code
                            , "after closeServer: " ++ String.join " | " (List.map W.messageString got ++ [ W.closeInfoString info ])
                            ]
                        )
            )
