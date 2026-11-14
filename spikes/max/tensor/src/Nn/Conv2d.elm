module Nn.Conv2d exposing
    ( Conv2d, KernelH, KernelW, Padding
    , kernel, params
    , apply, applySame, applyTransposed
    )

{-| A 2-D convolution layer slides a small filter over an image and, at each position it stops at,
mixes the channels under the filter into new channels. This module provides that layer and its
transpose.

Images are NHWC: rank-4 tensors of (batch, height, width, channels). A filter is a rank-4 tensor of
(kernel height, kernel width, input channels, output channels), the layout MAX calls RSCF, where the
input and output channels are those of `apply`. A filter in another layout, such as PyTorch's OIHW
(output channels, input channels, kernel height, kernel width), must be permuted before it can be a
`Conv2d`'s. The kernel's two axes carry this module's tags, `KernelH` and `KernelW`.

The height and width of a convolution's result follow from the input's, the kernel's, the strides
and the padding, and no rank type can compute them. `apply` and `applyTransposed` therefore take
the result's height and width as `Dim`s, whose tags name the result's axes in its type, and compare
their sizes with the computed ones when the tensor is made, unless the result has already failed for
another reason. A mismatch is a build error, as `Tensor` describes; so is an input whose channels
differ in size from those the filter takes. `applySame` takes no `Dim`s, because its result has the
input's height and width.

Strides and padding are the only settings: there is no dilation.


# Types

@docs Conv2d, KernelH, KernelW, Padding


# Parameters

@docs kernel, params


# Applying

@docs apply, applySame, applyTransposed

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| The axis tag of a filter's first axis, the kernel's height.

Its constructor is not exposed, so a `Dim KernelH` comes from `kernel`.

-}
type KernelH
    = KernelH


{-| The axis tag of a filter's second axis, the kernel's width.

Its constructor is not exposed, so a `Dim KernelW` comes from `kernel`.

-}
type KernelW
    = KernelW


{-| Returns the kernel height and width `( kh, kw )` as dimensions with this module's tags, for
writing a filter's shape outside `params`: for example the shape of a filter in PyTorch's
(output, input, kh, kw) layout, before it is permuted into a `Conv2d`'s.
-}
kernel : ( Int, Int ) -> ( Dim KernelH, Dim KernelW )
kernel ( kh, kw ) =
    ( T.dim KernelH kh, T.dim KernelW kw )


{-| The parameters of a convolution layer, which `apply` uses to map `c` channels to `o`: a
`filter` of shape (kernel height, kernel width, `c`, `o`) and a `bias` with one value per output
channel.

`applyTransposed` does not read `bias`.

-}
type alias Conv2d d c o =
    { filter : Tensor Float d (R4 KernelH KernelW c o), bias : Tensor Float d (R1 o) }


{-| The rows of padding above and below an image and the columns to its left and right.

`apply` pads its input with them; `applyTransposed` removes them from its result.

-}
type alias Padding =
    { top : Int, bottom : Int, left : Int, right : Int }


{-| Describes a `Conv2d` from `c` channels to `o` with a `kh × kw` kernel, given as
`kernel = ( kh, kw )`. It has two trainable fields: first the filter, drawn as `Param.heUniform`
describes for the shape (kh, kw, `c`, `o`), and then the bias, all zeros.
-}
params : DType Float d -> { kernel : ( Int, Int ) } -> Dim c -> Dim o -> Param.Spec (Conv2d d c o)
params dt cfg c o =
    Param.record Conv2d
        |> Param.heUniform .filter dt (T.r4 (T.dim KernelH (Tuple.first cfg.kernel)) (T.dim KernelW (Tuple.second cfg.kernel)) c o)
        |> Param.zeros .bias dt (T.r1 o)


{-| Returns the convolution of `x` by `p`'s filter with strides `( sh, sw )` and padding `pad`,
with `p`'s bias added to every output channel at every batch entry and position.
-}
convolve : ( Int, Int ) -> Padding -> Conv2d d c o -> Expr -> Expr
convolve ( sh, sw ) pad p x =
    let
        y =
            O.conv [ sh, sw, pad.top, pad.bottom, pad.left, pad.right ] x (I.tensor p.filter)

        b =
            I.tensor p.bias
    in
    O.add y (O.broadcastTo (E.shape y) b)


{-| Returns `e`, failed with a build error when its height and width are not those of `h2` and
`w2`. A poisoned `e` is returned unchanged, so the check adds no message to a result that has
already failed. An `e` whose shape is not of rank 4 is also returned unchanged.
-}
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


{-| Applies the layer `p` to the NHWC input `x` with the given `stride` (rows, columns) and
`padding`, adding the bias to every output channel, and declares the result's height and width to
be the sizes of `h2` and `w2`.

For an input of height h and width w, a kernel of kh × kw and strides (sh, sw), the result has
(h + top + bottom − kh) // sh + 1 rows and (w + left + right − kw) // sw + 1 columns, the divisions
rounding down. A stride of 0 or less is a build error, and so is a kernel taller or wider than the
padded input (kh > h + top + bottom, or kw > w + left + right), so the result has at least one row
and one column. Unless the result has already failed, an `h2` or `w2` whose size differs from the
computed one is also a build error.

-}
apply : { stride : ( Int, Int ), padding : Padding } -> Dim h2 -> Dim w2 -> Conv2d d c o -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h2 w2 o)
apply cfg h2 w2 p x =
    I.Tensor (check h2 w2 (convolve cfg.stride cfg.padding p (I.tensor x)))


{-| Applies the layer `p` to `x` with stride 1 and the padding that keeps the input's height and
width: (k − 1) / 2 rows or columns on each side for a kernel side of k. The bias is added to every
output channel.

The kernel's height and width must both be odd; an even one is a build error.

-}
applySame : Conv2d d c o -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h w o)
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


{-| Applies the transposed convolution of `p`'s filter to `x`, with the given `stride` and
`padding`, and declares the result's height and width to be the sizes of `h2` and `w2`. The bias of
`p` is not used.

This is the transpose of the convolution `apply` makes with the same filter, strides and padding,
leaving out the bias. A `Conv2d d o c`, which `apply` uses to map `o` channels to `c`, here maps `c`
channels to `o`, and the padding is removed from the result instead of added to the input.

For an input of height h and width w, a kernel of kh × kw and strides (sh, sw), the result has
(h − 1) · sh + kh − top − bottom rows and (w − 1) · sw + kw − left − right columns. A stride of 0
or less is a build error, and so is a computed size of zero or less. Unless the result has already
failed, an `h2` or `w2` whose size differs from the computed one is a build error.

-}
applyTransposed : { stride : ( Int, Int ), padding : Padding } -> Dim h2 -> Dim w2 -> Conv2d d o c -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h2 w2 o)
applyTransposed cfg h2 w2 p x =
    let
        ( sh, sw ) =
            cfg.stride

        pad =
            cfg.padding
    in
    I.Tensor (check h2 w2 (O.convTranspose [ sh, sw, pad.top, pad.bottom, pad.left, pad.right ] (I.tensor x) (I.tensor p.filter)))
