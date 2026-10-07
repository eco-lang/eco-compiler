module FileWatchRecursiveTest exposing (main)

{-| `System.File.watchRecursive` (plans/eco-system-library.md Phase 4 step
4.6, C.2, §3.8): a sub-directory created after the watch started is watched
too (inotify: a watch per sub-directory, added on IN_CREATE), and events
carry paths relative to the watched directory. The subscription goes through
`Sub.map`, which exercises the C++ manager's `subMap` composition. As in
FileWatchTest, a polling watcher gets one more append if only the creation of
the file was seen.
-}

-- CHECK: watching
-- CHECK: event: moved sub
-- CHECK: event: changed sub/inner.txt
-- CHECK: watch: done
-- EXIT: 0

import FileTestHelp exposing (bytes, child)
import Process
import Stream.Log
import System
import System.File as File
import System.File.Path as Path exposing (Path)
import Task


type Msg
    = GotDir (Result File.Error Path)
    | Event String
    | Logged
    | Finished
    | AppendNow


type alias Model =
    { env : System.Environment
    , dir : Maybe Path
    , done : Bool
    }


showEvent : File.WatchEvent -> String
showEvent ev =
    let
        p =
            Maybe.map Path.toPosixString >> Maybe.withDefault "-"
    in
    case ev of
        File.Changed path ->
            "changed " ++ p path

        File.Moved path ->
            "moved " ++ p path


log : Model -> String -> Cmd Msg
log model line =
    Task.perform (\_ -> Logged) (Stream.Log.line model.env.stdout line)


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, dir = Nothing, done = False }
                , Task.attempt GotDir (File.makeTempDirectory "eco-watchr-test-")
                )
        , update =
            \msg model ->
                case msg of
                    GotDir (Ok dir) ->
                        ( { model | dir = Just dir }
                        , Cmd.batch
                            [ log model "watching"
                            , Process.sleep 100
                                |> Task.andThen (\_ -> File.makeDirectory { recursive = False } (child dir "sub"))
                                |> Task.andThen (\_ -> Process.sleep 200)
                                |> Task.andThen (\_ -> File.writeFile (bytes "inner") (child dir "sub/inner.txt"))
                                |> Task.attempt (\_ -> Logged)
                            ]
                        )

                    GotDir (Err e) ->
                        ( { model | done = True }, log model ("error: " ++ File.errorCode e) )

                    Event line ->
                        if model.done then
                            ( model, Cmd.none )

                        else
                            case ( line == "changed sub/inner.txt", model.dir ) of
                                ( True, Just dir ) ->
                                    ( { model | done = True }
                                    , Cmd.batch
                                        [ log model ("event: " ++ line)
                                        , File.remove { recursive = True } dir |> Task.attempt (\_ -> Finished)
                                        ]
                                    )

                                ( False, Just _ ) ->
                                    ( model
                                    , Cmd.batch
                                        [ log model ("event: " ++ line)
                                        , if line == "moved sub/inner.txt" then
                                            Task.perform (\_ -> AppendNow) (Process.sleep 1200)

                                          else
                                            Cmd.none
                                        ]
                                    )

                                _ ->
                                    ( model, log model ("event: " ++ line) )

                    AppendNow ->
                        case ( model.dir, model.done ) of
                            ( Just dir, False ) ->
                                ( model
                                , File.appendToFile (bytes " again") (child dir "sub/inner.txt")
                                    |> Task.attempt (\_ -> Logged)
                                )

                            _ ->
                                ( model, Cmd.none )

                    Logged ->
                        ( model, Cmd.none )

                    Finished ->
                        ( model, log model "watch: done" )
        , subscriptions =
            \model ->
                case ( model.dir, model.done ) of
                    ( Just dir, False ) ->
                        Sub.map Event (File.watchRecursive showEvent dir)

                    _ ->
                        Sub.none
        }
