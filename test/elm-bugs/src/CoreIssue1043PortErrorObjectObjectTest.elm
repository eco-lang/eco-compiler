port module CoreIssue1043PortErrorObjectObjectTest exposing (main)

{-| A value of the wrong type arriving on an incoming port crashes the program with a message that describes the value.

<https://github.com/elm/core/issues/1043>

The program sends 1337 out on `echoOut`, and the test's host echoes it back on `echoIn`, which
expects a `String`. The crash is correct; its message must mention 1337. Elm 0.19.1 prints
"Trying to send an unexpected type of value through port `echoIn`: [object Object]" instead.

-}

-- EXIT: 1
-- CHECK: Trying to send an unexpected type of value through port `echoIn`
-- CHECK: 1337
-- CHECK-NOT: [object Object]

import Process
import Task


port echoOut : Int -> Cmd msg


port echoIn : (String -> msg) -> Sub msg


type Msg
    = Send
    | Got String


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Send ->
            ( model, echoOut 1337 )

        Got _ ->
            ( model, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform (always Send) (Process.sleep 10) )
        , update = update
        , subscriptions = \_ -> echoIn Got
        }
