module FileReadHugeFileTest exposing (main)

{-| FILE-03 (plans/kernel-lib-bug-fixes.md): `Eco.File.readString` has no size
cap. `readBytes` rejects a file over 4 GiB with EFBIG ("file too large for
Bytes", ByteBuffer `header.size` is u32); `readString` sizes the file with
`tellg` and hands the size straight to `allocByteBufferBlank`.

The file is a sparse 1 TiB + 1 byte file (truncate(1)), so no disk is used.
Today readString asks the heap for a 1 TiB byte buffer, which is above the
24 GiB maximum heap: after a recovery minor and major GC the runtime aborts
with largeBodyExhausted, and the readString line never appears. (The plan's
4 GiB + 1 variant, which would show the u32 truncation as `Ok 1`, needs a
small heap through `-- ENV: ECO_HEAP_CONFIG=<json file>`, and there is no
fixed path for such a file; a file above the heap cap exposes the same
missing check without touching memory.) After the fix both calls fail with
`OtherIOError` (EFBIG, tag 0) whose message says "too large".

readBytes runs first, as a control that passes today. The sparse file is
left behind when the program aborts; the next run truncates it again.
-}

-- LINUX-ONLY: sparse file via truncate(1)
-- CHECK: FileReadHugeFileTest: readBytes Err OtherIOError too-large=True
-- CHECK: FileReadHugeFileTest: readString Err OtherIOError too-large=True

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Eco.Process as P
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileReadHugeFileTest"


big : String
big =
    dir ++ "/big"


type Msg
    = Ready Bool
    | GotBytes String
    | GotString String
    | Removed


describe : Result IOError Int -> String
describe r =
    case r of
        Ok n ->
            "Ok " ++ String.fromInt n

        Err (OtherIOError e) ->
            "Err OtherIOError too-large=" ++ (if String.contains "too large" e.message then "True" else "False")

        Err (FileNotFound _) ->
            "Err FileNotFound"

        Err (IsADirectory _) ->
            "Err IsADirectory"

        Err _ ->
            "Err other"


setup : Task Never Bool
setup =
    File.createDir True dir
        |> Task.mapError (\_ -> ())
        |> Task.andThen
            (\_ ->
                P.spawn "truncate" [ "-s", "1099511627777", big ]
                    |> Task.mapError (\_ -> ())
            )
        |> Task.andThen (\h -> P.wait h |> Task.mapError never)
        |> Task.map (\code -> code == P.ExitSuccess)
        |> Task.onError (\_ -> Task.succeed False)


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.perform Ready setup )


log : String -> ()
log s =
    Debug.log ("FileReadHugeFileTest: " ++ s) ()


update : Msg -> () -> ( (), Cmd Msg )
update msg m =
    case msg of
        Ready ok ->
            if ok then
                ( m, Task.attempt (\r -> GotBytes (describe r)) (File.readBytes big |> Task.map (\_ -> -1)) )

            else
                let
                    _ =
                        log "setup failed"
                in
                ( m, Cmd.none )

        GotBytes s ->
            let
                _ =
                    log ("readBytes " ++ s)
            in
            ( m, Task.attempt (\r -> GotString (describe r)) (File.readString big |> Task.map String.length) )

        GotString s ->
            let
                _ =
                    log ("readString " ++ s)
            in
            ( m, Task.attempt (\_ -> Removed) (File.removeFile big) )

        Removed ->
            ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
