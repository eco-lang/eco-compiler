module FileWriteBytesAtomicTest exposing (main)

{-| `Eco.File.writeBytesAtomic` (cache-serialization plan S12c): temp file +
rename. Overwrites an existing file, reads back byte for byte, leaves no
`*.tmp-*` sibling, and a write into a missing directory fails with
`FileNotFound` (and also leaves no temp file).
-}

-- CHECK: FileWriteBytesAtomicTest: True

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileWriteBytesAtomicTest"


path : String
path =
    dir ++ "/target.bin"


payload : Int -> Bytes
payload n =
    BE.encode (BE.sequence (List.map (\i -> BE.unsignedInt8 (modBy 251 (i * 7 + n))) (List.range 0 (n - 1))))


type Msg
    = Done Bool


checks : Task IOError Bool
checks =
    File.createDir True dir
        |> Task.andThen (\_ -> File.writeBytes path (payload 10))
        |> Task.andThen (\_ -> File.writeBytesAtomic path (payload 9000))
        |> Task.andThen (\_ -> File.readBytes path)
        |> Task.andThen
            (\got ->
                File.list dir
                    |> Task.andThen
                        (\names ->
                            File.writeBytesAtomic (dir ++ "/missing/sub/x.bin") (payload 3)
                                |> Task.map (\_ -> False)
                                |> Task.onError
                                    (\e ->
                                        case e of
                                            FileNotFound _ ->
                                                Task.succeed True

                                            _ ->
                                                Task.succeed False
                                    )
                                |> Task.andThen
                                    (\missingOk ->
                                        File.list dir
                                            |> Task.map
                                                (\after ->
                                                    (got == payload 9000)
                                                        && (names == [ "target.bin" ])
                                                        && (after == [ "target.bin" ])
                                                        && missingOk
                                                )
                                    )
                        )
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.attempt (\r -> Done (r == Ok True)) checks )


update : Msg -> () -> ( (), Cmd Msg )
update (Done ok) m =
    let
        _ =
            Debug.log "FileWriteBytesAtomicTest" ok
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
