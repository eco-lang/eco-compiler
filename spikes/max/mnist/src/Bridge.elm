port module Bridge exposing
    ( TensorSpec, compile, compiledIn, run, runIn, load, loadIn, log, done
    , header, headerId, packed, paddedSize, slice
    )

{-| The ports to a generic MAX host, and the byte layout both sides share.

Every message on a bytes port starts with a 16-byte header whose first u32 (little-endian) is an
id. Tensors follow in order, each padded to a multiple of 16 bytes, so f32 data stays aligned and
a block of tensors can be passed on unchanged: the train graph's updated parameters come back in
exactly the layout they went out in.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Graph exposing (DType(..), Shape)
import Json.Decode as D


port compileOut : Bytes -> Cmd msg


port compiledIn : (D.Value -> msg) -> Sub msg


port runOut : Bytes -> Cmd msg


port runIn : (Bytes -> msg) -> Sub msg


port loadOut : Bytes -> Cmd msg


port loadIn : (Bytes -> msg) -> Sub msg


port logOut : String -> Cmd msg


port doneOut : Int -> Cmd msg


type alias TensorSpec =
    { name : String, dtype : DType, shape : Shape }


header : Int -> Encode.Encoder
header id =
    Encode.sequence (Encode.unsignedInt32 LE id :: List.repeat 3 (Encode.unsignedInt32 LE 0))


headerId : Bytes -> Int
headerId b =
    Maybe.withDefault -1 (Decode.decode (Decode.unsignedInt32 LE) b)


paddedSize : Int -> Int
paddedSize n =
    n + modBy 16 (16 - modBy 16 n)


{-| `b` followed by zeros up to a multiple of 16.
-}
packed : Bytes -> Encode.Encoder
packed b =
    let
        w =
            Bytes.width b
    in
    Encode.sequence (Encode.bytes b :: List.repeat (paddedSize w - w) (Encode.unsignedInt8 0))


{-| `len` bytes of `b` from `offset`.
-}
slice : Int -> Int -> Bytes -> Bytes
slice offset len b =
    Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.bytes len)) b
        |> Maybe.withDefault (Encode.encode (Encode.sequence []))


specText : String -> List TensorSpec -> String
specText tag specs =
    let
        dt d =
            case d of
                F32 ->
                    "f32"

                UI8 ->
                    "ui8"

                SI64 ->
                    "si64"

                Bool_ ->
                    "bool"

        one s =
            s.name ++ ":" ++ dt s.dtype ++ ":" ++ String.join "x" (List.map String.fromInt s.shape)
    in
    String.join " " (tag :: List.map one specs)


{-| Ask the host to compile `mlir` as graph `id`; it answers on `compiledIn`.
-}
compile : Int -> List TensorSpec -> List TensorSpec -> String -> Cmd msg
compile id inputs outputs mlir =
    compileOut
        (Encode.encode
            (Encode.sequence
                [ header id
                , Encode.string (specText "in" inputs ++ "\n" ++ specText "out" outputs ++ "\n" ++ mlir)
                ]
            )
        )


{-| Run graph `id` on tensors already packed by `packed`; the outputs come back on `runIn`.
-}
run : Int -> List Encode.Encoder -> Cmd msg
run id tensors =
    runOut (Encode.encode (Encode.sequence (header id :: tensors)))


{-| Ask the host for the bytes of the file at `path`; they come back on `loadIn` under `id`.
-}
load : Int -> String -> Cmd msg
load id path =
    loadOut (Encode.encode (Encode.sequence [ header id, Encode.string path ]))


log : String -> Cmd msg
log =
    logOut


done : Int -> Cmd msg
done =
    doneOut
