module WsChat exposing (main)

{-| A WebSocket chat server: every text message a client sends goes to all connected clients.

    eco make src/WsChat.elm --output=ws-chat && ./ws-chat 9002

Open `http://127.0.0.1:9002/` in a few browser windows (the page is a small chat client), or use
`src/WsClient.elm`:

    ./ws-client ws://127.0.0.1:9002/chat

The port is the first argument (default 9002). Each client gets a name (`guest1`, `guest2`, ...);
joins and leaves are announced. Messages arrive through `WebSocket.onMessage` subscriptions, one per
connection. The server runs until the process is stopped.

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Http.Server as Server exposing (Request, Server)
import Http.Server.Response as Response exposing (Response)
import Socket
import Socket.Address as Address
import Stream
import Stream.Log
import System
import Task
import WebSocket


type alias Client =
    { name : String
    , ws : WebSocket.WebSocket WebSocket.Whole
    }


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , server : Maybe Server
    , clients : Dict Int Client
    , nextId : Int
    }


type Msg
    = Started (Result Server.ServerError Server)
    | Received Request Response
    | Joined Int (Result Socket.Error (WebSocket.WebSocket WebSocket.Whole))
    | Said String WebSocket.Message
    | Left Int WebSocket.CloseInfo
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
    let
        port_ =
            env.args |> List.drop 1 |> List.head |> Maybe.andThen String.toInt |> Maybe.withDefault 9002
    in
    ( { stdout = env.stdout, stderr = env.stderr, server = Nothing, clients = Dict.empty, nextId = 1 }
    , Server.createServerWith (Server.defaultServerOptions (Address.loopback Address.IPv4) port_)
        |> Task.attempt Started
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started (Ok server) ->
            ( { model | server = Just server }
            , log model.stdout ("ws-chat: open http://127.0.0.1:" ++ String.fromInt (Server.serverPort server) ++ "/")
            )

        Started (Err (Server.ServerError err)) ->
            ( model
            , Cmd.batch [ log model.stderr ("ws-chat: " ++ err.message), System.exitWithCode 1 ]
            )

        Received request response ->
            if request.upgrade == Just "websocket" then
                ( { model | nextId = model.nextId + 1 }
                , Server.upgradeRequest request response
                    |> Task.andThen (WebSocket.accept WebSocket.defaultAcceptOptions)
                    |> Task.attempt (Joined model.nextId)
                )

            else if request.url.path == "/" then
                ( model
                , response
                    |> Response.setHeader "Content-Type" "text/html; charset=utf-8"
                    |> Response.setBody page
                    |> Response.send
                )

            else
                ( model, response |> Response.setStatus 404 |> Response.setBody "not found\n" |> Response.send )

        Joined id (Ok ws) ->
            let
                client =
                    { name = "guest" ++ String.fromInt id, ws = ws }

                clients =
                    Dict.insert id client model.clients
            in
            ( { model | clients = clients }
            , Cmd.batch
                [ send ws ("* you are " ++ client.name)
                , broadcast clients ("* " ++ client.name ++ " joined")
                ]
            )

        Joined _ (Err err) ->
            ( model, log model.stderr ("ws-chat: " ++ Socket.errorToString err) )

        Said name message ->
            case message of
                WebSocket.Text text ->
                    ( model, broadcast model.clients (name ++ ": " ++ text) )

                WebSocket.Binary _ ->
                    -- Binary messages are not part of this chat.
                    ( model, Cmd.none )

        Left id _ ->
            case Dict.get id model.clients of
                Just client ->
                    let
                        clients =
                            Dict.remove id model.clients
                    in
                    ( { model | clients = clients }, broadcast clients ("* " ++ client.name ++ " left") )

                Nothing ->
                    ( model, Cmd.none )

        Done ->
            ( model, Cmd.none )


broadcast : Dict Int Client -> String -> Cmd Msg
broadcast clients text =
    Dict.values clients |> List.map (\client -> send client.ws text) |> Cmd.batch


{-| Send a text message; a connection that is closing simply misses it.
-}
send : WebSocket.WebSocket WebSocket.Whole -> String -> Cmd Msg
send ws text =
    Stream.write (WebSocket.Text text) (WebSocket.writable ws)
        |> Task.attempt (\_ -> Done)


log : Stream.Writable Bytes -> String -> Cmd Msg
log stream line =
    Stream.Log.line stream line |> Task.perform (\_ -> Done)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        ((case model.server of
            Just server ->
                Server.onRequest server Received

            Nothing ->
                Sub.none
         )
            :: (Dict.toList model.clients
                    |> List.concatMap
                        (\( id, client ) ->
                            [ WebSocket.onMessage client.ws (Said client.name)
                            , WebSocket.onClose client.ws (Left id)
                            ]
                        )
               )
        )


page : String
page =
    """<!doctype html>
<meta charset="utf-8">
<title>ws-chat</title>
<pre id="log"></pre>
<form id="form"><input id="text" autofocus autocomplete="off" size="60"> <button>Send</button></form>
<script>
const log = document.getElementById('log');
const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/chat');
ws.onmessage = (e) => { log.textContent += e.data + '\\n'; };
ws.onclose = () => { log.textContent += '* disconnected\\n'; };
document.getElementById('form').onsubmit = (e) => {
  e.preventDefault();
  const input = document.getElementById('text');
  if (input.value) { ws.send(input.value); input.value = ''; }
};
</script>
"""
