port module CoreIssue1043PortErrorObjectObjectTest exposing (main)

{-| Sending a value of the wrong type into a port reports the problem as `[object Object]`.

<https://github.com/elm/core/issues/1043>

The host sends the number 1337 back through `echoIn`, which expects a String. Elm 0.19.1 throws
"Trying to send an unexpected type of value through port `echoIn`: [object Object]", stringifying
the `Json.Decode.Error` instead of describing it. The crash is right; its message must say what
was wrong (the value 1337, expecting a STRING).

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
