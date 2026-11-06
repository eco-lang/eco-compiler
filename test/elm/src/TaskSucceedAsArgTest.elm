module TaskSucceedAsArgTest exposing (main)

{-| `Task.succeed`, passed as a function value to a polymorphic `apply : (a -> b) -> a -> b` with `a` instantiated to `Int`, produces a task that `Task.perform` delivers to `update` with the value 7.
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
