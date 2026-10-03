module FileReadBytesRoundtripTest exposing (main)

{-| `Eco.File.readBytes` reads straight into a heap ByteBuffer (plan S11b).
Round-trips sizes around the large-object threshold (8 KiB), and a missing
file is an `Err`, not an empty or zero-padded buffer.
-}

-- CHECK: FileReadBytesRoundtripTest: True

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Eco.File as File
import Eco.IO.Error exposing (IOError)
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileReadBytesRoundtripTest"


sizes : List Int
sizes =
    [ 0, 1, 31, 8191, 8192, 8200, 1048576 ]


payload : Int -> Bytes
payload n =
    BE.encode (BE.sequence (List.map (\i -> BE.unsignedInt8 (modBy 253 (i * 13 + n))) (List.range 0 (n - 1))))


roundTrip : Int -> Task IOError Bool
roundTrip n =
    let
        p =
            dir ++ "/f" ++ String.fromInt n
    in
    File.writeBytes p (payload n)
        |> Task.andThen (\_ -> File.readBytes p)
        |> Task.map (\got -> Bytes.width got == n && got == payload n)


type Msg
    = Done Bool


checks : Task IOError Bool
checks =
    File.createDir True dir
        |> Task.andThen (\_ -> Task.sequence (List.map roundTrip sizes))
        |> Task.andThen
            (\oks ->
                File.readBytes (dir ++ "/does-not-exist")
                    |> Task.map (\_ -> False)
                    |> Task.onError (\_ -> Task.succeed True)
                    |> Task.map (\missingOk -> List.all identity oks && missingOk)
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.attempt (\r -> Done (r == Ok True)) checks )


update : Msg -> () -> ( (), Cmd Msg )
update (Done ok) m =
    let
        _ =
            Debug.log "FileReadBytesRoundtripTest" ok
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
