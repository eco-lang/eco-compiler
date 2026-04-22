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


items : Int
items =
    1000


listEnc : List Int -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List Int)
listDec =
    BD.succeed []


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 150))


{-| Append one value to the queue via take/modify/put. -}
push : MV.MVar (List Int) -> Int -> Task.Task Never ()
push chan v =
    MV.take listDec chan
        |> Task.andThen (\xs -> MV.put listEnc chan (xs ++ [ v ]))


pushMany : MV.MVar (List Int) -> Int -> Task.Task Never ()
pushMany chan i =
    if i > items then
        Task.succeed ()

    else
        push chan i
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> pushMany chan (i + 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\chan ->
                        MV.put listEnc chan []
                            |> Task.andThen (\_ -> pushMany chan 1)
                            |> Task.andThen (\_ -> MV.take listDec chan)
                    )
                |> Task.map (\xs -> xs == List.range 1 items)
    in
    ( Nothing, Task.perform GotResult task )


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
