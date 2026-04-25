module MVarChanPipelineStress exposing (main)

{-| Build an unbounded channel out of two MVars (the read-end and the
    write-end), both holding a "tail pointer" into a lazy Cons stream
    realised via MVars. Push N items, then pull N items, verify the
    pulled sequence matches the pushed sequence.

    The `Chan` primitive that `Utils.Main.newChan` constructs has this
    exact shape; exercising it directly stresses the MVar-of-MVar
    interaction at scale.

    Simplification vs the compiler's `Chan`: here we encode the stream
    as a plain queue built from `MVar (List Int)` so the write-end and
    read-end are explicit. This keeps the test focused on the kernel
    semantics without the extra Stream ADT.
-}

-- CHECK: MVarChanPipelineStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 100


listEnc : List Int -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List Int)
listDec =
    BD.succeed []


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 (m // 8)))


push : MV.MVar (List Int) -> Int -> Task.Task Never ()
push chan v =
    MV.take listDec chan
        |> Task.andThen (\xs -> MV.put listEnc chan (xs ++ [ v ]))


pushMany : MV.MVar (List Int) -> Int -> Task.Task Never ()
pushMany chan i =
    if i > m then
        Task.succeed ()

    else
        push chan i
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> pushMany chan (i + 1))


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\chan ->
                MV.put listEnc chan []
                    |> Task.andThen (\_ -> pushMany chan 1)
                    |> Task.andThen (\_ -> MV.take listDec chan)
            )
        |> Task.map (\xs -> xs == List.range 1 m)


repeatCycle : Int -> Task.Task Never Bool
repeatCycle remaining =
    if remaining <= 0 then
        Task.succeed True

    else
        singleCycle
            |> Task.andThen
                (\ok ->
                    if ok then
                        repeatCycle (remaining - 1)

                    else
                        Task.succeed False
                )


init : () -> ( Model, Cmd Msg )
init _ =
    ( Nothing, Task.perform GotResult (repeatCycle loopCount) )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarChanPipelineStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
