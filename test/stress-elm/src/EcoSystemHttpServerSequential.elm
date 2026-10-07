module EcoSystemHttpServerSequential exposing (main)

{-| Stress variant of the eco-system HTTP server tests
(plans/eco-system-library.md Phase 7 step 7.4, §3.3.3 gate 3).

The program starts a server on the harness's `ECO_TEST_PORT`, subscribes to
it, and then makes `max 200 (20 * numLoops)` sequential elm/http requests to
itself (fewer when `--timeout` ends the loop first). Every request carries a different path,
header and body; the server answers with a body derived from all three and a
status that depends on the index, and the client checks every answer. This
exercises the connection threads, llhttp, request delivery (the tagger
argument with its unboxed response key), the respond completion and Bytes
bodies under GC. A listening server keeps the program alive, so it ends with
`System.exit` (the `-- EXIT:` directive runs it in process-output mode).
-}

-- CHECK: EcoSystemHttpServerSequential: True
-- EXIT: 0

import Dict
import Http
import Http.Server as Server
import Http.Server.Response as Response
import StressHarness exposing (StressFlags)
import System
import Task exposing (Task)


type Msg
    = Started (Result Server.ServerError ( Server.Server, Int ))
    | GotRequest Server.Request Response.Response
    | Done Bool


type alias Model =
    { flags : StressFlags
    , server : Maybe Server.Server
    }


statusFor : Int -> Int
statusFor i =
    if modBy 7 i == 3 then
        404

    else
        200


expected : Int -> String
expected i =
    "p" ++ String.fromInt i ++ "|h" ++ String.fromInt (i * 3) ++ "|" ++ String.repeat (modBy 50 i) "b"


one : String -> Int -> Task Never Bool
one base i =
    Http.task
        { method = "POST"
        , headers = [ Http.header "X-Index" (String.fromInt (i * 3)) ]
        , url = base ++ "/p" ++ String.fromInt i
        , body = Http.stringBody "text/plain" (String.repeat (modBy 50 i) "b")
        , resolver =
            Http.stringResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ meta body ->
                            Ok (meta.statusCode == statusFor i && body == expected i)

                        Http.BadStatus_ meta body ->
                            Ok (meta.statusCode == statusFor i && body == expected i)

                        _ ->
                            Ok False
                )
        , timeout = Just 30000
        }
        |> Task.onError (\_ -> Task.succeed False)


run : Int -> StressFlags -> Task Never Bool
run port_ flags =
    let
        base =
            "http://127.0.0.1:" ++ String.fromInt port_

        count =
            max 200 (max 1 flags.numLoops * 20)
    in
    StressHarness.loopWhile flags count (one base)


main : Program StressFlags Model Msg
main =
    Platform.worker
        { init =
            \flags ->
                ( { flags = flags, server = Nothing }
                , System.getEnvironmentVariables
                    |> Task.map (Dict.get "ECO_TEST_PORT" >> Maybe.andThen String.toInt >> Maybe.withDefault 0)
                    |> Task.andThen
                        (\p ->
                            Server.createServer { host = "127.0.0.1", port_ = p }
                                |> Task.map (\s -> ( s, p ))
                        )
                    |> Task.attempt Started
                )
        , update = update
        , subscriptions =
            \model ->
                case model.server of
                    Just s ->
                        Server.onRequest s GotRequest

                    Nothing ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started (Ok ( server, p )) ->
            ( { model | server = Just server }, Task.perform Done (run p model.flags) )

        Started (Err _) ->
            ( model, Task.perform Done (Task.succeed False) )

        GotRequest request response ->
            let
                index =
                    String.dropLeft 2 request.url.path |> String.toInt |> Maybe.withDefault -1

                reply =
                    String.dropLeft 1 request.url.path
                        ++ "|h"
                        ++ (Dict.get "X-Index" request.headers |> Maybe.withDefault "?")
                        ++ "|"
                        ++ (Server.bodyAsString request |> Maybe.withDefault "<invalid>")
            in
            ( model
            , response
                |> Response.setStatus (statusFor index)
                |> Response.setBody reply
                |> Response.send
            )

        Done ok ->
            let
                _ =
                    Debug.log "EcoSystemHttpServerSequential" ok
            in
            ( model, System.exit )
