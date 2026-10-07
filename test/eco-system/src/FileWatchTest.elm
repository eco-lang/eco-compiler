module FileWatchTest exposing (main)

{-| `System.File.watch` (plans/eco-system-library.md Phase 4 step 4.6, C.2):
watch a fresh directory, create a file in it and receive `Changed` for it
(creation itself is a `Moved`, as with node's fs.watch on Linux). A polling
watcher (macOS, or ECO_SYSTEM_WATCH_POLL=1) may see only the creation, so if
no `Changed` has arrived 1.2 s after the `Moved`, the test appends to the file
once more. Once the
event has arrived the subscription is dropped; the active watch held the
program alive (pendingAsync) and releasing it lets the program exit.
-}

-- CHECK: watching
-- CHECK: event: moved hello.txt
-- CHECK: event: changed hello.txt
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
    | Event File.WatchEvent
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
                , Task.attempt GotDir (File.makeTempDirectory "eco-watch-test-")
                )
        , update =
            \msg model ->
                case msg of
                    GotDir (Ok dir) ->
                        ( { model | dir = Just dir }
                        , Cmd.batch
                            [ log model "watching"

                            -- Give the subscription a moment to be installed before writing.
                            , Process.sleep 100
                                |> Task.andThen (\_ -> File.writeFile (bytes "hello") (child dir "hello.txt"))
                                |> Task.attempt (\_ -> Logged)
                            ]
                        )

                    GotDir (Err e) ->
                        ( { model | done = True }, log model ("error: " ++ File.errorCode e) )

                    Event ev ->
                        if model.done then
                            ( model, Cmd.none )

                        else
                            case ( ev, model.dir ) of
                                ( File.Changed (Just p), Just dir ) ->
                                    if Path.toPosixString p == "hello.txt" then
                                        ( { model | done = True }
                                        , Cmd.batch
                                            [ log model ("event: " ++ showEvent ev)
                                            , File.remove { recursive = True } dir
                                                |> Task.attempt (\_ -> Finished)
                                            ]
                                        )

                                    else
                                        ( model, log model ("event: " ++ showEvent ev) )

                                ( File.Moved (Just p), Just _ ) ->
                                    ( model
                                    , Cmd.batch
                                        [ log model ("event: " ++ showEvent ev)
                                        , if Path.toPosixString p == "hello.txt" then
                                            Task.perform (\_ -> AppendNow) (Process.sleep 1200)

                                          else
                                            Cmd.none
                                        ]
                                    )

                                _ ->
                                    ( model, log model ("event: " ++ showEvent ev) )

                    AppendNow ->
                        case ( model.dir, model.done ) of
                            ( Just dir, False ) ->
                                ( model
                                , File.appendToFile (bytes " again") (child dir "hello.txt")
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
                        File.watch Event dir

                    _ ->
                        Sub.none
        }
