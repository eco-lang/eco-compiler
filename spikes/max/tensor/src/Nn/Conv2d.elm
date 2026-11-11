module Nn.Conv2d exposing (Conv2d, KernelH, KernelW, Padding, params, apply, applySame, applyTransposed)

{-| 2-D convolution on NHWC tensors, with filters (kernel h, kernel w, in, out) as MAX's RSCF.
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, R1, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| The kernel's spatial dimensions: tags owned by this module.
-}
type KernelH
    = KernelH


type KernelW
    = KernelW


type alias Conv2d d c o =
    { filter : Tensor Floating d (R4 KernelH KernelW c o), bias : Tensor Floating d (R1 o) }


type alias Padding =
    { top : Int, bottom : Int, left : Int, right : Int }


{-| He-uniform filters (fan-in kh × kw × c), zero biases.
-}
params : DType Floating d -> { kernel : ( Int, Int ) } -> Dim c -> Dim o -> Param.Spec (Conv2d d c o)
params dt cfg c o =
    Param.record Conv2d
        |> Param.heUniform .filter dt (T.r4 (T.dim KernelH (Tuple.first cfg.kernel)) (T.dim KernelW (Tuple.second cfg.kernel)) c o)
        |> Param.zeros .bias dt (T.r1 o)


convolve : ( Int, Int ) -> Padding -> Conv2d d c o -> Expr -> Expr
convolve ( sh, sw ) pad p x =
    let
        y =
            O.conv [ sh, sw, pad.top, pad.bottom, pad.left, pad.right ] x (I.tensor p.filter)

        b =
            I.tensor p.bias
    in
    O.add y (O.broadcastTo (E.shape y) b)


check : Dim h2 -> Dim w2 -> Expr -> Expr
check (I.Dim h2) (I.Dim w2) e =
    case E.shape e of
        [ _, h, w, _ ] ->
            if E.poisoned e || (h == h2 && w == w2) then
                e

            else
                E.failWith ("conv2d: the result is " ++ String.fromInt h ++ " × " ++ String.fromInt w ++ ", but its dimensions say " ++ String.fromInt h2 ++ " × " ++ String.fromInt w2) e

        _ ->
            e


{-| The output's spatial sizes are declared and checked when the graph is built.
-}
apply : { stride : ( Int, Int ), padding : Padding } -> Dim h2 -> Dim w2 -> Conv2d d c o -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 o)
apply cfg h2 w2 p x =
    I.Tensor (check h2 w2 (convolve cfg.stride cfg.padding p (I.tensor x)))


{-| Stride 1, padding that keeps the spatial size (odd kernels).
-}
applySame : Conv2d d c o -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h w o)
applySame p x =
    let
        ( kh, kw ) =
            case E.shape (I.tensor p.filter) of
                a :: b :: _ ->
                    ( a, b )

                _ ->
                    ( 1, 1 )

        e =
            convolve ( 1, 1 ) { top = (kh - 1) // 2, bottom = kh // 2, left = (kw - 1) // 2, right = kw // 2 } p (I.tensor x)
    in
    if modBy 2 kh == 0 || modBy 2 kw == 0 then
        I.Tensor (E.failWith "applySame needs an odd kernel" e)

    else
        I.Tensor e


{-| Transposed convolution with the same filter type as the convolution it inverts (no bias).
-}
applyTransposed : { stride : ( Int, Int ), padding : Padding } -> Dim h2 -> Dim w2 -> Conv2d d o c -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 o)
applyTransposed cfg h2 w2 p x =
    let
        ( sh, sw ) =
            cfg.stride

        pad =
            cfg.padding
    in
    I.Tensor (check h2 w2 (O.convTranspose [ sh, sw, pad.top, pad.bottom, pad.left, pad.right ] (I.tensor x) (I.tensor p.filter)))
