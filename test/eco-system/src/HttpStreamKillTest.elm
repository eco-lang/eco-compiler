module HttpStreamKillTest exposing (main)

{-| Stopping transfers (plans/eco-system-library.md Phase 8 step 8.3, E.6):

  - `Process.kill` on a spawned `task` still waiting for the headers (`/slow`)
    aborts the transfer through the binding's kill handle (T7): the task never
    completes, and nothing waits for the 3 s response.
  - `Process.kill` mid-upload aborts the transfer, and the upload's source
    stream is cancelled: a later write to it fails with `Cancelled`.
  - Mid-download, `Stream.cancelReadable` on the body stream aborts the
    transfer; the stream then reads `Closed`.

The program exits promptly: no stalled transfer keeps it alive.

-}

-- CHECK: killed while waiting for headers
-- CHECK: first write: ok
-- CHECK: killed mid-upload
-- CHECK: write after kill: err Cancelled: the HTTP request was aborted
-- CHECK: first chunk read
-- CHECK: read after cancel: err Closed
-- CHECK: prompt: True
-- CHECK-NOT: slow completed
-- CHECK-NOT: upload completed
-- EXIT: 0

import Bytes exposing (Bytes)
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Process
import Stream
import Stream.Log
import System
import Task exposing (Task)


body : Http.Response (Stream.Readable Bytes) -> Result String (Stream.Readable Bytes)
body r =
    case r of
        Http.GoodStatus_ _ b ->
            Ok b

        _ ->
            Err "unexpected response"


describe : Task Stream.Error a -> Task x String
describe t =
    t |> Task.map (\_ -> "ok") |> Task.onError (\e -> Task.succeed ("err " ++ Stream.errorToString e))


killBeforeHeaders : System.Environment -> Task String String
killBeforeHeaders env =
    Process.spawn
        (Http.Stream.task
            { method = "GET", headers = [], url = H.url "/slow?ms=3000", body = Http.Stream.emptyBody, resolver = Http.Stream.streamResolver body, timeout = Nothing }
            |> Task.andThen (\_ -> Stream.Log.line env.stdout "slow completed")
            |> Task.onError (\_ -> Stream.Log.line env.stdout "slow completed with an error")
        )
        |> Task.andThen (\pid -> Process.sleep 100 |> Task.andThen (\_ -> Process.kill pid))
        |> Task.map (\_ -> "killed while waiting for headers")


killMidUpload : System.Environment -> Task String (List String)
killMidUpload env =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn
                    (Http.Stream.task
                        { method = "POST", headers = [], url = H.url "/anything", body = Http.Stream.streamBody "text/plain" (Stream.readable t), resolver = Http.Stream.streamResolver body, timeout = Nothing }
                        |> Task.andThen (\_ -> Stream.Log.line env.stdout "upload completed")
                        |> Task.onError (\_ -> Stream.Log.line env.stdout "upload completed with an error")
                    )
                    |> Task.andThen
                        (\pid ->
                            describe (Stream.write (H.bytesOf "part one") (Stream.writable t))
                                |> Task.andThen
                                    (\first ->
                                        Process.sleep 200
                                            |> Task.andThen (\_ -> Process.kill pid)
                                            |> Task.andThen (\_ -> Process.sleep 200)
                                            |> Task.andThen (\_ -> describe (Stream.write (H.bytesOf "x") (Stream.writable t)))
                                            |> Task.andThen (\_ -> Process.sleep 200)
                                            |> Task.andThen (\_ -> describe (Stream.write (H.bytesOf "y") (Stream.writable t)))
                                            |> Task.map
                                                (\after ->
                                                    [ "first write: " ++ first
                                                    , "killed mid-upload"
                                                    , "write after kill: " ++ after
                                                    ]
                                                )
                                    )
                        )
            )


cancelMidDownload : Task String (List String)
cancelMidDownload =
    Http.Stream.task
        { method = "GET", headers = [], url = H.url "/drip?bytes=8192&ms=3000", body = Http.Stream.emptyBody, resolver = Http.Stream.streamResolver body, timeout = Nothing }
        |> Task.andThen
            (\stream ->
                H.streamErr (Stream.read stream)
                    |> Task.andThen (\_ -> H.streamErr (Stream.cancelReadable "done" stream))
                    |> Task.andThen (\_ -> describe (Stream.read stream))
                    |> Task.map (\after -> [ "first chunk read", "read after cancel: " ++ after ])
            )


main : System.SimpleProgram ()
main =
    H.program
        (\env ->
            H.now
                |> Task.andThen
                    (\t0 ->
                        killBeforeHeaders env
                            |> Task.andThen
                                (\a ->
                                    killMidUpload env
                                        |> Task.andThen
                                            (\b ->
                                                cancelMidDownload
                                                    |> Task.andThen
                                                        (\c ->
                                                            H.elapsedSince t0
                                                                |> Task.map
                                                                    (\dt ->
                                                                        a :: b ++ c ++ [ "prompt: " ++ (if dt < 2500 then "True" else "False (" ++ String.fromInt dt ++ " ms)") ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
