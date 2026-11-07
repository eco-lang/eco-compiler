module FileWatchRenameDirTest exposing (main)

{-| WATCH-02 (plans/kernel-lib-bug-fixes.md): a sub-directory renamed inside a recursive
watch must report its later entries under its new name. The test creates `a`, waits for the
watcher to map that creation (inotify mode adds a watch on `a`), renames `a` to `b`, and writes
`b/x`. The correct event for the file is `moved b/x`.

It failed in inotify mode: the MOVED_TO of `b` called `addDir` on the same inode, which got the
same watch descriptor back, and `addDir` returned early because the watch already used it
(WatchService.cpp), so the descriptor kept its relative path `a` and the file was reported as
`moved a/x`. Fixed: the MOVED_FROM of `a` drops the watches of its tree first. Poll mode
re-snapshots paths and passes. A 3 s deadline ends a failing run.

-}

-- CHECK: watching
-- CHECK: event: [moved b]
-- CHECK: event: [moved b/x]
-- CHECK-NOT: a/x]
-- CHECK-NOT: deadline
-- CHECK: watch: done
-- EXIT: 0

import ErrorNames
import FileTestHelp exposing (bytes, child)
import FileSystem as File
import Path exposing (Path)
import Process
import Stream
import System
import Task exposing (Task)


type Msg
    = GotDirs (Result File.Error ( Path, Path ))
    | Event String
    | StepsDone (Result File.Error ())
    | Deadline
    | Logged
    | Finished
    | Exit


type alias Model =
    { env : System.Environment
    , dirs : Maybe ( Path, Path )
    , done : Bool
    }


{-| An event as one line; the brackets keep one path from matching as a prefix of another in the
CHECK lines.
-}
showEvent : File.WatchEvent -> String
showEvent ev =
    let
        p =
            Maybe.map Path.toPosixString >> Maybe.withDefault "-"
    in
    case ev of
        File.Changed path ->
            "[changed " ++ p path ++ "]"

        File.Moved path ->
            "[moved " ++ p path ++ "]"


log : Model -> String -> Cmd Msg
log model line =
    Task.perform (\_ -> Logged) (Stream.logLine line model.env.stdout)


{-| Create `a`, let a drain map it, rename it to `b`, then write `b/x`. -}
steps : Path -> Path -> Task File.Error ()
steps dir _ =
    Process.sleep 100
        |> Task.andThen (\_ -> File.makeDirectory { recursive = False } (child dir "a"))
        |> Task.andThen (\_ -> Process.sleep 300)
        |> Task.andThen (\_ -> File.move (child dir "b") (child dir "a"))
        |> Task.andThen (\_ -> Process.sleep 300)
        |> Task.andThen (\_ -> File.writeFile (bytes "x") (child dir "b/x"))
        |> Task.map (\_ -> ())


{-| The run ends at the first event about the file `x`. -}
isLast : String -> Bool
isLast line =
    String.endsWith "/x]" line


{-| Ends the run: logs `why`, drops the subscription and removes both directories. -}
finish : Model -> String -> ( Model, Cmd Msg )
finish model why =
    case model.dirs of
        Just ( root, other ) ->
            ( { model | done = True }
            , Cmd.batch
                [ log model why
                , File.remove { recursive = True } root
                    |> Task.andThen (\_ -> File.remove { recursive = True } other)
                    |> Task.attempt (\_ -> Finished)
                ]
            )

        Nothing ->
            ( { model | done = True }, log model why )


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, dirs = Nothing, done = False }
                , Task.map2 Tuple.pair
                    (File.makeTempDirectory "eco-watch-rendir-")
                    (File.makeTempDirectory "eco-watch-rendir-o-")
                    |> Task.attempt GotDirs
                )
        , update =
            \msg model ->
                case msg of
                    GotDirs (Ok ( root, other )) ->
                        ( { model | dirs = Just ( root, other ) }
                        , Cmd.batch
                            [ log model "watching"
                            , steps root other |> Task.attempt StepsDone
                            , Process.sleep 3000 |> Task.perform (\_ -> Deadline)
                            ]
                        )

                    GotDirs (Err e) ->
                        ( { model | done = True }, log model ("error: " ++ ErrorNames.fileError e) )

                    StepsDone (Err e) ->
                        if model.done then
                            ( model, Cmd.none )

                        else
                            finish model ("step error: " ++ ErrorNames.fileError e)

                    StepsDone (Ok ()) ->
                        ( model, Cmd.none )

                    Event line ->
                        if model.done then
                            ( model, Cmd.none )

                        else if isLast line then
                            finish model ("event: " ++ line)

                        else
                            ( model, log model ("event: " ++ line) )

                    Deadline ->
                        if model.done then
                            ( model, Cmd.none )

                        else
                            finish model "deadline"

                    Logged ->
                        ( model, Cmd.none )

                    Finished ->
                        -- Exit, so the pending Deadline sleep does not keep the program alive.
                        ( model, Task.perform (\_ -> Exit) (Stream.logLine "watch: done" model.env.stdout) )

                    Exit ->
                        ( model, System.exitWithCode 0 )
        , subscriptions =
            \model ->
                case ( model.dirs, model.done ) of
                    ( Just ( root, _ ), False ) ->
                        Sub.map Event (File.watchRecursive showEvent root)

                    _ ->
                        Sub.none
        }
