module ProcessSpawnExternalTest exposing (main)

{-| `spawn` with an `External` connection (plans/eco-system-library.md Phase 5
step 5.4): write to `cat`'s stdin, close it, read everything back from its
stdout, see its stderr close empty, and receive `onExit 0`. The External
streams are FdSink/FdSource streams over the child's pipes.
-}

-- CHECK: stdout: hello child|second line|
-- CHECK: stderr: <empty>
-- CHECK: exit: 0
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode
import Process
import ProcessTestHelp exposing (bytesToString)
import Stream
import Stream.Log
import System
import System.Process as P
import Task exposing (Task)


type Msg
    = Started { processId : Process.Id, streams : P.StreamIO }
    | Output String String
    | Exited Int
    | Logged


type alias Model =
    { env : System.Environment
    , output : Maybe ( String, String )
    , exit : Maybe Int
    }


utf8 : String -> Bytes
utf8 s =
    Bytes.Encode.encode (Bytes.Encode.string s)


readAll : Stream.Readable Bytes -> Task Stream.Error String
readAll readable =
    Stream.readUntilClosed (\chunk acc -> Ok (acc ++ bytesToString chunk)) "" readable


talk : P.StreamIO -> Task Never Msg
talk streams =
    Stream.write (utf8 "hello child\n") streams.input
        |> Task.andThen (\_ -> Stream.write (utf8 "second line\n") streams.input)
        |> Task.andThen (\_ -> Stream.closeWritable streams.input)
        |> Task.andThen (\_ -> Task.map2 Output (readAll streams.output) (readAll streams.error))
        |> Task.onError (\err -> Task.succeed (Output ("error: " ++ Stream.errorToString err) ""))


report : Model -> ( Model, Cmd Msg )
report model =
    case ( model.output, model.exit ) of
        ( Just ( out, err ), Just code ) ->
            ( model
            , Task.perform (\_ -> Logged)
                (Stream.Log.line model.env.stdout
                    ("stdout: "
                        ++ String.replace "\n" "|" out
                        ++ "\nstderr: "
                        ++ (if err == "" then
                                "<empty>"

                            else
                                err
                           )
                        ++ "\nexit: "
                        ++ String.fromInt code
                    )
                )
            )

        _ ->
            ( model, Cmd.none )


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, output = Nothing, exit = Nothing }
                , P.spawn "cat" [] (P.defaultSpawnOptions (P.External Started) Exited)
                )
        , update =
            \msg model ->
                case msg of
                    Started { streams } ->
                        ( model, Task.perform identity (talk streams) )

                    Output out err ->
                        report { model | output = Just ( out, err ) }

                    Exited code ->
                        report { model | exit = Just code }

                    Logged ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
