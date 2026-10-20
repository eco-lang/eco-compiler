module TaskSucceedAsArgTest exposing (main)

{-| `Task.succeed` passed as a value to a polymorphic function, with the type variable it fills
instantiated to `Int`, must compile and deliver its value. The compiler used to abort in LLVM
with "Calling a function with a bad signature!" on this module.
-}

-- CHECK: got: 7

import Platform
import Task


apply : (a -> b) -> a -> b
apply f a =
    f a


type Msg
    = Got Int


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Got (apply Task.succeed 7) )
        , update =
            \(Got n) m ->
                let
                    _ =
                        Debug.log "got" n
                in
                ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
