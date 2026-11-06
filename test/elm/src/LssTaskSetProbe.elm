module LssTaskSetProbe exposing (main)

{-| An LSS probe: the dispatch site applies an `Int -> Int` carried in a message. It also pins the
order a `Cmd.batch` of two `Task.attempt`s delivers its results: last first, [40,42], as Elm 0.19.1
does (PORT_005). Eco delivered them first first, [42,40], until 2026-11-06, when the test moved here
from test/eco-divergence.
-}

-- CHECK: r: [40,42]

import Platform
import Task exposing (Task)


type Msg
    = Got (Result String (Int -> Int))
    | Done


incr : Int -> Int
incr =
    (+) 1


decr : Int -> Int
decr x =
    x - 1


tasks : List (Task String (Int -> Int))
tasks =
    [ Task.succeed incr, Task.succeed decr ]


init : () -> ( List Int, Cmd Msg )
init _ =
    ( [], tasks |> List.map (Task.attempt Got) |> Cmd.batch )


update : Msg -> List Int -> ( List Int, Cmd Msg )
update msg model =
    case msg of
        Got (Ok f) ->
            -- THE dispatch site: applies the Int -> Int carried in the Msg.
            let
                acc =
                    model ++ [ f 41 ]
            in
            if List.length acc == 2 then
                ( acc, Task.perform (\_ -> Done) (Task.succeed ()) )

            else
                ( acc, Cmd.none )

        Got (Err _) ->
            ( model, Cmd.none )

        Done ->
            let
                _ =
                    Debug.log "r" model
            in
            ( model, Cmd.none )


main : Program () (List Int) Msg
main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }
