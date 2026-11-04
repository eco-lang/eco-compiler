module FileWatchNewTreeTest exposing (main)

{-| WATCH-08 (plans/kernel-lib-bug-fixes.md): every entry of a sub-tree that appears inside a
recursive watch must be reported, including the entries created before the watcher could add
watches for the new directories. The test makes `a/b/c` with one recursive `makeDirectory` and
at once writes `a/b/c/f`. Expected: Moved for `a`, `a/b`, `a/b/c` and `a/b/c/f` (duplicates
allowed).

It failed in inotify mode: one recursive mkdir creates `b` and `c` before any drain adds a watch
on `a`, and the new-directory branch of `mapInotify` added the watches (`addTree`) without
reporting what was already there, so `a/b` and `a/b/c` were never reported (`a/b/c/f` only when
the write landed after that drain). Fixed: `addTree` reports every entry it finds, after the
directory's own event. Poll mode passes. A 3 s deadline ends a failing run.

-}

-- CHECK: watching
-- CHECK-DAG: event: [moved a]
-- CHECK-DAG: event: [moved a/b]
-- CHECK-DAG: event: [moved a/b/c]
-- CHECK-DAG: event: [moved a/b/c/f]
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


{-| Create `a/b/c` in one call, then write `a/b/c/f` at once. -}
steps : Path -> Path -> Task File.Error ()
steps dir _ =
    Process.sleep 100
        |> Task.andThen (\_ -> File.makeDirectory { recursive = True } (child dir "a/b/c"))
        |> Task.andThen (\_ -> File.writeFile (bytes "f") (child dir "a/b/c/f"))
        |> Task.map (\_ -> ())


{-| The run waits for the deadline: the events it expects may arrive in any order, and a
duplicate may follow.
-}
isLast : String -> Bool
isLast _ =
    False


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
                    (File.makeTempDirectory "eco-watch-newtree-")
                    (File.makeTempDirectory "eco-watch-newtree-o-")
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
