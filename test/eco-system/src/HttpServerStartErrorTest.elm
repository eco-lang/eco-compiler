module HttpServerStartErrorTest exposing (main)

{-| A server that cannot start fails with `ServerError` (plans/eco-system-library.md
Phase 7 steps 7.2 and 7.4): the first server takes the harness's port, a
second one on the same port fails with `EADDRINUSE`, and an unresolvable host
fails with `ENOTFOUND`. The program exits explicitly, because the listening
server keeps it alive.
-}

-- CHECK: first: started
-- CHECK: second: EADDRINUSE listen EADDRINUSE:
-- CHECK: third: ENOTFOUND
-- EXIT: 0

import Http.Server as Server
import HttpServerTestHelp as Help
import Stream.Log
import System
import Task exposing (Task)


attempt : String -> Int -> Task Never String
attempt host port_ =
    Server.createServer { host = host, port_ = port_ }
        |> Task.map (\_ -> "started")
        |> Task.onError (\(Server.ServerError e) -> Task.succeed (e.code ++ " " ++ e.message))


main : System.Program () ()
main =
    System.defineProgram
        { init =
            \env ->
                ( ()
                , Help.testPort
                    |> Task.andThen
                        (\p ->
                            Task.map3
                                (\a b c -> [ "first: " ++ a, "second: " ++ b, "third: " ++ c ])
                                (attempt "127.0.0.1" p)
                                (attempt "127.0.0.1" p)
                                (attempt "no-such-host.invalid" p)
                        )
                    |> Task.andThen (\lines -> Stream.Log.line env.stdout (String.join "\n" lines))
                    |> Task.perform (\_ -> ())
                )
        , update = \_ model -> ( model, System.exit )
        , subscriptions = \_ -> Sub.none
        }
