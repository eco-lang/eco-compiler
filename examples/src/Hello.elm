module Hello exposing (main)

import Eco.Console
import Platform
import Task


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Task.attempt (always ()) (Eco.Console.write Eco.Console.stdout "Hello World!\n")
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
