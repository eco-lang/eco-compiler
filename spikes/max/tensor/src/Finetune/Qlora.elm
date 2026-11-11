module Finetune.Qlora exposing (Quantized, Block, blocks, params, quantize, dequantize, apply, codebook)

{-| QLoRA (Dettmers et al. 2023): a frozen weight stored as 4-bit NormalFloat codes (one per byte
here) with one scale per block of weights, plus a trainable LoRA adapter.

The codes and scales are `Param.data`: loaded by the host (`quantize` writes their block), never
trained.

-}

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Finetune.Lora as Lora exposing (Lora)
import Param
import Tensor as T exposing (DType, Dim, Floating, Integral, R1, R2, Tensor, U8)
import Tensor.Internal.Expr as E
import Tensor.Internal.Host as Host
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


type Block
    = Block


type alias Quantized d i o =
    { codes : Tensor Integral U8 (R2 i o), scales : Tensor Floating d (R1 Block), blockSize : Int }


{-| The 16 NF4 values: quantiles of a standard normal, scaled to [-1, 1], with an exact zero.
-}
codebook : List Float
codebook =
    [ -1.0, -0.6961928009986877, -0.5250730514526367, -0.39491748809814453, -0.28444138169288635, -0.18477343022823334, -0.09105003625154495, 0.0, 0.07958029955625534, 0.16093020141124725, 0.24611230194568634, 0.33791524171829224, 0.44070982933044434, 0.5626170039176941, 0.7229568362236023, 1.0 ]


{-| The number of blocks of an i × o weight (blockSize must divide i × o).
-}
blocks : Int -> Dim i -> Dim o -> Dim Block
blocks size i o =
    T.dim Block ((T.size i * T.size o) // Basics.max 1 size)


params : DType Floating d -> Int -> Dim i -> Dim o -> Param.Spec (Quantized d i o)
params dt size i o =
    Param.record Quantized
        |> Param.data .codes T.uint8 (T.r2 i o)
        |> Param.data .scales dt (T.r1 (blocks size i o))
        |> Param.config .blockSize size


{-| Host side: row-major f32 weights to the parameter block of `params` (codes, then f32 scales:
each block's largest magnitude), ready for `Train.initialFrom`.
-}
quantize : Int -> Dim i -> Dim o -> List Float -> Bytes
quantize size _ _ weights =
    let
        blocksOf l =
            if List.isEmpty l then
                []

            else
                List.take size l :: blocksOf (List.drop size l)

        one block =
            let
                absmax =
                    List.foldl (\w m -> Basics.max m (Basics.abs w)) 0 block

                scale =
                    if absmax == 0 then
                        1

                    else
                        absmax
            in
            ( List.map (\w -> nearest (w / scale)) block, scale )

        quantized =
            List.map one (blocksOf weights)

        codes =
            List.concatMap Tuple.first quantized

        scales =
            List.map Tuple.second quantized
    in
    Encode.encode
        (Encode.sequence
            [ Host.packed (Host.encodeValues UI8 (List.map toFloat codes))
            , Host.packed (Host.encodeValues F32 scales)
            ]
        )


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


{-| The dense weight: each code's codebook value times its block's scale.
-}
dequantize : Quantized d i o -> Tensor Floating d (R2 i o)
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

        values =
            O.gather 0 (E.const F32 [ 16 ] codebook) (O.cast SI64 (O.flatten codes))

        byBlock =
            O.reshape [ nb, n // Basics.max 1 nb ] values

        scaled =
            O.mul byBlock (O.broadcastTo [ nb, n // Basics.max 1 nb ] (O.insertAxis 1 (O.cast F32 scales)))
    in
    I.Tensor (O.cast (E.dtype scales) (O.reshape s scaled))


{-| x @ W + the adapter's update, W dequantized.
-}
apply : Quantized d i o -> Lora d i r o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
apply q lora x =
    x |> T.matmul (dequantize q) |> T.plus (x |> T.matmul (Lora.delta lora))
