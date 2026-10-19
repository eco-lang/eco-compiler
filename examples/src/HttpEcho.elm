module HttpEcho exposing (main)

{-| An HTTP echo server: answers every request with its method, URL and body.

    eco make src/HttpEcho.elm --output=http-echo && ./http-echo 8080
    curl -d hello http://127.0.0.1:8080/some/path

The port is the first argument (default 8080). The server runs until the process is stopped.

-}

import Bytes exposing (Bytes)
import Http.Server as Server exposing (Request, Response, Server)
import Stream
import System
import Task
import Url


type alias Model =
    { stdout : Stream.Writable Bytes
    , stderr : Stream.Writable Bytes
    , server : Maybe Server
    }


type Msg
    = Started (Result Server.Error Server)
    | Received Request Response
    | Logged
    | Exit Int


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
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
    , Task.attempt Started (Server.listenOnHost "127.0.0.1" port_)
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started (Ok server) ->
            ( { model | server = Just server }
            , Stream.logLine ("listening on http://127.0.0.1:" ++ String.fromInt (Server.endpoint server).port_) model.stdout
                |> Task.perform (\_ -> Logged)
            )

        Started (Err err) ->
            ( model
            , Stream.logLine ("http-echo: " ++ Server.errorToString err) model.stderr
                |> Task.perform (\_ -> Exit 1)
            )

        Received request response ->
            ( model
            , response
                |> Server.setStatus 200
                |> Server.setHeader "Content-Type" "text/plain; charset=utf-8"
                |> Server.setBodyAsString (echo request)
                |> Server.send
            )

        Logged ->
            ( model, Cmd.none )

        Exit code ->
            ( model, System.exitWithCode code )


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
