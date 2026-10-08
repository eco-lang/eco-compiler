module WebSocketDeflateMatrixTest exposing (main)

{-| permessage-deflate between our client and our server (plans/eco-system-websockets.md §4 WS7,
Appendix D.7): what each side's `compression` reports for a matrix of client offers and server
policies, and that messages (compressible text, pseudo-random binary, short ones under the
threshold, a 300 000-byte one sent in fragments) come back intact over each.

  - defaults: no context takeover either way (the user decision of W8);
  - takeover offered and allowed: no restriction (context kept across messages);
  - takeover offered, default server: the server restricts both directions;
  - default client, takeover server: the client's own restrictions are echoed;
  - window sizes: the client limits the server to 8 bits (deflated with 9) and itself to 9;
  - no offer, or a server that declines: no compression.

Each line: client's view / server's view as ( serverNoContextTakeover, clientNoContextTakeover,
serverMaxWindowBits, clientMaxWindowBits ).
-}

-- CHECK: defaults: client (True,True,15,15) server (True,True,15,15) echo True
-- CHECK: takeover both: client (False,False,15,15) server (False,False,15,15) echo True
-- CHECK: takeover client only: client (True,True,15,15) server (True,True,15,15) echo True
-- CHECK: takeover server only: client (True,True,15,15) server (True,True,15,15) echo True
-- CHECK: window bits: client (False,False,8,9) server (False,False,8,9) echo True
-- CHECK: no offer: client none server none echo True
-- CHECK: declined: client none server none echo True
-- EXIT: 0

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Encode as E
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


pseudoRandom : Int -> Bytes
pseudoRandom n =
    let
        step ( seed, acc ) =
            let
                next =
                    modBy 2147483648 (seed * 1103515245 + 12345)
            in
            ( next, E.unsignedInt8 (Bitwise.and 255 (Bitwise.shiftRightBy 16 next)) :: acc )
    in
    List.foldl (\_ s -> step s) ( 42, [] ) (List.range 1 n)
        |> Tuple.second
        |> E.sequence
        |> E.encode


messages : List WebSocket.Message
messages =
    [ W.text (String.repeat 1000 "abc ")
    , WebSocket.Binary (pseudoRandom 3000)
    , W.text "short"
    , W.text (String.repeat 1000 "abc ")
    , WebSocket.Binary (E.encode (E.sequence (List.repeat 75000 (E.unsignedInt32 Bytes.BE 0x01020304))))
    , W.text "ünïcödé ✓ 𝄞 ünïcödé ✓ 𝄞 ünïcödé ✓ 𝄞 ünïcödé ✓ 𝄞 ünïcödé ✓ 𝄞 ünïcödé ✓ 𝄞"
    , W.binary []
    ]


describeCompression : Maybe WebSocket.Negotiated -> String
describeCompression c =
    case c of
        Just n ->
            "("
                ++ String.join ","
                    [ H.boolString n.serverNoContextTakeover
                    , H.boolString n.clientNoContextTakeover
                    , String.fromInt n.serverMaxWindowBits
                    , String.fromInt n.clientMaxWindowBits
                    ]
                ++ ")"

        Nothing ->
            "none"


oneCase :
    Socket.Listener
    -> ( String, Maybe WebSocket.ClientCompression, Maybe WebSocket.ServerCompression )
    -> Task String String
oneCase listener ( label, client, server ) =
    let
        d =
            WebSocket.defaultAcceptOptions
    in
    H.async (W.acceptWith { d | compression = server } listener |> Task.andThen (\ws -> W.echo ws |> Task.map (\_ -> ws)))
        |> Task.andThen
            (\serverDone ->
                W.connectWith (\o -> { o | compression = client }) listener
                    |> Task.andThen
                        (\c ->
                            W.sendAll messages c
                                |> Task.andThen (\_ -> W.readMessages (List.length messages) c)
                                |> Task.andThen
                                    (\got ->
                                        WebSocket.close WebSocket.Normal "" c
                                            |> Task.mapError W.wsErr
                                            |> Task.andThen (\_ -> serverDone)
                                            |> Task.map
                                                (\s ->
                                                    label
                                                        ++ ": client "
                                                        ++ describeCompression (WebSocket.compression c)
                                                        ++ " server "
                                                        ++ describeCompression (WebSocket.compression s)
                                                        ++ " echo "
                                                        ++ H.boolString (got == messages)
                                                )
                                    )
                        )
            )


cases : List ( String, Maybe WebSocket.ClientCompression, Maybe WebSocket.ServerCompression )
cases =
    let
        dc =
            { clientMaxWindowBits = Just Nothing, serverMaxWindowBits = Nothing, contextTakeover = False, threshold = 64 }

        ds =
            { maxWindowBits = 15, contextTakeover = False, threshold = 64 }
    in
    [ ( "defaults", Just dc, Just ds )
    , ( "takeover both", Just { dc | contextTakeover = True }, Just { ds | contextTakeover = True } )
    , ( "takeover client only", Just { dc | contextTakeover = True }, Just ds )
    , ( "takeover server only", Just dc, Just { ds | contextTakeover = True } )
    , ( "window bits", Just { dc | contextTakeover = True, clientMaxWindowBits = Just (Just 9), serverMaxWindowBits = Just 8, threshold = 0 }, Just { ds | contextTakeover = True, threshold = 0 } )
    , ( "no offer", Nothing, Just ds )
    , ( "declined", Just dc, Nothing )
    ]


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                cases
                    |> List.map (oneCase listener)
                    |> sequence
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String a) -> Task String (List a)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))
