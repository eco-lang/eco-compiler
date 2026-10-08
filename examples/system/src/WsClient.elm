module WsClient exposing (main)

{-| A WebSocket client: connects to a URL, sends the messages given on the command line and prints
every message it receives.

    eco make src/WsClient.elm --output=ws-client
    ./ws-client ws://127.0.0.1:9001/ hello world     # against src/WsEchoServer.elm
    ./ws-client wss://127.0.0.1:9443/ --cacert ca.pem hi

    ws-client URL [--cacert FILE | --insecure] [--no-compression] [MESSAGE ...]

Each `MESSAGE` is sent as a text message. With messages, the client closes the connection once it
has received as many messages as it sent (handy against an echo server); without, it prints
messages until the server closes the connection. Text messages are printed as they are, binary ones
as `<binary N bytes>`; the last line tells how the connection ended.

`--cacert FILE` trusts only the certificate authorities in the PEM file (for a test server);
`--insecure` accepts any certificate. By default the system's certificate authorities are trusted.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Socket
import Socket.Tls
import Stream
import Stream.Log
import System
import System.File
import System.File.Path
import Task exposing (Task)
import WebSocket


type alias Options =
    { url : Maybe String
    , caFile : Maybe String
    , insecure : Bool
    , compression : Bool
    , messages : List String
    }


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env ->
            case parseArgs (List.drop 1 env.args) { url = Nothing, caFile = Nothing, insecure = False, compression = True, messages = [] } of
                Ok ({ url } as options) ->
                    case url of
                        Just u ->
                            run env.stdout u options
                                |> Task.onError
                                    (\problem ->
                                        Stream.Log.line env.stderr ("ws-client: " ++ problem)
                                            |> Task.andThen (\_ -> System.setExitCode 1)
                                    )
                                |> System.endSimpleProgram

                        Nothing ->
                            usage env.stderr "missing URL"

                Err problem ->
                    usage env.stderr problem
        )


usage : Stream.Writable Bytes -> String -> Cmd msg
usage stderr problem =
    Stream.Log.line stderr ("ws-client: " ++ problem ++ "\nusage: ws-client URL [--cacert FILE | --insecure] [--no-compression] [MESSAGE ...]")
        |> Task.andThen (\_ -> System.setExitCode 2)
        |> System.endSimpleProgram


parseArgs : List String -> Options -> Result String Options
parseArgs args options =
    case args of
        [] ->
            Ok { options | messages = List.reverse options.messages }

        "--cacert" :: file :: rest ->
            parseArgs rest { options | caFile = Just file }

        "--insecure" :: rest ->
            parseArgs rest { options | insecure = True }

        "--no-compression" :: rest ->
            parseArgs rest { options | compression = False }

        arg :: rest ->
            if String.startsWith "--" arg then
                Err ("unknown option " ++ arg)

            else if options.url == Nothing then
                parseArgs rest { options | url = Just arg }

            else
                parseArgs rest { options | messages = arg :: options.messages }


run : Stream.Writable Bytes -> String -> Options -> Task String ()
run stdout url options =
    verification options
        |> Task.andThen
            (\v ->
                let
                    d =
                        WebSocket.defaultConnectOptions url

                    connectOptions =
                        { d
                            | verification = v
                            , compression =
                                if options.compression then
                                    d.compression

                                else
                                    Nothing
                        }
                in
                WebSocket.connect connectOptions |> Task.mapError Socket.errorToString
            )
        |> Task.andThen
            (\ws ->
                Stream.Log.line stdout ("connected to " ++ url ++ describe ws)
                    |> Task.andThen (\_ -> sendAll options.messages ws)
                    |> Task.andThen
                        (\_ ->
                            receive stdout
                                (if List.isEmpty options.messages then
                                    -1

                                 else
                                    List.length options.messages
                                )
                                ws
                        )
                    |> Task.andThen (\_ -> WebSocket.closed ws)
                    |> Task.andThen (\info -> Stream.Log.line stdout (describeClose info))
            )


verification : Options -> Task String Socket.Tls.Verification
verification options =
    case options.caFile of
        Just file ->
            System.File.readFile (System.File.Path.fromPosixString file)
                |> Task.mapError System.File.errorToString
                |> Task.map
                    (\bytes ->
                        Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
                            |> Maybe.withDefault ""
                            |> Socket.Tls.TrustedCertificates
                    )

        Nothing ->
            if options.insecure then
                Task.succeed Socket.Tls.NoVerification

            else
                Task.succeed Socket.Tls.SystemCertificates


sendAll : List String -> WebSocket.WebSocket WebSocket.Whole -> Task String ()
sendAll messages ws =
    case messages of
        [] ->
            Task.succeed ()

        text :: rest ->
            Stream.write (WebSocket.Text text) (WebSocket.writable ws)
                |> Task.mapError Stream.errorToString
                |> Task.andThen (\_ -> sendAll rest ws)


{-| Print messages: `remaining` more (then close), or until the connection ends when negative.
-}
receive : Stream.Writable Bytes -> Int -> WebSocket.WebSocket WebSocket.Whole -> Task String ()
receive stdout remaining ws =
    if remaining == 0 then
        WebSocket.close WebSocket.Normal "" ws |> Task.mapError Socket.errorToString

    else
        Stream.read (WebSocket.readable ws)
            |> Task.map Just
            |> Task.onError
                (\err ->
                    case err of
                        Stream.Closed ->
                            Task.succeed Nothing

                        _ ->
                            Task.fail (Stream.errorToString err)
                )
            |> Task.andThen
                (\received ->
                    case received of
                        Just message ->
                            Stream.Log.line stdout (showMessage message)
                                |> Task.andThen (\_ -> receive stdout (remaining - 1) ws)

                        Nothing ->
                            Task.succeed ()
                )


showMessage : WebSocket.Message -> String
showMessage message =
    case message of
        WebSocket.Text text ->
            text

        WebSocket.Binary bytes ->
            "<binary " ++ String.fromInt (Bytes.width bytes) ++ " bytes>"


describe : WebSocket.WebSocket WebSocket.Whole -> String
describe ws =
    (case WebSocket.protocol ws of
        Just p ->
            " (protocol " ++ p ++ ")"

        Nothing ->
            ""
    )
        ++ (case WebSocket.compression ws of
                Just _ ->
                    " with permessage-deflate"

                Nothing ->
                    ""
           )


describeClose : WebSocket.CloseInfo -> String
describeClose info =
    "closed: "
        ++ closeCodeName info.code
        ++ (if String.isEmpty info.reason then
                ""

            else
                " \"" ++ info.reason ++ "\""
           )
        ++ (if info.clean then
                " (clean)"

            else
                " (not clean)"
           )


closeCodeName : WebSocket.CloseCode -> String
closeCodeName code =
    case code of
        WebSocket.Normal ->
            "1000 Normal"

        WebSocket.GoingAway ->
            "1001 GoingAway"

        WebSocket.ProtocolError ->
            "1002 ProtocolError"

        WebSocket.UnsupportedData ->
            "1003 UnsupportedData"

        WebSocket.NoStatus ->
            "1005 NoStatus"

        WebSocket.Abnormal ->
            "1006 Abnormal"

        WebSocket.InvalidData ->
            "1007 InvalidData"

        WebSocket.PolicyViolation ->
            "1008 PolicyViolation"

        WebSocket.MessageTooBig ->
            "1009 MessageTooBig"

        WebSocket.MandatoryExtension ->
            "1010 MandatoryExtension"

        WebSocket.InternalError ->
            "1011 InternalError"

        WebSocket.Other n ->
            String.fromInt n
