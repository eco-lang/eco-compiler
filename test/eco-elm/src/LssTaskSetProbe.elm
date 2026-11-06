module LssTaskSetProbe exposing (main)

{-| A function of type `Int -> Int` carried in a message is applied in `update`, and `Cmd.batch` of two `Task.attempt` commands delivers their results last first.

`init` batches `Task.attempt Got` over `[ Task.succeed incr, Task.succeed decr ]`. Each `Got`
applies its function to 41 and appends the result, and after two results the model is logged.
The expected `[40,42]` means `decr`'s result arrived before `incr`'s, which is the order
Elm 0.19.1 produces.

## eco

A lambda-set specialization probe: the `f 41` call in `update` applies a function carried
in a message, a dispatch site whose set comes through the effect manager. It also pins the
delivery order of a batch of `Task.attempt` commands, which follows Elm 0.19.1 (PORT_005 in
design_docs/invariants.csv covers eco's effect dispatch). Eco delivered them first first,
`[42,40]`, until 2026-11-06, when the test moved here from test/eco-divergence.

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
