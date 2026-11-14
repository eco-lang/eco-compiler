module Finetune.Qlora exposing
    ( Quantized, Block, blocks, params
    , quantize
    , dequantize, apply
    , codebook
    )

{-| QLoRA (Dettmers et al. 2023) fine-tunes a dense layer whose weight is frozen and kept in a
compact form, each element replaced by a small integer code, while only a LoRA adapter beside it
(`Finetune.Lora`) is trained. This module is that frozen weight: how a parameter description holds
it, how its codes are computed from a weight in Elm, and how a graph turns them back into a dense
weight and applies it with an adapter.

The weight W has shape (i, o), from `i` input features to `o` output features, as in `Nn.Linear`.
To _quantize_ it, its elements are taken in row-major order and cut into _blocks_ of consecutive
elements, as many in each as the _block size_ (`Quantized`'s `blockSize`), which divides i × o.
Each block has a _scale_ and each element is replaced by its _code_. A block's scale is the largest
magnitude among its elements, or 1 when they are all 0, and an element's code is the index of the
value in the _codebook_ nearest to the element divided by its block's scale. To _dequantize_ it,
each element is its code's codebook value times its block's scale.

The codebook is _NF4_ (4-bit NormalFloat), the 16 values of `codebook`. A code is therefore in
0 … 15 and needs only 4 bits, but here each code is stored in a byte of its own, as a `u8`.

The codes and scales are data fields of the description (`Param.data`): training does not update
them, and `Param.initial` and `Train.initial` give them zeros. `quantize` computes their contents,
as bytes for `Train.initialFrom` or for a runtime that takes buffers as bytes.

Given the same scale dtype, block size and dimensions as `params`, `quantize` gives bytes of the
lengths and dtypes that the description's `codes` and `scales` fields have, or an error when the
block size is not positive or does not divide i × o. `dequantize` refuses such a block size too,
with a build error.


# Quantized weights

@docs Quantized, Block, blocks, params


# Preparing the weights

@docs quantize


# Applying

@docs dequantize, apply


# NF4

@docs codebook

-}

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Finetune.Lora as Lora exposing (Lora)
import Param
import Tensor as T exposing (DType, Dim, R1, R2, Tensor, U8)
import Tensor.Internal.Encode as Elements
import Tensor.Internal.Expr as E
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values


{-| The tag of the axis that indexes a weight's blocks, the one axis of `Quantized`'s `scales`.

Its constructor is not exposed, so outside this package a `Dim Block` is made only by `blocks`.

-}
type Block
    = Block


{-| A frozen (i, o) weight in quantized form, whose dequantized elements have dtype `d`.

`codes` holds each element's code, an index into `codebook`, not its value. `scales` holds one
scale per block, in block order. `blockSize` is the `size` given to `params`, the number of
elements in each block.

-}
type alias Quantized d i o =
    { codes : Tensor Int U8 (R2 i o), scales : Tensor Float d (R1 Block), blockSize : Int }


{-| The 16 NF4 values in ascending order, which a code indexes. They run from −1 to 1, are closer
together near 0 than near ±1, and include 0 itself.
-}
codebook : List Float
codebook =
    [ -1.0, -0.6961928009986877, -0.5250730514526367, -0.39491748809814453, -0.28444138169288635, -0.18477343022823334, -0.09105003625154495, 0.0, 0.07958029955625534, 0.16093020141124725, 0.24611230194568634, 0.33791524171829224, 0.44070982933044434, 0.5626170039176941, 0.7229568362236023, 1.0 ]


{-| Returns the dimension of the scales of an (i, o) weight cut into blocks of `size` elements:
i × o divided by `size` with Elm's `//`. A `size` of 0 or less is taken as 1.

When `size` is not positive or does not divide i × o, `quantize` refuses the weight and `dequantize`
gives a build error, so such a dimension describes no weight they accept.

-}
blocks : Int -> Dim i -> Dim o -> Dim Block
blocks size i o =
    T.dim Block ((T.size i * T.size o) // Basics.max 1 size)


{-| Returns the description of an (i, o) weight quantized in blocks of `size` elements, whose
scales have dtype `dt`.

`codes` and `scales`, in that order, are data fields, and `scales` has `blocks size i o` elements.
`blockSize` is a config field holding `size`. `quantize dt size i o` gives their contents as bytes.

-}
params : DType Float d -> Int -> Dim i -> Dim o -> Param.Spec (Quantized d i o)
params dt size i o =
    Param.record Quantized
        |> Param.data .codes T.uint8 (T.r2 i o)
        |> Param.data .scales dt (T.r1 (blocks size i o))
        |> Param.config .blockSize size


{-| Returns the codes and scales of an (i, o) weight given as its i × o elements in row-major order,
as bytes in the package encoding that `Train` describes: one byte per code, and one element of `dt`
per scale.

The elements are cut into blocks of `size` in list order. A block's scale is the largest magnitude
among its elements, or 1 when they are all 0, and an element's code is the index of the `codebook`
value nearest to the element divided by its block's scale, the lower index on a tie.

The result is an error, and no bytes are made, when `size` is 0 or less, when the number of
elements is not i × o, when `size` does not divide i × o, or when an element is NaN or ±∞.

The bytes are meant for `Train.initialFrom`, under the resident names `Param.names` gives the
`codes` and `scales` fields of `params dt size i o`, whose lengths and dtypes they match, or for a
runtime that takes buffers as bytes. `Tensor.Eval` takes buffers as values, not bytes.

-}
quantize : DType Float d -> Int -> Dim i -> Dim o -> List Float -> Result String { codes : Bytes, scales : Bytes }
quantize (I.DType dt _) size i o weights =
    let
        n =
            T.size i * T.size o

        count =
            List.length weights

        problem =
            if size <= 0 then
                Just ("the block size is " ++ String.fromInt size ++ ", but it must be positive")

            else if count /= n then
                Just (String.fromInt count ++ " weights were given for " ++ String.fromInt (T.size i) ++ " × " ++ String.fromInt (T.size o) ++ " = " ++ String.fromInt n)

            else if modBy size n /= 0 then
                Just ("the block size " ++ String.fromInt size ++ " does not divide the " ++ String.fromInt n ++ " weights")

            else if List.any (\w -> isNaN w || isInfinite w) weights then
                Just "a weight is NaN or infinite"

            else
                Nothing

        -- Tail-recursive, so that the number of blocks is not limited by the stack.
        go rest codesAcc scalesAcc =
            case rest of
                [] ->
                    ( List.reverse codesAcc, List.reverse scalesAcc )

                _ ->
                    let
                        block =
                            List.take size rest

                        absmax =
                            List.foldl (\w m -> Basics.max m (Basics.abs w)) 0 block

                        scale =
                            if absmax == 0 then
                                1

                            else
                                absmax
                    in
                    go (List.drop size rest)
                        (List.foldl (\w acc -> nearest (w / scale) :: acc) codesAcc block)
                        (scale :: scalesAcc)
    in
    case problem of
        Just p ->
            Err ("Qlora.quantize: " ++ p)

        Nothing ->
            let
                ( codes, scales ) =
                    go weights [] []
            in
            Ok
                { codes = Elements.encodeValues UI8 (Values.IntValues codes)
                , scales = Elements.encodeValues dt (Values.FloatValues scales)
                }


{-| Returns the index of the `codebook` value nearest to `v`, the lower index on a tie, for a `v`
from −1 to 1. For NaN or ±∞ it returns 0.
-}
nearest : Float -> Int
nearest v =
    List.indexedMap (\k c -> ( Basics.abs (v - c), k )) codebook
        |> List.foldl
            (\( d, k ) ( bd, bk ) ->
                if d < bd then
                    ( d, k )

                else
                    ( bd, bk )
            )
            ( 1.0e30, 0 )
        |> Tuple.second


{-| Returns the dense weight that `q` stands for: each element its code's `codebook` value times its
block's scale, a block being the next `q.blockSize` elements in row-major order.

The result is a build error when `q.blockSize` is 0 or less, or when the number of scales times
`q.blockSize` is not i × o. The products are computed in f32 and then cast to the scales' dtype. A
code of 16 or more is an index outside `codebook`, which, like any index, is not checked when the
graph is built; `Tensor.Eval` refuses it when it runs the graph.

-}
dequantize : Quantized d i o -> Tensor Float d (R2 i o)
dequantize q =
    let
        codes =
            I.tensor q.codes

        scales =
            I.tensor q.scales

        s =
            E.shape codes

        n =
            List.product s

        nb =
            List.product (E.shape scales)

        size =
            Basics.max 1 q.blockSize

        values =
            O.gather 0 (E.const F32 [ 16 ] codebook) (O.cast SI64 (O.flatten codes))

        byBlock =
            O.reshape [ nb, size ] values

        scaled =
            O.mul byBlock (O.broadcastTo [ nb, size ] (O.insertAxis 1 (O.cast F32 scales)))

        result =
            O.cast (E.dtype scales) (O.reshape s scaled)

        -- A refused weight is built without the reshapes, which would fail first and keep their
        -- own message (Tensor.Internal.Expr.failWith records nothing on a failed expression).
        refuse msg =
            O.cast (E.dtype scales) codes
                |> E.inherit scales
                |> E.failWith ("Qlora.dequantize: " ++ msg)
    in
    if q.blockSize <= 0 then
        I.Tensor (refuse ("the block size is " ++ String.fromInt q.blockSize ++ ", but it must be positive"))

    else if nb * q.blockSize /= n then
        I.Tensor (refuse (String.fromInt nb ++ " scales of blocks of " ++ String.fromInt q.blockSize ++ " cover " ++ String.fromInt (nb * q.blockSize) ++ " elements, but the weight has " ++ String.fromInt n))

    else
        I.Tensor result


{-| Returns the `n` rows of `x` multiplied by the dequantized weight, plus the adapter's
contribution: x · `dequantize q` + x · `Lora.delta lora`. No bias is added.

Unlike `Lora.apply`, this forms the adapter's whole (i, o) update with `Lora.delta` before
multiplying, rather than multiplying `x` by A and then by B.

-}
apply : Quantized d i o -> Lora d i r o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply q lora x =
    x |> T.matmul (dequantize q) |> T.plus (x |> T.matmul (Lora.delta lora))
