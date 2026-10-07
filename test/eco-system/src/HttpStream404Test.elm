module HttpStream404Test exposing (main)

{-| `expectStream` on `/status/404` (plans/eco-system-library.md Phase 8 step 8.3,
E.6): the result is `Err (BadStatus 404)`, the body is discarded by the
transfer thread, and the program exits promptly — nothing stalls on the
unread body.
-}

-- CHECK: BadStatus 404
-- CHECK: done
-- EXIT: 0

import Bytes exposing (Bytes)
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Stream.Log
import System
import Task


type Msg
    = GotStream (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ))
    | Logged


main : System.Program System.Environment Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( env
                , Http.Stream.request
                    { method = "GET"
                    , headers = []
                    , url = H.url "/status/404"
                    , body = Http.Stream.emptyBody
                    , expect = Http.Stream.expectStream GotStream
                    , timeout = Nothing
                    }
                )
        , update =
            \msg env ->
                case msg of
                    GotStream result ->
                        let
                            text =
                                case result of
                                    Ok ( meta, _ ) ->
                                        "unexpected Ok " ++ String.fromInt meta.statusCode

                                    Err e ->
                                        H.describeHttpError e
                        in
                        ( env
                        , Stream.Log.line env.stdout text
                            |> Task.andThen (\_ -> Stream.Log.line env.stdout "done")
                            |> Task.perform (\_ -> Logged)
                        )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
