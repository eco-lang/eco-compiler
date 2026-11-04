module MVarReadAfterDropFailsTest exposing (main)

{-| FILE-04 (plans/kernel-lib-bug-fixes.md): `Eco.MVar.read` of an MVar that was
dropped. The kernel evaluator (MVar.cpp `resumeNotFound`) fails the task with
the IO error tuple ("MVar not found: <id>"). Before decision D10 the API typed
the task `Task Never`, so a failure handed `Task.attempt` an `Err` holding a
value of type Never. D10 retyped `read`, `take` and `put` to `Task IOError`,
so the program now gets an `OtherIOError` whose message names the MVar.
-}

-- CHECK: MVarReadAfterDropFailsTest: Err OtherIOError MVar not found:
-- CHECK-NOT: MVarReadAfterDropFailsTest: Ok

import Bytes exposing (Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.IO.Error exposing (IOError(..))
import Eco.MVar as MV
import Platform
import Task


type Msg
    = Done String


intEnc : Int -> BE.Encoder
intEnc n =
    BE.signedInt32 BE n


intDec : BD.Decoder Int
intDec =
    BD.signedInt32 BE


init : () -> ( (), Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen (\m -> MV.drop m |> Task.andThen (\_ -> MV.read intDec m))
    in
    ( ()
    , Task.attempt
        (\r ->
            case r of
                Ok _ ->
                    Done "Ok"

                Err (OtherIOError e) ->
                    Done ("Err OtherIOError " ++ e.message)

                Err _ ->
                    Done "Err (another constructor)"
        )
        task
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done how) m =
    let
        _ =
            Debug.log ("MVarReadAfterDropFailsTest: " ++ how) ()
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
