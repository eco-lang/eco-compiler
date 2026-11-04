module FileWatchMoveOutTest exposing (main)

{-| WATCH-03 (plans/kernel-lib-bug-fixes.md): a sub-directory moved out of a recursive watch
must stop being reported. The test creates `sub` in the watched directory, waits for the
watcher to map that creation (inotify mode adds a watch on `sub`), moves `sub` to `gone` in a
second temp directory outside the watch, writes `gone/x`, and 1.2 s later writes `marker` in the
watched directory. Correct: no event names `x`.

It failed in inotify mode: the moved directory's watch descriptor kept its use with relative
path `sub`, so the write outside the watch was reported as `moved sub/x` (and `changed sub/x`).
Fixed: the MOVED_FROM of `sub` drops the watches of its tree. Poll mode passes. A 3 s deadline
ends a failing run.

-}

-- CHECK: watching
-- CHECK-NOT: sub/x]
-- CHECK-NOT: deadline
-- CHECK: event: [moved marker]
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


{-| Create `sub`, let a drain map it, move it out to `other/gone`, write `gone/x`, then
`marker` in the watched directory.
-}
steps : Path -> Path -> Task File.Error ()
steps dir other =
    Process.sleep 100
        |> Task.andThen (\_ -> File.makeDirectory { recursive = False } (child dir "sub"))
        |> Task.andThen (\_ -> Process.sleep 300)
        |> Task.andThen (\_ -> File.move (child other "gone") (child dir "sub"))
        |> Task.andThen (\_ -> Process.sleep 300)
        |> Task.andThen (\_ -> File.writeFile (bytes "x") (child other "gone/x"))
        |> Task.andThen (\_ -> Process.sleep 1200)
        |> Task.andThen (\_ -> File.writeFile (bytes "m") (child dir "marker"))
        |> Task.map (\_ -> ())


{-| The run ends at the creation of `marker`. -}
isLast : String -> Bool
isLast line =
    line == "[moved marker]"


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
                    (File.makeTempDirectory "eco-watch-moveout-")
                    (File.makeTempDirectory "eco-watch-moveout-o-")
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
                        ( model, log model "watch: done" )
        , subscriptions =
            \model ->
                case ( model.dirs, model.done ) of
                    ( Just ( root, _ ), False ) ->
                        Sub.map Event (File.watchRecursive showEvent root)

                    _ ->
                        Sub.none
        }
