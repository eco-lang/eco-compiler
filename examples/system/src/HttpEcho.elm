module HttpEcho exposing (main)

{-| An HTTP echo server: answers every request with its method, URL and body.

    eco make src/HttpEcho.elm --output=http-echo && ./http-echo 8080
    curl -d hello http://127.0.0.1:8080/some/path

The port is the first argument (default 8080). The server runs until the process is stopped.

-}

import Bytes exposing (Bytes)
import Http.Server as Server exposing (Request, Server)
import Http.Server.Response as Response exposing (Response)
import Stream
import Stream.Log
import System
import Task
import Url


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , server : Maybe Server
    }


type Msg
    = Started Int (Result Server.ServerError Server)
    | Received Request Response


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
        -- args includes the program name first (the full C argv).
        port_ =
            env.args
                |> List.drop 1
                |> List.head
                |> Maybe.andThen String.toInt
                |> Maybe.withDefault 8080
    in
    ( { stdout = env.stdout, stderr = env.stderr, server = Nothing }
    , Task.attempt (Started port_) (Server.createServer { host = "127.0.0.1", port_ = port_ })
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started port_ (Ok server) ->
            ( { model | server = Just server }
            , System.endSimpleProgram
                (Stream.Log.line model.stdout ("listening on http://127.0.0.1:" ++ String.fromInt port_))
            )

        Started _ (Err (Server.ServerError err)) ->
            ( model
            , Cmd.batch
                [ System.endSimpleProgram (Stream.Log.line model.stderr ("http-echo: " ++ err.message))
                , System.exitWithCode 1
                ]
            )

        Received request response ->
            ( model
            , response
                |> Response.setStatus 200
                |> Response.setHeader "Content-Type" "text/plain; charset=utf-8"
                |> Response.setBodyAsString (echo request)
                |> Response.send
            )


echo : Request -> String
echo request =
    Server.methodToString request.method
        ++ " "
        ++ Url.toString request.url
        ++ "\n"
        ++ Maybe.withDefault "" (Server.bodyAsString request)
        ++ "\n"


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.server of
        Just server ->
            Server.onRequest server Received

        Nothing ->
            Sub.none
