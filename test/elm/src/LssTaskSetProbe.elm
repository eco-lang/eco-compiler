module LssTaskSetProbe exposing (main)

-- CHECK: r: [42, 40]

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
