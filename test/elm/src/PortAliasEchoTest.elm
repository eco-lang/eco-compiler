port module PortAliasEchoTest exposing (main)

{-| An outgoing port whose type is written through a type alias,
`port echoOut : Out msg` with `type alias Out msg = Payload -> Cmd msg`.

The monomorphizer's `connectEncoderType` (Compiler.Monomorphize.Solver.Translate)
unifies an outgoing port's encoder with `payload -> r` only when the port's type
is a function as written; through an alias it is a `TAlias`, so the encoder is
left unconnected (plans/dead-code-report.md, b5, Translate.elm:1147). This test
pins that such a port still encodes its record payload correctly: the harness
bounces every `echoOut` payload back into `echoIn` (see PortEchoTest).

-}

-- SKIP-AOT: needs the JIT harness echoOut -> echoIn port bounce (a standalone executable has no port host)
-- CHECK: PortAliasEchoTest got: { n = 42, s = "hi" }
-- CHECK: PortAliasEchoTest done: "ok"

import Platform


type alias Payload =
    { n : Int, s : String }


type alias Out msg =
    Payload -> Cmd msg


port echoOut : Out msg


port echoIn : (Payload -> msg) -> Sub msg


type Msg
    = Got Payload


type alias Model =
    { received : Bool }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { received = False }, echoOut { n = 42, s = "hi" } )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got payload ->
            let
                _ =
                    Debug.log "PortAliasEchoTest got" payload

                _ =
                    Debug.log "PortAliasEchoTest done" "ok"
            in
            ( { model | received = True }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.received then
        Sub.none

    else
        echoIn Got


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
