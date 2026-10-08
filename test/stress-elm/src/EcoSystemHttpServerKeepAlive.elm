module EcoSystemHttpServerKeepAlive exposing (main)

{-| Stress program for `Http.Server` on the IoReactor (plans/eco-system-websockets.md §3.4, §4
WS2; base plan §3.3.3 gate 3).

The program creates a server with `createServerWith` (port 0) and subscribes to it, then runs
`max 1 numLoops` waves (`-n 10`: 10 waves, 400 connections, 3 200 requests) of 40 concurrent
keep-alive clients over raw `Socket.Tcp` connections. Every client sends 8 requests on its one
connection, two of them pipelined in each even round, each with a different path, header and
body (index-dependent length, up to a few KiB), and checks every response: status, `Connection:
keep-alive`, and a body derived from all three. The server answers with Bytes bodies; every
seventh request is answered 404. At the end the server is closed and the program ends by itself
(a closed server and idle keep-alive connections keep nothing alive).
-}

-- CHECK: EcoSystemHttpServerKeepAlive: True

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Dict
import Http.Server as Server
import Http.Server.Response as Response
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


type Msg
    = Started (Result Server.ServerError Server.Server)
    | GotRequest Server.Request Response.Response
    | Done Bool
    | Closed


type alias Model =
    { flags : StressFlags
    , server : Maybe Server.Server
    , closed : Bool
    }


main : Program StressFlags Model Msg
main =
    Platform.worker
        { init =
            \flags ->
                ( { flags = flags, server = Nothing, closed = False }
                , Server.createServerWith (Server.defaultServerOptions (Address.loopback IPv4) 0)
                    |> Task.attempt Started
                )
        , update = update
        , subscriptions =
            \model ->
                case ( model.server, model.closed ) of
                    ( Just s, False ) ->
                        Server.onRequest s GotRequest

                    _ ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started (Ok server) ->
            ( { model | server = Just server }, Task.perform Done (run server model.flags) )

        Started (Err _) ->
            ( model, Task.perform Done (Task.succeed False) )

        GotRequest request response ->
            let
                index =
                    Dict.get "X-Index" request.headers |> Maybe.andThen String.toInt |> Maybe.withDefault -1

                reply =
                    request.url.path
                        ++ "|"
                        ++ String.fromInt index
                        ++ "|"
                        ++ (Server.bodyAsString request |> Maybe.withDefault "<invalid>")
            in
            ( model
            , response
                |> Response.setStatus (statusFor index)
                |> Response.setBodyAsBytes (toBytes reply)
                |> Response.send
            )

        Done ok ->
            let
                _ =
                    Debug.log "EcoSystemHttpServerKeepAlive" ok
            in
            case model.server of
                Just server ->
                    ( { model | closed = True }, Task.perform (\_ -> Closed) (Server.closeServer server) )

                Nothing ->
                    ( model, Cmd.none )

        Closed ->
            ( model, Cmd.none )


statusFor : Int -> Int
statusFor i =
    if modBy 7 i == 3 then
        404

    else
        200


toBytes : String -> Bytes
toBytes s =
    E.encode (E.string s)


fromBytes : Bytes -> String
fromBytes b =
    D.decode (D.string (Bytes.width b)) b |> Maybe.withDefault "<invalid>"



-- CLIENTS


run : Server.Server -> StressFlags -> Task Never Bool
run server flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (wave server)


async : Task Never a -> Task x (Task Never (Maybe a))
async task =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn
                    (task
                        |> Task.andThen (\v -> Stream.write v (Stream.writable t) |> Task.map (\_ -> ()) |> Task.onError (\_ -> Task.succeed ()))
                    )
                    |> Task.map
                        (\_ ->
                            Stream.read (Stream.readable t)
                                |> Task.map Just
                                |> Task.onError (\_ -> Task.succeed Nothing)
                        )
            )


wave : Server.Server -> Int -> Task Never Bool
wave server w =
    Task.sequence (List.map (\j -> async (client server w j)) (List.range 0 39))
        |> Task.andThen Task.sequence
        |> Task.map (List.all ((==) (Just True)))


crlf : String
crlf =
    "\u{000D}\n"


{-| The request number `r` of client `j` in wave `w`, and the response it expects.
-}
requestOf : Int -> Int -> Int -> ( String, String )
requestOf w j r =
    let
        index =
            (w * 40 + j) * 8 + r

        path =
            "/w" ++ String.fromInt w ++ "/c" ++ String.fromInt j ++ "/r" ++ String.fromInt r

        body =
            String.repeat (modBy 3001 (index * 37)) "b"

        text =
            "POST "
                ++ path
                ++ " HTTP/1.1"
                ++ crlf
                ++ "Host: stress"
                ++ crlf
                ++ "X-Index: "
                ++ String.fromInt index
                ++ crlf
                ++ "Content-Length: "
                ++ String.fromInt (String.length body)
                ++ crlf
                ++ crlf
                ++ body

        expected =
            String.fromInt (statusFor index) ++ " keep-alive " ++ path ++ "|" ++ String.fromInt index ++ "|" ++ body
    in
    ( text, expected )


client : Server.Server -> Int -> Int -> Task Never Bool
client server w j =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (Server.serverPort server))
        |> Task.mapError (\_ -> "connect")
        |> Task.andThen (\conn -> rounds w j conn 0 "" |> Task.andThen (\ok -> Socket.close conn |> Task.map (\_ -> ok)))
        |> Task.onError (\_ -> Task.succeed False)


{-| Round `r` sends one request (odd rounds) or two pipelined ones (even rounds).
-}
rounds : Int -> Int -> Socket.Connection -> Int -> String -> Task String Bool
rounds w j conn r buffer =
    if r >= 8 then
        Task.succeed (buffer == "")

    else
        let
            batch =
                if modBy 2 r == 0 && r + 1 < 8 then
                    [ requestOf w j r, requestOf w j (r + 1) ]

                else
                    [ requestOf w j r ]
        in
        Stream.write (toBytes (String.concat (List.map Tuple.first batch))) (Socket.writable conn)
            |> Task.mapError Stream.errorToString
            |> Task.andThen (\_ -> readResponses (List.length batch) conn buffer [])
            |> Task.andThen
                (\( got, rest ) ->
                    if got == List.map Tuple.second batch then
                        rounds w j conn (r + List.length batch) rest

                    else
                        Task.succeed False
                )


readResponses : Int -> Socket.Connection -> String -> List String -> Task String ( List String, String )
readResponses n conn buffer acc =
    case parseOne buffer of
        Just ( resp, rest ) ->
            if List.length acc + 1 >= n then
                Task.succeed ( acc ++ [ resp ], rest )

            else
                readResponses n conn rest (acc ++ [ resp ])

        Nothing ->
            Stream.read (Socket.readable conn)
                |> Task.mapError Stream.errorToString
                |> Task.andThen (\chunk -> readResponses n conn (buffer ++ fromBytes chunk) acc)


{-| "<status> <connection> <body>" of the first complete response in `buffer`.
-}
parseOne : String -> Maybe ( String, String )
parseOne buffer =
    case List.head (String.indexes (crlf ++ crlf) buffer) of
        Nothing ->
            Nothing

        Just i ->
            let
                lines =
                    String.split crlf (String.left i buffer)

                rest =
                    String.dropLeft (i + 4) buffer

                status =
                    List.head lines |> Maybe.map (String.split " " >> List.drop 1 >> List.head >> Maybe.withDefault "?") |> Maybe.withDefault "?"

                header name =
                    lines
                        |> List.filterMap
                            (\line ->
                                case String.indexes ":" line of
                                    c :: _ ->
                                        if String.toLower (String.left c line) == name then
                                            Just (String.trim (String.dropLeft (c + 1) line))

                                        else
                                            Nothing

                                    [] ->
                                        Nothing
                            )
                        |> List.head

                length =
                    header "content-length" |> Maybe.andThen String.toInt |> Maybe.withDefault 0
            in
            if String.length rest >= length then
                Just
                    ( status ++ " " ++ Maybe.withDefault "-" (header "connection") ++ " " ++ String.left length rest
                    , String.dropLeft length rest
                    )

            else
                Nothing
