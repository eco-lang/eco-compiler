module EcoSystemHttpServerHtml exposing (main)

{-| Stress variant of the setBodyAsHtml test (plans/elm-html-native-kernel.md P6,
plans/eco-system-library.md §3.3.3 gate 3).

The program starts a server on the harness's `ECO_TEST_PORT` and makes
`max 50 (5 * numLoops)` sequential elm/http requests to itself. Each answer is a
5,000-element page built with elm/html and sent with
`Response.setBodyAsHtml`, so the respondHtml export's tuple allocations and the
copy-out of a large tree (HtmlWriter inside the no-allocation scope) run under
GC pressure. The client compares every body with `<!DOCTYPE html>` followed by
`Http.Dom.toString` of the same page.
-}

-- CHECK: EcoSystemHttpServerHtml: True
-- EXIT: 0

import Dict
import Html exposing (Html, node, span, text)
import Html.Attributes exposing (class, id)
import Http
import Http.Dom
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


page : Int -> Html msg
page i =
    node "html"
        []
        [ node "body"
            [ class ("p" ++ String.fromInt i) ]
            (List.map (\k -> span [ id (String.fromInt (k + i)) ] [ text "x<" ]) (List.range 1 5000))
        ]


expected : Int -> String
expected i =
    "<!DOCTYPE html>" ++ Http.Dom.toString (page i)


one : String -> Int -> Task Never Bool
one base i =
    Http.task
        { method = "GET"
        , headers = []
        , url = base ++ "/p" ++ String.fromInt i
        , body = Http.emptyBody
        , resolver =
            Http.stringResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ meta body ->
                            Ok
                                (body == expected i
                                    && Dict.get "content-type" meta.headers == Just "text/html; charset=utf-8"
                                )

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
            max 50 (max 1 flags.numLoops * 5)
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
            in
            ( model
            , response
                |> Response.setBodyAsHtml (page index)
                |> Response.send
            )

        Done ok ->
            let
                _ =
                    Debug.log "EcoSystemHttpServerHtml" ok
            in
            ( model, System.exit )
