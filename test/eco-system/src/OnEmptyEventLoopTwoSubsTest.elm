module OnEmptyEventLoopTwoSubsTest exposing (main)

{-| Two `onEmptyEventLoop` subscriptions (plans/program-liveness-rule.md §7.2, §11.1):
both receive their message on the one firing, in subscription order, and there is
no second firing. Each delivery is numbered so that a second firing would show as
`got A 2`.
-}

-- CHECK: got A 1
-- CHECK-NEXT: got B 1
-- CHECK-NOT: got A 2
-- CHECK-NOT: got B 2
-- EXIT: 0

import System


type Msg
    = A
    | B


main : Platform.Program System.Environment ( Int, Int ) Msg
main =
    Platform.worker
        { init = \_ -> ( ( 0, 0 ), Cmd.none )
        , update =
            \msg ( a, b ) ->
                case msg of
                    A ->
                        let
                            _ =
                                Debug.log ("got A " ++ String.fromInt (a + 1)) ()
                        in
                        ( ( a + 1, b ), Cmd.none )

                    B ->
                        let
                            _ =
                                Debug.log ("got B " ++ String.fromInt (b + 1)) ()
                        in
                        ( ( a, b + 1 ), Cmd.none )
        , subscriptions = \_ -> Sub.batch [ System.onEmptyEventLoop A, System.onEmptyEventLoop B ]
        }
