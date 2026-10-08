module WebSocketExitTest exposing (main)

{-| Keep-alive (plans/eco-system-websockets.md §4 WS4, §3.6 "Keep-alive counts"): the only thing
this program waits for is an `onMessage` subscription on an accepted WebSocket. The client is a
detached Node process (it does not keep the program alive) that sends a message half a second
after the handshake, so the subscription must keep the program running until it arrives. Once the
subscription is gone, nothing is subscribed or parked, and the program exits by itself although
the WebSocket is still open (heartbeat timers hold nothing).
-}

-- CHECK: got: Text "hello"
-- CHECK: unsubscribed
-- EXIT: 0

import Socket
import SocketTestHelp as H
import Stream.Log
import System
import System.Process as Process
import Task
import WebSocket exposing (WebSocket, Whole)
import WebSocketTestHelp as W


type Msg
    = Listening (Result String Socket.Listener)
    | Accepted (Result String (WebSocket Whole))
    | Started
    | ClientExit Int
    | Got WebSocket.Message
    | Done


type alias Model =
    { env : System.Environment
    , ws : Maybe (WebSocket Whole)
    , subscribed : Bool
    }


client : Int -> String
client port_ =
    String.join ""
        [ "const net=require('net');"
        , "const s=net.connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{s.write('GET / HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
        , "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n');});"
        , "let got=false;"
        , "s.on('data',()=>{if(got)return;got=true;setTimeout(()=>{const p=Buffer.from('hello');"
        , "s.write(Buffer.concat([Buffer.from([0x81,0x80|p.length,0,0,0,0]),p]));},500);});"
        , "s.on('close',()=>process.exit(0));s.on('error',()=>process.exit(0));"
        , "setTimeout(()=>process.exit(0),20000).unref();"
        ]


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, ws = Nothing, subscribed = False }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions =
            \model ->
                case ( model.ws, model.subscribed ) of
                    ( Just ws, True ) ->
                        WebSocket.onMessage ws Got

                    _ ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( model
            , Cmd.batch
                [ W.acceptOne l
                    |> Task.andThen (\ws -> Socket.closeListener l |> Task.mapError W.wsErr |> Task.map (\_ -> ws))
                    |> Task.attempt Accepted
                , Process.spawn "node"
                    [ "-e", client (H.portOf l) ]
                    (Process.defaultSpawnOptions (Process.Detached (\_ -> Started)) ClientExit
                        |> (\o -> { o | shell = Process.NoShell })
                    )
                ]
            )

        Listening (Err e) ->
            ( model, Task.perform (\_ -> Done) (Stream.Log.line model.env.stdout ("error " ++ e)) )

        Accepted (Ok ws) ->
            ( { model | ws = Just ws, subscribed = True }, Cmd.none )

        Accepted (Err e) ->
            ( model, Task.perform (\_ -> Done) (Stream.Log.line model.env.stdout ("error " ++ e)) )

        Got m ->
            ( { model | subscribed = False }
            , Task.perform (\_ -> Done) (Stream.Log.line model.env.stdout ("got: " ++ W.messageString m ++ "\nunsubscribed"))
            )

        Started ->
            ( model, Cmd.none )

        ClientExit _ ->
            ( model, Cmd.none )

        Done ->
            ( model, Cmd.none )
