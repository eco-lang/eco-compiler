module WebSocketTestHelp exposing
    ( url, connect, connectWith, acceptOne, acceptWith, upgrade
    , messageString, readMessages, readAll, sendAll, echo, describe, closeInfoString, codeString
    , text, binary, bytesOfList, rawWrite, rawRead, rawReadAll, rawUpgrade, rawUpgradeClient
    , frame, maskedFrame, closePayload, hexOf, wsErr
    , parseFrames, framesString, rawHandshake, request, latin1, listOfBytes, concatBytes
    , switching, rawUntilClose
    , connectStreamed, acceptStreamed, acceptStreamedWith, patternSource, readPatternBody, readTextBody
    , rssKiB, parseFramesFin, framesFinString, sendEach, writeAll, noCompression
    , zeroMaskedFrame, rawHandshakeHead, headerOf
    )

{-| Shared helpers for the WebSocket tests (not a test: no `main`; plans/eco-system-websockets.md
§4 WS4). A server is a `Socket.Tcp` listener whose connections are upgraded with
`WebSocket.upgradeRequest`; malformed peers are written by hand over raw `Socket.Tcp`
connections, with `frame` / `maskedFrame` building the bytes.
-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Process
import Socket
import Socket.Tcp
import SocketTestHelp as H
import Stream
import System.File
import System.File.Path as Path
import Task exposing (Task)
import WebSocket


wsErr : Socket.Error -> String
wsErr e =
    Socket.errorToString e


{-| `ws://127.0.0.1:<port><path>` of a listener.
-}
url : Socket.Listener -> String -> String
url listener path =
    "ws://127.0.0.1:" ++ String.fromInt (H.portOf listener) ++ path


connect : Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Whole)
connect listener =
    connectWith identity listener


connectWith : (WebSocket.ConnectOptions -> WebSocket.ConnectOptions) -> Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Whole)
connectWith change listener =
    WebSocket.connect (change (WebSocket.defaultConnectOptions (url listener "/test")))
        |> Task.mapError
            (\e ->
                "err "
                    ++ Socket.errorCode e
                    ++ " status "
                    ++ (case WebSocket.handshakeStatus e of
                            Just s ->
                                "Just " ++ String.fromInt s

                            Nothing ->
                                "Nothing"
                       )
                    ++ " failed "
                    ++ H.boolString (WebSocket.errorIsHandshakeFailed e)
            )


{-| Accept one connection and upgrade it with the default options.
-}
acceptOne : Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Whole)
acceptOne =
    acceptWith WebSocket.defaultAcceptOptions


acceptWith : WebSocket.AcceptOptions -> Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Whole)
acceptWith options listener =
    upgrade listener
        |> Task.andThen (\up -> WebSocket.accept options up |> Task.mapError wsErr)


upgrade : Socket.Listener -> Task String WebSocket.Upgrade
upgrade listener =
    Socket.accept listener
        |> Task.andThen WebSocket.upgradeRequest
        |> Task.mapError wsErr


text : String -> WebSocket.Message
text =
    WebSocket.Text


binary : List Int -> WebSocket.Message
binary ints =
    WebSocket.Binary (bytesOfList ints)


bytesOfList : List Int -> Bytes
bytesOfList ints =
    E.encode (E.sequence (List.map E.unsignedInt8 ints))


listOfBytes : Bytes -> List Int
listOfBytes b =
    D.decode (D.loop ( Bytes.width b, [] ) step) b |> Maybe.withDefault []


step : ( Int, List Int ) -> D.Decoder (D.Step ( Int, List Int ) (List Int))
step ( n, acc ) =
    if n <= 0 then
        D.succeed (D.Done (List.reverse acc))

    else
        D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8


hexOf : Bytes -> String
hexOf b =
    listOfBytes b |> List.map hexByte |> String.join " "


hexByte : Int -> String
hexByte n =
    let
        digit d =
            String.slice d (d + 1) "0123456789abcdef"
    in
    digit (n // 16) ++ digit (modBy 16 n)


{-| `Text "..."` / `Binary [1,2,3]` (binary longer than 16 bytes: its size).
-}
messageString : WebSocket.Message -> String
messageString m =
    case m of
        WebSocket.Text t ->
            "Text " ++ "\"" ++ t ++ "\""

        WebSocket.Binary b ->
            if Bytes.width b > 16 then
                "Binary " ++ String.fromInt (Bytes.width b) ++ " bytes"

            else
                "Binary [" ++ String.join "," (List.map String.fromInt (listOfBytes b)) ++ "]"


{-| Read `n` messages.
-}
readMessages : Int -> WebSocket.WebSocket WebSocket.Whole -> Task String (List WebSocket.Message)
readMessages n ws =
    if n <= 0 then
        Task.succeed []

    else
        Stream.read (WebSocket.readable ws)
            |> Task.mapError Stream.errorToString
            |> Task.andThen (\m -> readMessages (n - 1) ws |> Task.map (\rest -> m :: rest))


{-| Read to the end: the messages, and how the readable ended (`Closed` or the error).
-}
readAll : WebSocket.WebSocket WebSocket.Whole -> Task x ( List WebSocket.Message, String )
readAll ws =
    let
        loop acc =
            Stream.read (WebSocket.readable ws)
                |> Task.map (\m -> Ok m)
                |> Task.onError (\e -> Task.succeed (Err e))
                |> Task.andThen
                    (\r ->
                        case r of
                            Ok m ->
                                loop (m :: acc)

                            Err e ->
                                Task.succeed ( List.reverse acc, Stream.errorToString e )
                    )
    in
    loop []


sendAll : List WebSocket.Message -> WebSocket.WebSocket mode -> Task String ()
sendAll messages ws =
    messages
        |> List.map (\m -> Stream.write m (WebSocket.writable ws))
        |> Task.sequence
        |> Task.map (\_ -> ())
        |> Task.mapError Stream.errorToString


{-| Echo every message until the readable ends; the end as `readAll` reports it.
-}
echo : WebSocket.WebSocket WebSocket.Whole -> Task x String
echo ws =
    Stream.read (WebSocket.readable ws)
        |> Task.map Ok
        |> Task.onError (\e -> Task.succeed (Err e))
        |> Task.andThen
            (\r ->
                case r of
                    Ok m ->
                        Stream.write m (WebSocket.writable ws)
                            |> Task.map (\_ -> ())
                            |> Task.onError (\_ -> Task.succeed ())
                            |> Task.andThen (\_ -> echo ws)

                    Err e ->
                        Task.succeed (Stream.errorToString e)
            )


describe : Task Socket.Error a -> Task x String
describe task =
    task
        |> Task.map (\_ -> "ok")
        |> Task.onError (\e -> Task.succeed ("err " ++ Socket.errorCode e))


codeString : WebSocket.CloseCode -> String
codeString code =
    case code of
        WebSocket.Normal ->
            "Normal"

        WebSocket.GoingAway ->
            "GoingAway"

        WebSocket.ProtocolError ->
            "ProtocolError"

        WebSocket.UnsupportedData ->
            "UnsupportedData"

        WebSocket.NoStatus ->
            "NoStatus"

        WebSocket.Abnormal ->
            "Abnormal"

        WebSocket.InvalidData ->
            "InvalidData"

        WebSocket.PolicyViolation ->
            "PolicyViolation"

        WebSocket.MessageTooBig ->
            "MessageTooBig"

        WebSocket.MandatoryExtension ->
            "MandatoryExtension"

        WebSocket.InternalError ->
            "InternalError"

        WebSocket.Other n ->
            "Other " ++ String.fromInt n


closeInfoString : WebSocket.CloseInfo -> String
closeInfoString info =
    codeString info.code ++ " \"" ++ info.reason ++ "\" clean " ++ H.boolString info.clean



-- RAW PEERS


rawWrite : Bytes -> Socket.Connection -> Task String ()
rawWrite bytes conn =
    Stream.write bytes (Socket.writable conn)
        |> Task.map (\_ -> ())
        |> Task.mapError Stream.errorToString


{-| One chunk from a raw connection.
-}
rawRead : Socket.Connection -> Task String Bytes
rawRead conn =
    Stream.read (Socket.readable conn)
        |> Task.mapError Stream.errorToString


{-| Everything until the peer closes (or the read fails), as bytes.
-}
rawReadAll : Socket.Connection -> Task x Bytes
rawReadAll conn =
    let
        loop acc =
            Stream.read (Socket.readable conn)
                |> Task.map Just
                |> Task.onError (\_ -> Task.succeed Nothing)
                |> Task.andThen
                    (\r ->
                        case r of
                            Just chunk ->
                                loop (chunk :: acc)

                            Nothing ->
                                Task.succeed (E.encode (E.sequence (List.map E.bytes (List.reverse acc))))
                    )
    in
    loop []


{-| A raw client's opening request (a valid one), and the server's response read up to its blank
line (the bytes after it are returned too).
-}
rawUpgrade : Socket.Listener -> Task String ( Socket.Connection, String, Bytes )
rawUpgrade listener =
    H.socketErr (H.connectTo listener)
        |> Task.andThen
            (\conn ->
                rawWrite (H.bytesOf (request "dGhlIHNhbXBsZSBub25jZQ==" [])) conn
                    |> Task.andThen (\_ -> readHead conn emptyBytes)
                    |> Task.map (\( head, rest ) -> ( conn, head, rest ))
            )


request : String -> List String -> String
request key extra =
    String.join "\u{000D}\n"
        ([ "GET /raw HTTP/1.1"
         , "Host: 127.0.0.1"
         , "Upgrade: websocket"
         , "Connection: Upgrade"
         , "Sec-WebSocket-Key: " ++ key
         , "Sec-WebSocket-Version: 13"
         ]
            ++ extra
        )
        ++ "\u{000D}\n\u{000D}\n"


readHead : Socket.Connection -> Bytes -> Task String ( String, Bytes )
readHead conn acc =
    rawRead conn
        |> Task.andThen
            (\chunk ->
                let
                    all =
                        E.encode (E.sequence [ E.bytes acc, E.bytes chunk ])

                    s =
                        latin1 all
                in
                case String.indexes "\u{000D}\n\u{000D}\n" s of
                    i :: _ ->
                        Task.succeed ( String.left (i + 4) s, dropBytes (i + 4) all )

                    [] ->
                        readHead conn all
            )


emptyBytes : Bytes
emptyBytes =
    E.encode (E.sequence [])


latin1 : Bytes -> String
latin1 b =
    listOfBytes b |> List.map Char.fromCode |> String.fromList


dropBytes : Int -> Bytes -> Bytes
dropBytes n b =
    D.decode (D.bytes n |> D.andThen (\_ -> D.bytes (Bytes.width b - n))) b
        |> Maybe.withDefault emptyBytes


{-| A raw server for one client: accepts a connection, reads the request head, writes `response`
(the whole response, possibly followed by frames). Returns the connection and the request.
-}
rawUpgradeClient : Socket.Listener -> (String -> Bytes) -> Task String ( Socket.Connection, String )
rawUpgradeClient listener response =
    H.socketErr (Socket.accept listener)
        |> Task.andThen
            (\conn ->
                readHead conn emptyBytes
                    |> Task.andThen
                        (\( head, _ ) ->
                            rawWrite (response (keyOf head)) conn
                                |> Task.map (\_ -> ( conn, head ))
                        )
            )


keyOf : String -> String
keyOf head =
    String.lines head
        |> List.filterMap
            (\line ->
                if String.startsWith "sec-websocket-key:" (String.toLower line) then
                    Just (String.trim (String.dropLeft 18 line))

                else
                    Nothing
            )
        |> List.head
        |> Maybe.withDefault ""



-- FRAMES


{-| An unmasked frame: FIN, RSV bits (0-7), opcode, payload.
-}
frame : Bool -> Int -> Int -> Bytes -> Bytes
frame fin rsv opcode payload =
    E.encode (E.sequence [ header fin rsv opcode False (Bytes.width payload), E.bytes payload ])


{-| A frame masked with the key 1 2 3 4.
-}
maskedFrame : Bool -> Int -> Int -> Bytes -> Bytes
maskedFrame fin rsv opcode payload =
    let
        key =
            [ 1, 2, 3, 4 ]

        masked =
            listOfBytes payload
                |> List.indexedMap (\i x -> Bitwise.xor x (Maybe.withDefault 0 (List.head (List.drop (modBy 4 i) key))))
    in
    E.encode
        (E.sequence
            [ header fin rsv opcode True (Bytes.width payload)
            , E.sequence (List.map E.unsignedInt8 key)
            , E.sequence (List.map E.unsignedInt8 masked)
            ]
        )


{-| A client frame masked with the key 0 0 0 0 (the payload goes out as it is: fast for big
payloads).
-}
zeroMaskedFrame : Bool -> Int -> Int -> Bytes -> Bytes
zeroMaskedFrame fin rsv opcode payload =
    E.encode
        (E.sequence
            [ header fin rsv opcode True (Bytes.width payload)
            , E.unsignedInt32 Bytes.BE 0
            , E.bytes payload
            ]
        )


header : Bool -> Int -> Int -> Bool -> Int -> E.Encoder
header fin rsv opcode masked len =
    let
        b0 =
            (if fin then
                0x80

             else
                0
            )
                + (rsv * 16)
                + opcode

        m =
            if masked then
                0x80

            else
                0
    in
    if len < 126 then
        E.sequence [ E.unsignedInt8 b0, E.unsignedInt8 (m + len) ]

    else if len <= 0xFFFF then
        E.sequence [ E.unsignedInt8 b0, E.unsignedInt8 (m + 126), E.unsignedInt16 Bytes.BE len ]

    else
        E.sequence [ E.unsignedInt8 b0, E.unsignedInt8 (m + 127), E.unsignedInt32 Bytes.BE 0, E.unsignedInt32 Bytes.BE len ]


closePayload : Int -> String -> Bytes
closePayload code reason =
    E.encode (E.sequence [ E.unsignedInt16 Bytes.BE code, E.string reason ])



{-| The frames in raw bytes (masked or not): ( opcode, payload ), FIN and RSV ignored; an
incomplete last frame is dropped.
-}
parseFrames : Bytes -> List ( Int, List Int )
parseFrames bytes =
    framesOf (listOfBytes bytes) []


framesOf : List Int -> List ( Int, List Int ) -> List ( Int, List Int )
framesOf data acc =
    case data of
        b0 :: b1 :: rest ->
            let
                opcode =
                    modBy 16 b0

                masked =
                    b1 >= 128

                len7 =
                    modBy 128 b1

                ( len, afterLen ) =
                    if len7 == 126 then
                        ( List.foldl (\x a -> a * 256 + x) 0 (List.take 2 rest), List.drop 2 rest )

                    else if len7 == 127 then
                        ( List.foldl (\x a -> a * 256 + x) 0 (List.take 8 rest), List.drop 8 rest )

                    else
                        ( len7, rest )

                ( key, body ) =
                    if masked then
                        ( List.take 4 afterLen, List.drop 4 afterLen )

                    else
                        ( [ 0, 0, 0, 0 ], afterLen )

                payload =
                    List.take len body
                        |> List.indexedMap (\i x -> Bitwise.xor x (Maybe.withDefault 0 (List.head (List.drop (modBy 4 i) key))))
            in
            if List.length body < len then
                List.reverse acc

            else
                framesOf (List.drop len body) (( opcode, payload ) :: acc)

        _ ->
            List.reverse acc


{-| `ping [1,2] | close 1002 "reason"` ...
-}
framesString : List ( Int, List Int ) -> String
framesString frames =
    frames
        |> List.map
            (\( op, payload ) ->
                case op of
                    8 ->
                        case payload of
                            hi :: lo :: reason ->
                                "close " ++ String.fromInt (hi * 256 + lo) ++ " \"" ++ String.fromList (List.map Char.fromCode reason) ++ "\""

                            _ ->
                                "close"

                    9 ->
                        "ping " ++ String.fromInt (List.length payload)

                    10 ->
                        "pong [" ++ String.join "," (List.map String.fromInt payload) ++ "]"

                    1 ->
                        "text \"" ++ String.fromList (List.map Char.fromCode payload) ++ "\""

                    2 ->
                        "binary " ++ String.fromInt (List.length payload)

                    _ ->
                        "op " ++ String.fromInt op
            )
        |> String.join " | "


{-| A raw client that sends `bytes` right after a valid opening request (in one write), and reads
the response head; returns the connection, the status line, and the bytes after the head.
-}
rawHandshake : Socket.Listener -> List String -> Bytes -> Task String ( Socket.Connection, String, Bytes )
rawHandshake listener extraHeaders after =
    H.socketErr (H.connectTo listener)
        |> Task.andThen
            (\conn ->
                rawWrite (E.encode (E.sequence [ E.bytes (H.bytesOf (request "dGhlIHNhbXBsZSBub25jZQ==" extraHeaders)), E.bytes after ])) conn
                    |> Task.andThen (\_ -> readHead conn emptyBytes)
                    |> Task.map (\( head, rest ) -> ( conn, String.lines head |> List.head |> Maybe.map String.trim |> Maybe.withDefault "", rest ))
            )


concatBytes : Bytes -> Bytes -> Bytes
concatBytes a b =
    E.encode (E.sequence [ E.bytes a, E.bytes b ])


{-| A 101 answer for a client's key (the accept computed in Elm, WebSocketSha1).
-}
switching : (String -> String) -> String -> List String -> Bytes
switching acceptFor key extra =
    H.bytesOf
        (String.join "\u{000D}\n"
            ([ "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: " ++ acceptFor key ]
                ++ extra
            )
            ++ "\u{000D}\n\u{000D}\n"
        )


{-| A raw server's side after the handshake: read until a Close frame arrives (or the connection
ends), answer it with Close 1000, close the connection; the frames received.
-}
rawUntilClose : Socket.Connection -> Task x (List ( Int, List Int ))
rawUntilClose conn =
    let
        loop acc =
            Stream.read (Socket.readable conn)
                |> Task.map Just
                |> Task.onError (\_ -> Task.succeed Nothing)
                |> Task.andThen
                    (\r ->
                        case r of
                            Just chunk ->
                                let
                                    all =
                                        concatBytes acc chunk

                                    frames =
                                        parseFrames all
                                in
                                if List.any (\( op, _ ) -> op == 8) frames then
                                    rawWrite (frame True 0 8 (closePayload 1000 "")) conn
                                        |> Task.onError (\_ -> Task.succeed ())
                                        |> Task.andThen (\_ -> Socket.close conn)
                                        |> Task.map (\_ -> frames)

                                else
                                    loop all

                            Nothing ->
                                Socket.close conn |> Task.map (\_ -> parseFrames acc)
                    )
    in
    loop emptyBytes



-- STREAMED MESSAGES (WS6)


connectStreamed : (WebSocket.ConnectOptions -> WebSocket.ConnectOptions) -> Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Streamed)
connectStreamed change listener =
    WebSocket.connectStreamed (change (WebSocket.defaultConnectOptions (url listener "/test")))
        |> Task.mapError wsErr


acceptStreamed : Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Streamed)
acceptStreamed =
    acceptStreamedWith WebSocket.defaultAcceptOptions


acceptStreamedWith : WebSocket.AcceptOptions -> Socket.Listener -> Task String (WebSocket.WebSocket WebSocket.Streamed)
acceptStreamedWith options listener =
    upgrade listener
        |> Task.andThen (\up -> WebSocket.acceptStreamed options up |> Task.mapError wsErr)


{-| Connection options without permessage-deflate (for tests that look at the bytes on the wire).
-}
noCompression : WebSocket.ConnectOptions -> WebSocket.ConnectOptions
noCompression o =
    { o | compression = Nothing }


{-| A readable of `count` chunks of `size` bytes (`size` a multiple of 256) whose bytes count
0..255 over and over, written by a process of its own. The same chunk value is written every
time: the source holds one chunk, whatever `count` is.
-}
patternSource : Int -> Int -> Task String (Stream.Readable Bytes)
patternSource count size =
    let
        block =
            E.sequence (List.map E.unsignedInt8 (List.range 0 255))

        chunk =
            E.encode (E.sequence (List.repeat (size // 256) block))
    in
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                let
                    loop n =
                        if n <= 0 then
                            Stream.closeWritable (Stream.writable t)

                        else
                            Stream.write chunk (Stream.writable t) |> Task.andThen (\_ -> loop (n - 1))
                in
                Process.spawn (loop count |> Task.onError (\_ -> Task.succeed ()))
                    |> Task.map (\_ -> Stream.readable t)
            )
        |> Task.mapError never


{-| Read a body made by `patternSource` to its end: its size, and whether every chunk starts with
the byte its offset calls for (data lost, repeated or reordered shows).
-}
readPatternBody : Stream.Readable Bytes -> Task String ( Int, Bool )
readPatternBody body =
    let
        loop offset ok =
            Stream.read body
                |> Task.map Just
                |> Task.onError
                    (\e ->
                        case e of
                            Stream.Closed ->
                                Task.succeed Nothing

                            _ ->
                                Task.fail ("body: " ++ Stream.errorToString e)
                    )
                |> Task.andThen
                    (\r ->
                        case r of
                            Nothing ->
                                Task.succeed ( offset, ok )

                            Just chunk ->
                                loop (offset + Bytes.width chunk) (ok && D.decode D.unsignedInt8 chunk == Just (modBy 256 offset))
                    )
    in
    loop 0 True


{-| Read a text body to its end: its chunks, and how it ended (`Closed` or the error).
-}
readTextBody : Stream.Readable String -> Task x ( List String, String )
readTextBody body =
    let
        loop acc =
            Stream.read body
                |> Task.map Ok
                |> Task.onError (\e -> Task.succeed (Err e))
                |> Task.andThen
                    (\r ->
                        case r of
                            Ok chunk ->
                                loop (chunk :: acc)

                            Err e ->
                                Task.succeed ( List.reverse acc, Stream.errorToString e )
                    )
    in
    loop []


{-| This process's resident set size in KiB (`VmRSS` of /proc/self/status), -1 if unknown.
-}
rssKiB : Task x Int
rssKiB =
    System.File.readFile (Path.fromPosixString "/proc/self/status")
        |> Task.map
            (\b ->
                D.decode (D.string (Bytes.width b)) b
                    |> Maybe.withDefault ""
                    |> String.lines
                    |> List.filter (String.startsWith "VmRSS:")
                    |> List.head
                    |> Maybe.map (String.dropLeft 6 >> String.trim >> String.words >> List.head >> Maybe.andThen String.toInt >> Maybe.withDefault -1)
                    |> Maybe.withDefault -1
            )
        |> Task.onError (\_ -> Task.succeed -1)


{-| The frames in raw bytes: ( FIN, RSV1, opcode, payload ); an incomplete last frame is dropped.
-}
parseFramesFin : Bytes -> List ( ( Bool, Bool ), Int, List Int )
parseFramesFin bytes =
    framesFinOf (listOfBytes bytes) []


framesFinOf : List Int -> List ( ( Bool, Bool ), Int, List Int ) -> List ( ( Bool, Bool ), Int, List Int )
framesFinOf data acc =
    case data of
        b0 :: _ ->
            case framesOf data [] of
                ( op, payload ) :: _ ->
                    let
                        size =
                            frameSize data
                    in
                    framesFinOf (List.drop size data) (( ( b0 >= 128, modBy 128 b0 >= 64 ), op, payload ) :: acc)

                [] ->
                    List.reverse acc

        [] ->
            List.reverse acc


frameSize : List Int -> Int
frameSize data =
    case data of
        _ :: b1 :: rest ->
            let
                len7 =
                    modBy 128 b1

                ( len, extra ) =
                    if len7 == 126 then
                        ( List.foldl (\x a -> a * 256 + x) 0 (List.take 2 rest), 2 )

                    else if len7 == 127 then
                        ( List.foldl (\x a -> a * 256 + x) 0 (List.take 8 rest), 8 )

                    else
                        ( len7, 0 )
            in
            2
                + extra
                + (if b1 >= 128 then
                    4

                   else
                    0
                  )
                + len

        _ ->
            0


{-| `text "a" | cont FIN "b" | pong [1]` ... (`FIN` marks final frames, `Z` compressed ones).
-}
framesFinString : List ( ( Bool, Bool ), Int, List Int ) -> String
framesFinString frames =
    frames
        |> List.map
            (\( ( fin, rsv1 ), op, payload ) ->
                (case op of
                    0 ->
                        "cont"

                    1 ->
                        "text"

                    2 ->
                        "binary"

                    8 ->
                        "close"

                    9 ->
                        "ping"

                    10 ->
                        "pong"

                    _ ->
                        "op " ++ String.fromInt op
                )
                    ++ (if fin then
                            " FIN"

                        else
                            ""
                       )
                    ++ (if rsv1 then
                            " Z"

                        else
                            ""
                       )
                    ++ (if op == 1 || op == 0 then
                            " \"" ++ String.fromList (List.map Char.fromCode payload) ++ "\""

                        else if op == 8 then
                            case payload of
                                hi :: lo :: _ ->
                                    " " ++ String.fromInt (hi * 256 + lo)

                                _ ->
                                    ""

                        else
                            " [" ++ String.join "," (List.map String.fromInt payload) ++ "]"
                       )
            )
        |> String.join " | "


sendEach : Socket.Connection -> List Bytes -> Task String ()
sendEach conn frames =
    case frames of
        [] ->
            Task.succeed ()

        f :: rest ->
            rawWrite f conn |> Task.andThen (\_ -> sendEach conn rest)


{-| Write values to a writable, then close it.
-}
writeAll : List a -> Stream.Writable a -> Task String ()
writeAll values w =
    case values of
        [] ->
            Stream.closeWritable w |> Task.mapError Stream.errorToString

        v :: rest ->
            Stream.write v w |> Task.mapError Stream.errorToString |> Task.andThen (\_ -> writeAll rest w)


{-| A raw client's valid opening request with extra headers (sent with `after` in one write); the
response head (up to its blank line) and the bytes after it.
-}
rawHandshakeHead : Socket.Listener -> List String -> Bytes -> Task String ( Socket.Connection, String, Bytes )
rawHandshakeHead listener extraHeaders after =
    H.socketErr (H.connectTo listener)
        |> Task.andThen
            (\conn ->
                rawWrite (E.encode (E.sequence [ E.bytes (H.bytesOf (request "dGhlIHNhbXBsZSBub25jZQ==" extraHeaders)), E.bytes after ])) conn
                    |> Task.andThen (\_ -> readHead conn emptyBytes)
                    |> Task.map (\( head, rest ) -> ( conn, head, rest ))
            )


{-| A header's value in an HTTP head (the first one; names compared case-insensitively), or
"none".
-}
headerOf : String -> String -> String
headerOf name head =
    String.lines head
        |> List.map String.trim
        |> List.filterMap
            (\line ->
                if String.startsWith (String.toLower name ++ ":") (String.toLower line) then
                    Just (String.trim (String.dropLeft (String.length name + 1) line))

                else
                    Nothing
            )
        |> List.head
        |> Maybe.withDefault "none"
