module Max.Internal.Elements exposing (byteSize, check, decode, encode)

{-| A tensor crosses between Elm and the MAX host as bytes, while `Tensor.Eval` computes on
`Value`s, so a session that runs graphs either way has to turn one into the other. This module
does that, in both directions and for every dtype the package has, and also checks whether a value
fits a tensor's dtype and shape.

A tensor is described here by any record with a `dtype` and a `shape`, as `Graph.Spec` and
`Tensor.Eval.Value` both are. The `dtype` is the dtype's name as `Graph.Spec` gives it (`"f32"`,
`"si64"`, `"bool"`, …). A name the package does not have is refused by `byteSize`, `decode`,
`encode` and `check` alike.

The bytes are in the package encoding that `Train` states: row-major, little-endian, each element
at its dtype's width, with nothing between or around the elements. `encode` writes them with
`Tensor.Internal.Encode.encodeValues`, which decides how each value is rounded or converted on the
way to bytes. `decode` reads the same layout back:

  - `f16` and `bf16` patterns are read as the numbers they stand for, ±∞, signed zeros and
    subnormals included; every NaN pattern gives NaN, but its sign and payload are not carried
    over.
  - `f32` and `f64` are read by elm/bytes.
  - `si8`, `si32` and `ui8` are read at their width, signed or not as their names say.
  - `si64` and `ui64` are read as a low unsigned 32-bit word and a high signed one. Natively that
    gives the `Int` with the element's 64 bits, so a `ui64` element of 2⁶³ or more is a negative
    `Int`, as `Tensor.Eval.Data` describes. Under JavaScript an `Int` is a double, and an element
    beyond ±2⁵³ may be read inexactly.
  - a `bool` byte is `True` when it is not 0.

Decoding does not undo every encoding. On the way to bytes a float is rounded to its dtype and an
integer is not range-checked, as `Tensor.Internal.Encode` describes, and an f16 or bf16 NaN does
not come back with its sign and payload.

`encode` checks nothing but the dtype name. Whether a value fits a tensor is `check`'s question,
answered by the rule `Tensor.Eval.run` applies to an input value, so its messages are worded for an
input.

-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder)
import Tensor.Eval exposing (Data(..), Value)
import Tensor.Internal.Encode as Encode
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Values as Values


{-| Returns the dtype whose name, as `Tensor.Internal.Prim.dtName` spells it, is `name`, or
`Nothing` if no dtype has that name.
-}
dtypeNamed : String -> Maybe DT
dtypeNamed name =
    List.filter (\d -> P.dtName d == name) P.allDTs |> List.head


{-| Returns the number of bytes a tensor of the spec's dtype and shape takes in the package
encoding, or `Nothing` for a dtype name the package does not have.
-}
byteSize : { a | dtype : String, shape : List Int } -> Maybe Int
byteSize spec =
    dtypeNamed spec.dtype |> Maybe.map (\dt -> P.dtSize dt * List.product spec.shape)


{-| Reads `bytes` as a value of the spec's dtype and shape, each dtype as the module docstring
lists, or returns why it cannot: a dtype the package does not have (`"unknown dtype x"`), or a
width other than the one `byteSize` gives for the spec (`"10 bytes, but si32 [3] takes 12"`).
-}
decode : { a | dtype : String, shape : List Int } -> Bytes -> Result String Value
decode spec bytes =
    case dtypeNamed spec.dtype of
        Nothing ->
            Err ("unknown dtype " ++ spec.dtype)

        Just dt ->
            let
                count =
                    List.product spec.shape

                wanted =
                    P.dtSize dt * count
            in
            if Bytes.width bytes /= wanted then
                Err
                    (String.fromInt (Bytes.width bytes)
                        ++ " bytes, but "
                        ++ spec.dtype
                        ++ " ["
                        ++ String.join ", " (List.map String.fromInt spec.shape)
                        ++ "] takes "
                        ++ String.fromInt wanted
                    )

            else
                let
                    data =
                        if P.isFloat dt then
                            Maybe.map Floats (Decode.decode (many count (floatElement dt)) bytes)

                        else if dt == Bool then
                            Maybe.map Bools (Decode.decode (many count (Decode.map (\n -> n /= 0) Decode.unsignedInt8)) bytes)

                        else
                            Maybe.map Ints (Decode.decode (many count (intElement dt)) bytes)
                in
                case data of
                    Just d ->
                        Ok { dtype = spec.dtype, shape = spec.shape, data = d }

                    Nothing ->
                        Err ("cannot read " ++ spec.dtype ++ " elements")


{-| Produces a decoder for `count` elements, each read by `element`, in order.
-}
many : Int -> Decoder a -> Decoder (List a)
many count element =
    Decode.loop ( count, [] )
        (\( n, acc ) ->
            if n <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.map (\x -> Decode.Loop ( n - 1, x :: acc )) element
        )


{-| Produces a decoder for one little-endian element of the floating-point dtype `dt`. Any dtype
other than `F64`, `F16` and `BF16` is read as an f32.
-}
floatElement : DT -> Decoder Float
floatElement dt =
    case dt of
        F64 ->
            Decode.float64 LE

        F16 ->
            Decode.map f16Value (Decode.unsignedInt16 LE)

        BF16 ->
            Decode.map bf16Value (Decode.unsignedInt16 LE)

        _ ->
            Decode.float32 LE


{-| Produces a decoder for one element of the integer dtype `dt`, little-endian where it is wider
than a byte. Any dtype other than `SI8`, `SI32`, `SI64` and `UI64` is read as one unsigned byte,
which is right for `UI8`.
-}
intElement : DT -> Decoder Int
intElement dt =
    case dt of
        SI8 ->
            Decode.signedInt8

        SI32 ->
            Decode.signedInt32 LE

        SI64 ->
            int64

        UI64 ->
            int64

        _ ->
            Decode.unsignedInt8


{-| A decoder for a 64-bit integer written as its low 32 bits, unsigned, then its high 32 bits,
signed, each little-endian. It gives `high * 2³² + low`, which natively is the `Int` with those
64 bits; under JavaScript it is the nearest double, inexact for some values beyond ±2⁵³.
-}
int64 : Decoder Int
int64 =
    Decode.map2 (\low high -> high * 4294967296 + low) (Decode.unsignedInt32 LE) (Decode.signedInt32 LE)


{-| Returns the number the f16 pattern `bits` stands for. Every NaN pattern gives the NaN `0 / 0`
gives, so its sign and payload are not carried over.
-}
f16Value : Int -> Float
f16Value bits =
    let
        sign =
            if Bitwise.and bits 0x8000 /= 0 then
                -1

            else
                1

        e =
            Bitwise.and (Bitwise.shiftRightZfBy 10 bits) 0x1F

        m =
            toFloat (Bitwise.and bits 0x03FF)
    in
    if e == 0 then
        sign * m * (2 ^ -24)

    else if e == 31 then
        if m == 0 then
            sign * (1 / 0)

        else
            0 / 0

    else
        sign * (1 + m / 1024) * (2 ^ toFloat (e - 15))


{-| Returns the number the bf16 pattern `bits` stands for: the f32 whose upper 16 bits are `bits`
and whose lower 16 bits are zero. Every NaN pattern gives the NaN `0 / 0` gives, so its sign and
payload are not carried over.
-}
bf16Value : Int -> Float
bf16Value bits =
    let
        sign =
            if Bitwise.and bits 0x8000 /= 0 then
                -1

            else
                1

        e =
            Bitwise.and (Bitwise.shiftRightZfBy 7 bits) 0xFF

        m =
            toFloat (Bitwise.and bits 0x7F)
    in
    if e == 0 then
        sign * m * (2 ^ -133)

    else if e == 255 then
        if m == 0 then
            sign * (1 / 0)

        else
            0 / 0

    else
        sign * (1 + m / 128) * (2 ^ toFloat (e - 127))


{-| Returns `Ok ()` if `value` is a tensor of the spec's dtype and shape, or why it is not.

The tests are made in the order below, and the message is that of the first test that fails. The
spec's dtype must be one the package has. `value` must have the spec's dtype and exactly its shape,
and as many elements as the shape holds. Its `Data` must be `Floats` for a floating-point dtype,
`Ints` for an integer dtype and `Bools` for `bool`, and any other kind is refused, as in
`"Ints for a floating or mask input"`. `Ints` for `si8`, `ui8` or `si32` must fit the dtype's
range (`"value 300 does not fit ui8"`), while for `si64` and `ui64` any `Int` is accepted.

These are the tests `Tensor.Eval.run` makes of an input value, and the messages are the same
without the `"<graph>: input <key>: "` that `run` puts before them. `run` tests the kind and the
range before the element count, so for a value with the wrong number of elements that also has the
wrong kind of `Data`, or an integer out of range, the two give different messages.

-}
check : { a | dtype : String, shape : List Int } -> Value -> Result String ()
check spec value =
    let
        count =
            List.product spec.shape

        length =
            case value.data of
                Floats l ->
                    List.length l

                Ints l ->
                    List.length l

                Bools l ->
                    List.length l
    in
    case dtypeNamed spec.dtype of
        Nothing ->
            Err ("unknown dtype " ++ spec.dtype)

        Just dt ->
            if value.dtype /= spec.dtype then
                Err ("dtype " ++ value.dtype ++ ", but the graph takes " ++ spec.dtype)

            else if value.shape /= spec.shape then
                Err ("shape [" ++ showInts value.shape ++ "], but the graph takes [" ++ showInts spec.shape ++ "]")

            else if length /= count then
                Err (String.fromInt length ++ " elements, but the shape has " ++ String.fromInt count)

            else
                case value.data of
                    Floats _ ->
                        if P.isFloat dt then
                            Ok ()

                        else
                            Err "Floats for an integer or mask input"

                    Ints l ->
                        if P.isInt dt then
                            case Values.fitsDtype dt (Values.IntValues l) of
                                Just msg ->
                                    Err msg

                                Nothing ->
                                    Ok ()

                        else
                            Err "Ints for a floating or mask input"

                    Bools _ ->
                        if dt == Bool then
                            Ok ()

                        else
                            Err "Bools for a non-mask input"


{-| Returns the integers in `l` in decimal, separated by commas, for an error message.
-}
showInts : List Int -> String
showInts l =
    String.join ", " (List.map String.fromInt l)


{-| Returns `value`'s elements as bytes of its dtype in the package encoding, in list order, or
`"unknown dtype x"` for a dtype the package does not have.

Nothing else is checked: not the shape, not the element count, not the kind of `Data` or the range
of an integer. Each element is converted as `Tensor.Internal.Encode.encodeValues` converts it, with
`Bools` given to it as the integers 1 and 0. `check` is the test of whether a value fits.

-}
encode : Value -> Result String Bytes
encode value =
    case dtypeNamed value.dtype of
        Nothing ->
            Err ("unknown dtype " ++ value.dtype)

        Just dt ->
            Ok
                (Encode.encodeValues dt
                    (case value.data of
                        Floats l ->
                            Values.FloatValues l

                        Ints l ->
                            Values.IntValues l

                        Bools l ->
                            Values.IntValues
                                (List.map
                                    (\b ->
                                        if b then
                                            1

                                        else
                                            0
                                    )
                                    l
                                )
                    )
                )
