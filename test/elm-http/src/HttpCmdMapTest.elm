module HttpCmdMapTest exposing (main)

{-| `Cmd.map` over an Http command (plans/http-cmdmap-native-crash.md). elm/http's effect
manager maps a request through `Elm.Kernel.Http.mapExpect`, so the response must come back
through every tagger, in order: a constructor, a lambda, two nested maps, and `identity`.
Each case carries its own label in the message, and the label must survive the mapping.
-}

-- CHECK: ctor: "ok \"ctor\""
-- CHECK: lambda: "ok \"lambda\""
-- CHECK: nested: "ok \"nested\""
-- CHECK: identity: "ok \"identity\""
-- CHECK: done: 4

import Http
import Platform
import Task
import TestServerConfig


type Msg
    = Got String (Result Http.Error String)


type Outer
    = GotServer TestServerConfig.Server
    | Inner Msg
    | Lambda Msg
    | Wrapped Middle
    | Plain Msg


type Middle
    = Middle Msg


main : Program () Int Outer
main =
    Platform.worker
        { init = \_ -> ( 0, Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : TestServerConfig.Server -> String -> Cmd Msg
get server label =
    Http.get { url = server.baseUrl ++ "/anything", expect = Http.expectString (Got label) }


report : String -> Msg -> Int -> ( Int, Cmd Outer )
report case_ (Got label result) count =
    let
        outcome =
            case result of
                Ok body ->
                    if String.contains "\"method\":\"GET\"" body then
                        "ok"

                    else
                        "unexpected body"

                Err _ ->
                    "error"

        _ =
            Debug.log case_ (outcome ++ " \"" ++ label ++ "\"")

        n =
            count + 1

        _ =
            if n == 4 then
                Debug.log "done" n

            else
                n
    in
    ( n, Cmd.none )


update : Outer -> Int -> ( Int, Cmd Outer )
update msg count =
    case msg of
        GotServer server ->
            ( count
            , Cmd.batch
                [ Cmd.map Inner (get server "ctor")
                , Cmd.map (\m -> Lambda m) (get server "lambda")
                , Cmd.map Wrapped (Cmd.map Middle (get server "nested"))
                , Cmd.map Plain (Cmd.map identity (get server "identity"))
                ]
            )

        Inner m ->
            report "ctor" m count

        Lambda m ->
            report "lambda" m count

        Wrapped (Middle m) ->
            report "nested" m count

        Plain m ->
            report "identity" m count
