module WsEchoServer exposing (main)

{-| A WebSocket echo server on `Http.Server`: every message a client sends comes back unchanged.

    eco make src/WsEchoServer.elm --output=ws-echo-server && ./ws-echo-server 9001
    ./ws-client ws://127.0.0.1:9001/ hello      # examples/system/src/WsClient.elm

Arguments, all optional, in any order:

  - a port number (default 9001; the server listens on 127.0.0.1);
  - `--tls CERT KEY`: serve `https` and `wss` with the PEM certificate chain and private key in
    these files;
  - `--http2`: also serve HTTP/2 (needs `--tls`; ALPN chooses);
  - `--no-compression`: decline permessage-deflate (by default it is accepted, without context
    takeover);
  - `--context-takeover`: accept permessage-deflate with context takeover.

Requests that ask for a WebSocket are upgraded with `Http.Server.upgradeRequest` and accepted with
messages up to 64 MiB and no heartbeat; other requests get a short text answer. Pings are answered
by the WebSocket itself. The server runs until the process is stopped.

The conformance scripts in `test/conformance/` run the Autobahn|Testsuite and h2spec against this
program.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Http.Server as Server exposing (Request, Server)
import Http.Server.Response as Response exposing (Response)
import Socket.Address as Address
import Stream
import Stream.Log
import System
import System.File
import System.File.Path
import Task exposing (Task)
import WebSocket


type alias Options =
    { port_ : Int
    , tls : Maybe ( String, String )
    , http2 : Bool
    , compression : Maybe WebSocket.ServerCompression
    }


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , options : Options
    , server : Maybe Server
    }


type Msg
    = Started (Result String Server)
    | Received Request Response
    | Done


main : System.Program Model Msg
main =
    System.defineProgram
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


init : System.Environment -> ( Model, Cmd Msg )
init env =
    case parseArgs (List.drop 1 env.args) defaultOptions of
        Ok options ->
            ( { stdout = env.stdout, stderr = env.stderr, options = options, server = Nothing }
            , start options |> Task.attempt Started
            )

        Err problem ->
            ( { stdout = env.stdout, stderr = env.stderr, options = defaultOptions, server = Nothing }
            , fail env.stderr (problem ++ "\nusage: ws-echo-server [PORT] [--tls CERT KEY] [--http2] [--no-compression] [--context-takeover]")
            )


defaultOptions : Options
defaultOptions =
    { port_ = 9001
    , tls = Nothing
    , http2 = False
    , compression = WebSocket.defaultAcceptOptions.compression
    }


parseArgs : List String -> Options -> Result String Options
parseArgs args options =
    case args of
        [] ->
            Ok options

        "--tls" :: cert :: key :: rest ->
            parseArgs rest { options | tls = Just ( cert, key ) }

        "--http2" :: rest ->
            parseArgs rest { options | http2 = True }

        "--no-compression" :: rest ->
            parseArgs rest { options | compression = Nothing }

        "--context-takeover" :: rest ->
            parseArgs rest
                { options
                    | compression =
                        Just { maxWindowBits = 15, contextTakeover = True, threshold = 64 }
                }

        arg :: rest ->
            case String.toInt arg of
                Just n ->
                    parseArgs rest { options | port_ = n }

                Nothing ->
                    Err ("ws-echo-server: unexpected argument " ++ arg)


{-| Read the certificate and key (when given) and create the server.
-}
start : Options -> Task String Server
start options =
    let
        serverOptions tls =
            let
                d =
                    Server.defaultServerOptions (Address.loopback Address.IPv4) options.port_
            in
            { d | tls = tls, http2 = options.http2 }
    in
    (case options.tls of
        Just ( certFile, keyFile ) ->
            Task.map2
                (\cert key -> Just { certificateChain = cert, privateKey = key, alpn = [] })
                (readText certFile)
                (readText keyFile)

        Nothing ->
            Task.succeed Nothing
    )
        |> Task.andThen
            (\tls ->
                Server.createServerWith (serverOptions tls)
                    |> Task.mapError (\(Server.ServerError e) -> e.message)
            )


readText : String -> Task String String
readText file =
    System.File.readFile (System.File.Path.fromPosixString file)
        |> Task.mapError System.File.errorToString
        |> Task.andThen
            (\bytes ->
                case Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes of
                    Just text ->
                        Task.succeed text

                    Nothing ->
                        Task.fail (file ++ ": not UTF-8")
            )


fail : Stream.Writable Bytes -> String -> Cmd Msg
fail stderr problem =
    Cmd.batch
        [ Task.perform (\_ -> Done) (Stream.Log.line stderr problem)
        , System.exitWithCode 1
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started (Ok server) ->
            let
                scheme =
                    if model.options.tls == Nothing then
                        "ws"

                    else
                        "wss"
            in
            ( { model | server = Just server }
            , Stream.Log.line model.stdout
                ("ws-echo-server: listening on "
                    ++ scheme
                    ++ "://127.0.0.1:"
                    ++ String.fromInt (Server.serverPort server)
                    ++ "/"
                )
                |> Task.perform (\_ -> Done)
            )

        Started (Err problem) ->
            ( model, fail model.stderr ("ws-echo-server: " ++ problem) )

        Received request response ->
            if request.upgrade == Just "websocket" then
                ( model
                , Server.upgradeRequest request response
                    |> Task.andThen (WebSocket.accept (acceptOptions model.options))
                    |> Task.andThen echo
                    |> Task.onError (\_ -> Task.succeed ())
                    |> Task.perform (\_ -> Done)
                )

            else
                ( model
                , response
                    |> Response.setHeader "Content-Type" "text/plain; charset=utf-8"
                    |> Response.setBody "A WebSocket echo server: connect with a WebSocket client.\n"
                    |> Response.send
                )

        Done ->
            ( model, Cmd.none )


acceptOptions : Options -> WebSocket.AcceptOptions
acceptOptions options =
    let
        d =
            WebSocket.defaultAcceptOptions
    in
    { d
        | maxMessageSize = 64 * 1024 * 1024
        , heartbeat = Nothing
        , compression = options.compression
    }


{-| Echo every message until the readable ends (the peer closed, or the connection failed).
-}
echo : WebSocket.WebSocket WebSocket.Whole -> Task x ()
echo ws =
    Stream.read (WebSocket.readable ws)
        |> Task.andThen (\message -> Stream.write message (WebSocket.writable ws))
        |> Task.map (\_ -> True)
        |> Task.onError (\_ -> Task.succeed False)
        |> Task.andThen
            (\more ->
                if more then
                    echo ws

                else
                    Task.succeed ()
            )


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.server of
        Just server ->
            Server.onRequest server Received

        Nothing ->
            Sub.none
