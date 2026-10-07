module HarnessTestPortTest exposing (main)

{-| Harness self-test (plans/eco-system-library.md Phase 7 step 7.4): the
runner hands every test child a free TCP port as `ECO_TEST_PORT`
(test/TestPort.hpp). It is a number in 1..65535, and a server can listen
on it.
-}

-- CHECK: ECO_TEST_PORT set: True
-- CHECK: ECO_TEST_PORT in range: True
-- CHECK: listen: ok
-- EXIT: 0

import Dict
import Http.Server as Server
import HttpServerTestHelp as Help
import Stream.Log
import System
import Task


main : System.Program () ()
main =
    System.defineProgram
        { init =
            \env ->
                ( ()
                , System.getEnvironmentVariables
                    |> Task.andThen
                        (\vars ->
                            let
                                port_ =
                                    Dict.get "ECO_TEST_PORT" vars |> Maybe.andThen String.toInt
                            in
                            Server.createServer { host = "127.0.0.1", port_ = Maybe.withDefault 0 port_ }
                                |> Task.map (\_ -> "ok")
                                |> Task.onError (\(Server.ServerError e) -> Task.succeed e.code)
                                |> Task.andThen
                                    (\listen ->
                                        Stream.Log.line env.stdout
                                            (String.join "\n"
                                                [ "ECO_TEST_PORT set: " ++ Help.boolString (port_ /= Nothing)
                                                , "ECO_TEST_PORT in range: "
                                                    ++ Help.boolString
                                                        (Maybe.map (\p -> p >= 1 && p <= 65535) port_ |> Maybe.withDefault False)
                                                , "listen: " ++ listen
                                                ]
                                            )
                                    )
                        )
                    |> Task.perform (\_ -> ())
                )
        , update = \_ model -> ( model, System.exit )
        , subscriptions = \_ -> Sub.none
        }
