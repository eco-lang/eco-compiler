port module Churn exposing (main)

{-| The MNIST spike's per-step Bytes traffic without MAX, one allocation path per mode:

  - "both": as MNIST: send [header | 407 KB slice of the last reply | 78 KB batch] built with
    Encode, and get a 407 KB reply emitted into the heap by the host
  - "encode": only build and drop the 485 KB Encode result (the host replies with 16 bytes)
  - "emit": send 16 bytes; the host emits the 407 KB reply
  - "selfloop": no ports per step: build and drop the 485 KB Encode result in a Task loop
  - "slices": as "both", but the 78 KB batch is a slice of a 47 MB Bytes the host sent on dataIn,
    at a different offset each step, as MNIST takes its batches
  - "slice0": as "slices", always at offset 0
  - "hold": the 47 MB Bytes is held, but the batch is the ordinary 78 KB one
  - "sliceonly": a slice of the 47 MB Bytes is taken each step and only its width used

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Json.Decode as D
import Platform
import Task


port reqOut : Bytes -> Cmd msg


port respIn : (Bytes -> msg) -> Sub msg


port logOut : String -> Cmd msg


port dataIn : (Bytes -> msg) -> Sub msg


type Msg
    = Resp Bytes
    | Next
    | Data Bytes


type alias Model =
    { mode : String, steps : Int, step : Int, params : Bytes, batch : Bytes, sink : Int, data : Bytes }


slice : Int -> Int -> Bytes -> Bytes
slice off len b =
    Decode.decode (Decode.bytes off |> Decode.andThen (\_ -> Decode.bytes len)) b
        |> Maybe.withDefault (Encode.encode (Encode.sequence []))


filled : Int -> Bytes
filled n =
    Encode.encode (Encode.sequence (List.repeat (n // 4) (Encode.unsignedInt32 LE 7)))


header : Encode.Encoder
header =
    Encode.sequence (List.repeat 4 (Encode.unsignedInt32 LE 0))


big : Model -> Bytes
big m =
    Encode.encode (Encode.sequence [ header, Encode.bytes m.params, Encode.bytes (batchOf m) ])


batchOf : Model -> Bytes
batchOf m =
    case m.mode of
        "slices" ->
            slice (16 + modBy 600 m.step * 78400) 78512 m.data

        "slice0" ->
            slice 16 78512 m.data

        "sliceonly" ->
            if Bytes.width (slice (16 + modBy 600 m.step * 78400) 78512 m.data) > 0 then
                m.batch

            else
                m.params

        _ ->
            m.batch


request : Model -> Cmd Msg
request m =
    case m.mode of
        "emit" ->
            reqOut (Encode.encode header)

        "selfloop" ->
            Task.perform (\_ -> Next) (Task.succeed ())

        _ ->
            reqOut (big m)


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        field f d dflt =
            Result.withDefault dflt (D.decodeValue (D.field f d) flags)

        m =
            { mode = field "mode" D.string "both"
            , steps = field "steps" D.int 3000
            , step = 0
            , params = filled 407088
            , batch = filled 78512
            , sink = 0
            , data = Encode.encode (Encode.sequence [])
            }
    in
    if List.member m.mode [ "slices", "slice0", "hold", "sliceonly" ] then
        ( m, Cmd.none )

    else
        ( m, request m )


advance : Model -> ( Model, Cmd Msg )
advance m =
    if m.step >= m.steps then
        ( m, logOut ("done " ++ String.fromInt m.sink) )

    else
        ( m, request m )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg m =
    case msg of
        Resp bytes ->
            let
                m2 =
                    { m | step = m.step + 1 }
            in
            if m.mode /= "encode" then
                advance { m2 | params = slice 16 407088 bytes }

            else
                advance m2

        Data bytes ->
            let
                m2 =
                    { m | data = bytes }
            in
            ( m2, request m2 )

        Next ->
            advance { m | step = m.step + 1, sink = m.sink + Bytes.width (big m) }


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.batch [ respIn Resp, dataIn Data ]
        }
