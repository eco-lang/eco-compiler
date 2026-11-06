port module Upcase exposing (main)

{-| A filter run inside a C++ program, `host.cpp`, which talks to it through ports.

The host reads its standard input on a thread of its own and sends each chunk in on `input`. For
each chunk this program asks the host to upper-case it, through `upcase`; the host answers at once
on `upcased`, from inside that call. The program counts the bytes and lines of each answer and sends
it out on `output`, which the host writes to its standard output. Once the host has said on
`inputEnded` how many bytes it read, and every chunk has come back, the program sends its counts on
`summary`.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Platform


{-| Chunks of the host's input, in order.
-}
port input : (Bytes -> msg) -> Sub msg


{-| The number of bytes the host read, once its input has ended.
-}
port inputEnded : (Int -> msg) -> Sub msg


{-| Asks the host to upper-case a chunk. The answer arrives on `upcased`.
-}
port upcase : Bytes -> Cmd msg


port upcased : (Bytes -> msg) -> Sub msg


{-| The upper-cased chunks, in order.
-}
port output : Bytes -> Cmd msg


port summary : { chunks : Int, bytes : Int, lines : Int, hostBytes : Int } -> Cmd msg


type Msg
    = Input Bytes
    | Upcased Bytes
    | InputEnded Int


type alias Model =
    { chunks : Int
    , bytes : Int
    , lines : Int
    , waiting : Int
    , hostBytes : Maybe Int
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { chunks = 0, bytes = 0, lines = 0, waiting = 0, hostBytes = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Input chunk ->
            ( { model | waiting = model.waiting + 1 }, upcase chunk )

        Upcased chunk ->
            let
                counted =
                    { model
                        | chunks = model.chunks + 1
                        , bytes = model.bytes + Bytes.width chunk
                        , lines = model.lines + countLines chunk
                        , waiting = model.waiting - 1
                    }
            in
            ( counted, Cmd.batch [ output chunk, finish counted ] )

        InputEnded total ->
            -- The end can arrive while chunks are still out with the host: each answer is queued
            -- behind whatever the host's reader thread had already sent.
            let
                ended =
                    { model | hostBytes = Just total }
            in
            ( ended, finish ended )


{-| The summary, once the input has ended and every chunk has come back.
-}
finish : Model -> Cmd Msg
finish model =
    case model.hostBytes of
        Just total ->
            if model.waiting == 0 then
                summary { chunks = model.chunks, bytes = model.bytes, lines = model.lines, hostBytes = total }

            else
                Cmd.none

        Nothing ->
            Cmd.none


countLines : Bytes -> Int
countLines bytes =
    let
        step ( left, n ) =
            if left == 0 then
                Decode.succeed (Decode.Done n)

            else
                Decode.map
                    (\b ->
                        Decode.Loop
                            ( left - 1
                            , if b == 10 then
                                n + 1

                              else
                                n
                            )
                    )
                    Decode.unsignedInt8
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, 0 ) step) bytes
        |> Maybe.withDefault 0


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch [ input Input, upcased Upcased, inputEnded InputEnded ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
