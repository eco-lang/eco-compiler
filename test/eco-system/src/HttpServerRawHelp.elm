module HttpServerRawHelp exposing
    ( Answer(..), Config, program
    , Resp, connect, sendRaw, readResponses, exchange, readToClose, closedOrNot, describe
    , connectCode, sleep
    )

{-| Shared helpers for the `Http.Server` tests that talk raw HTTP/1.1 (not a test: no `main`;
plans/eco-system-websockets.md §4 WS2).

Every test creates a server with `createServerWith` on 127.0.0.1, port 0 (the options can be
changed per test), subscribes to it, and runs a client task in the same program that talks to the
server over plain `Socket.Tcp` connections, writing requests byte for byte and parsing the
responses itself (status, `Connection` header, body by `Content-Length`). The server's handler
returns lines to log and how to answer: now, after a delay, or not at all. When the client task
ends, the server's lines (in arrival order) and then the client's lines are printed to the real
stdout; the program then exits with `System.exit`, unless the test asks it to end by itself.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Http.Server as Server exposing (Request, Server, ServerOptions)
import Http.Server.Response as Response exposing (Response)
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Stream
import Stream.Log
import System
import Task exposing (Task)


{-| How the server answers a request: with this response now, after the given number of
milliseconds, or never (the test answers otherwise, or not at all).
-}
type Answer
    = Now Response
    | After Int Response
    | NoAnswer


type alias Config =
    { options : ServerOptions -> ServerOptions
    , handler : List String -> Request -> Response -> ( List String, Answer )
    , client : Server -> Task String (List String)
    , exitAtEnd : Bool
    }


type Msg
    = Started (Result Server.ServerError Server)
    | GotRequest Request Response
    | SendLater String Response
    | ClientDone (Result String (List String))
    | Printed
    | Exit


type alias Model =
    { env : System.Environment
    , server : Maybe Server
    , lines : List String
    , answered : List String
    }


{-| The program of a raw-client test. The handler gets the paths of the requests answered so far
(oldest first; a delayed answer counts once it is sent).
-}
program : Config -> System.Program Model Msg
program config =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, server = Nothing, lines = [], answered = [] }
                , Server.createServerWith (config.options (Server.defaultServerOptions (Address.loopback IPv4) 0))
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


update : Config -> Msg -> Model -> ( Model, Cmd Msg )
update config msg model =
    case msg of
        Started (Ok server) ->
            ( { model | server = Just server }
            , config.client server |> Task.attempt ClientDone
            )

        Started (Err (Server.ServerError e)) ->
            finish config { model | lines = [ "server error: " ++ e.code ++ " " ++ e.message ] } []

        GotRequest request response ->
            let
                ( lines, answer ) =
                    config.handler model.answered request response

                logged =
                    { model | lines = model.lines ++ List.map (\l -> "server: " ++ l) lines }

                path =
                    request.url.path
            in
            case answer of
                Now reply ->
                    ( { logged | answered = logged.answered ++ [ path ] }, Response.send reply )

                After ms reply ->
                    ( logged, Process.sleep (toFloat ms) |> Task.perform (\_ -> SendLater path reply) )

                NoAnswer ->
                    ( logged, Cmd.none )

        SendLater path reply ->
            ( { model | answered = model.answered ++ [ path ] }, Response.send reply )

        ClientDone (Ok lines) ->
            finish config model lines

        ClientDone (Err e) ->
            finish config model [ "client failed: " ++ e ]

        Printed ->
            ( model, Cmd.none )

        Exit ->
            ( model, System.exit )


finish : Config -> Model -> List String -> ( Model, Cmd Msg )
finish config model clientLines =
    let
        out =
            Stream.Log.line model.env.stdout
                (String.join "\n" (model.lines ++ List.map (\l -> "client: " ++ l) clientLines))
    in
    if config.exitAtEnd then
        ( model, Task.perform (\_ -> Exit) out )

    else
        -- The program must end by itself (nothing may keep it alive).
        ( model, Task.perform (\_ -> Printed) out )



-- RAW CLIENT


bytesOf : String -> Bytes
bytesOf s =
    Bytes.Encode.encode (Bytes.Encode.string s)


bytesToString : Bytes -> String
bytesToString b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b
        |> Maybe.withDefault "<invalid utf-8>"


sleep : Int -> Task x ()
sleep ms =
    Process.sleep (toFloat ms)


{-| A TCP connection to the server.
-}
connect : Server -> Task String Socket.Connection
connect server =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (Server.serverPort server))
        |> Task.mapError Socket.errorToString


{-| `"connected"`, or the error code of a failed connect to `port_`.
-}
connectCode : Int -> Task x String
connectCode port_ =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) port_)
        |> Task.andThen (\conn -> Socket.close conn |> Task.map (\_ -> "connected"))
        |> Task.onError (\e -> Task.succeed (Socket.errorCode e))


sendRaw : String -> Socket.Connection -> Task String ()
sendRaw text conn =
    Stream.write (bytesOf text) (Socket.writable conn)
        |> Task.map (\_ -> ())
        |> Task.mapError Stream.errorToString


{-| A parsed response: status, the `Connection` header ("-" if none), the body.
-}
type alias Resp =
    { status : Int
    , connection : String
    , body : String
    , headers : List ( String, String )
    }


describe : Resp -> String
describe r =
    String.fromInt r.status ++ " " ++ r.connection ++ " " ++ r.body


{-| One response from the front of `buffer` (none if incomplete): 1xx, 204 and 304 have no
body, the others `Content-Length` bytes (ASCII bodies only).
-}
parseOne : String -> Maybe ( Resp, String )
parseOne buffer =
    case List.head (String.indexes "\u{000D}\n\u{000D}\n" buffer) of
        Nothing ->
            Nothing

        Just i ->
            let
                headLines =
                    String.split "\u{000D}\n" (String.left i buffer)

                rest =
                    String.dropLeft (i + 4) buffer

                status =
                    List.head headLines
                        |> Maybe.andThen (String.split " " >> List.drop 1 >> List.head)
                        |> Maybe.andThen String.toInt
                        |> Maybe.withDefault 0

                headers =
                    List.drop 1 headLines
                        |> List.filterMap
                            (\line ->
                                case String.indexes ":" line of
                                    c :: _ ->
                                        Just ( String.toLower (String.left c line), String.trim (String.dropLeft (c + 1) line) )

                                    [] ->
                                        Nothing
                            )

                header name =
                    List.filter (\( n, _ ) -> n == name) headers |> List.head |> Maybe.map Tuple.second

                length =
                    if status < 200 || status == 204 || status == 304 then
                        0

                    else
                        header "content-length" |> Maybe.andThen String.toInt |> Maybe.withDefault 0
            in
            if String.length rest >= length then
                Just
                    ( { status = status
                      , connection = header "connection" |> Maybe.withDefault "-"
                      , body = String.left length rest
                      , headers = headers
                      }
                    , String.dropLeft length rest
                    )

            else
                Nothing


parseAll : String -> List Resp -> ( List Resp, String )
parseAll buffer acc =
    case parseOne buffer of
        Just ( r, rest ) ->
            parseAll rest (acc ++ [ r ])

        Nothing ->
            ( acc, buffer )


{-| Read until `n` responses arrived (fails if the connection ends first). Bytes after the n-th
are returned too.
-}
readResponses : Int -> Socket.Connection -> Task String ( List Resp, String )
readResponses n conn =
    readHelp n conn ""


readHelp : Int -> Socket.Connection -> String -> Task String ( List Resp, String )
readHelp n conn buffer =
    let
        ( resps, rest ) =
            parseAll buffer []
    in
    if List.length resps >= n then
        Task.succeed ( resps, rest )

    else
        Stream.read (Socket.readable conn)
            |> Task.mapError
                (\e ->
                    "connection ended after "
                        ++ String.fromInt (List.length resps)
                        ++ " responses ("
                        ++ Stream.errorToString e
                        ++ ")"
                        ++ (if buffer == "" then
                                ""

                            else
                                ": " ++ String.left 60 buffer
                           )
                )
            |> Task.andThen (\chunk -> readHelp n conn (buffer ++ bytesToString chunk))


{-| Everything up to the end of the connection (a read error ends it too, shown as `<error>`).
-}
readToClose : Socket.Connection -> Task x String
readToClose conn =
    Stream.readUntilClosed (\chunk acc -> Ok (acc ++ bytesToString chunk)) "" (Socket.readable conn)
        |> Task.onError (\e -> Task.succeed ("<" ++ Stream.errorToString e ++ ">"))


{-| `"closed"` when the connection ends with nothing more, else what came first.
-}
closedOrNot : String -> Socket.Connection -> Task x String
closedOrNot leftover conn =
    readToClose conn
        |> Task.map
            (\more ->
                if leftover ++ more == "" then
                    "closed"

                else
                    "closed after " ++ String.left 40 (leftover ++ more)
            )


{-| Send `text`, read `n` responses, then wait for the end of the connection when `thenClosed`:
the described responses, then `closed` (or what came instead).
-}
exchange : String -> Int -> Bool -> Socket.Connection -> Task String (List String)
exchange text n thenClosed conn =
    sendRaw text conn
        |> Task.andThen (\_ -> readResponses n conn)
        |> Task.andThen
            (\( resps, rest ) ->
                if thenClosed then
                    closedOrNot rest conn |> Task.map (\c -> List.map describe resps ++ [ c ])

                else
                    Task.succeed (List.map describe resps)
            )
