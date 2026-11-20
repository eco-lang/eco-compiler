module EraseWrapperModelTest exposing (main)

{-| A `Platform.worker` whose model is a wrapper of a `Float`,
`type Model = Model Float`, under `EraseWrappers`
(plans/constructor-representation-levels.md E1a, E1b). `Platform.worker`'s
Elm wrapper views the model through a type variable, so `EraseWrappers` leaves
`Model` a heap value (MONO_031: a wrapper viewed through a type variable is
not erased, since an erased view would read it untyped). The program checks
that the model still crosses the platform boundary and prints as `Model ...`.
`init` starts at 1.5 and asks for two `Add` messages through `Task.perform`
(which the platform delivers last first); `update` adds each to the model and
logs it.

-}

-- CHECK: model: Model 1.5
-- CHECK: model: Model 3.5
-- CHECK: model: Model 6.5

import Platform
import Task


type Model
    = Model Float


type Msg
    = Add Float


init : () -> ( Model, Cmd Msg )
init _ =
    let
        m =
            Model 1.5

        _ =
            Debug.log "model" m
    in
    ( m, Cmd.batch [ Task.perform Add (Task.succeed 3), Task.perform Add (Task.succeed 2) ] )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Add d) (Model x) =
    let
        m =
            Model (x + d)

        _ =
            Debug.log "model" m
    in
    ( m, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
