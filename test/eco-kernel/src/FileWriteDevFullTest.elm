module FileWriteDevFullTest exposing (main)

{-| FILE-07 (plans/kernel-lib-bug-fixes.md): `Eco.File.writeString` and
`writeBytes` write through a `std::ofstream` and never check the write or the
close. Writing to /dev/full fails with ENOSPC, but the ofstream buffers the
data, the error of the destructor's flush is lost, and both calls succeed.
After the fix both fail with `NoSpaceLeft`.

`hWriteString` on a handle opened on /dev/full is the control: its single
`write` returns -1/ENOSPC and is reported today.
-}

-- LINUX-ONLY: /dev/full
-- CHECK: FileWriteDevFullTest: writeString NoSpaceLeft
-- CHECK: FileWriteDevFullTest: writeBytes NoSpaceLeft
-- CHECK: FileWriteDevFullTest: hWriteString NoSpaceLeft

import Bytes.Encode as BE
import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task exposing (Task)


type Msg
    = Done (List String)


classify : String -> Task IOError () -> Task Never String
classify label task =
    task
        |> Task.map (\_ -> label ++ " Ok")
        |> Task.onError
            (\e ->
                Task.succeed
                    (case e of
                        NoSpaceLeft _ ->
                            label ++ " NoSpaceLeft"

                        _ ->
                            label ++ " other error"
                    )
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , [ classify "writeString" (File.writeString "/dev/full" "hello")
      , classify "writeBytes" (File.writeBytes "/dev/full" (BE.encode (BE.string "hello")))
      , classify "hWriteString"
            (File.open "/dev/full" File.WriteMode
                |> Task.andThen (\h -> File.hWriteString h "hello" |> Task.andThen (\_ -> File.close h))
            )
      ]
        |> Task.sequence
        |> Task.perform Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done lines) m =
    let
        _ =
            List.map (\l -> Debug.log ("FileWriteDevFullTest: " ++ l) ()) lines
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
