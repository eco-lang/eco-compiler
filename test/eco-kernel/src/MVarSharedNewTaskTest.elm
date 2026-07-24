module MVarSharedNewTaskTest exposing (main)

{-| Task purity (plans/task-purity-and-caf-guard-removal.md): a Task is an
    immutable REQUEST for IO — fulfilling the same Task value twice performs
    the IO twice. Here ONE `MV.new` task value bound via `let` is fulfilled
    twice; each fulfilment must allocate a FRESH MVar.

    Under the old eager kernel (`Eco_Kernel_MVar_new` ran `newEmpty()` at
    value evaluation), both fulfilments observed the same id, so after
    `drop m1` the second "new" MVar was already dead and the put failed.
    This is the same shape a CAF-memoized `MV.new` takes once the
    effect-type memoization guard is removed (CGEN_068).

    Chain: t ⟹ m1, put m1 111, drop m1, t ⟹ m2, put m2 222, take m2 → 222.
-}

-- CHECK: MVarSharedNewTaskTest: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


intEnc : Int -> BE.Encoder
intEnc n =
    BE.signedInt32 BE n


intDec : BD.Decoder Int
intDec =
    BD.signedInt32 BE


init : () -> ( Model, Cmd Msg )
init _ =
    let
        sharedNew =
            MV.new

        task =
            sharedNew
                |> Task.andThen
                    (\m1 ->
                        MV.put intEnc m1 111
                            |> Task.andThen (\_ -> MV.drop m1)
                            |> Task.andThen (\_ -> sharedNew)
                            |> Task.andThen
                                (\m2 ->
                                    MV.put intEnc m2 222
                                        |> Task.andThen (\_ -> MV.take intDec m2)
                                )
                    )
                |> Task.map (\v -> v == 222)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarSharedNewTaskTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
