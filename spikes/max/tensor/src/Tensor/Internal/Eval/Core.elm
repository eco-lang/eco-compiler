module Tensor.Internal.Eval.Core exposing
    ( Data(..)
    , T
    , broadcastShapes
    , floatsOf
    , fromValues
    , getF
    , getI
    , intsOf
    , isWide
    , lanes
    , pick
    , size
    , split
    , strided
    , strides
    , withLanes
    , wrapInt
    )

{-| The evaluator runs tensor expressions in plain Elm. This module supplies the value its
primitives compute on, and index maps, which find for an element of a result the element of an
operand it is read from.

The value is `T`, a _run-time tensor_: a dtype, a shape, and the elements in one flat array in
row-major order, so that the last axis varies fastest. A position in that array is a _flat index_.
The elements are held in the Elm type of the dtype's kind, as `Tensor.Internal.Values` fixes it:
`Float`s for the floating-point dtypes, and `Int`s for the integer dtypes and for `bool`, whose
elements are 0 and 1. A `ui64` element follows the u64 convention described there.

Two facts about element values follow from that choice of Elm types. A float element is an Elm
`Float`, a 64-bit double, whatever its dtype: an `f16`, `bf16` or `f32` element has f64 precision
and range, and nothing in this module rounds it to its dtype. `wrapInt` brings an integer into the
range of its dtype as fixed-width two's complement arithmetic would. Under JavaScript an `Int` is a
double, which holds every integer only up to 2⁵³; arithmetic on `si64` and `ui64` elements
(`isWide`) is therefore left to `Tensor.Internal.Eval.U64`.

Most of the module is index arithmetic. A transpose, a slice, a broadcast or a padding computes no
new element: each element of the result is an element of the operand, or a fill value. Such an
operation is a map from the result's flat indices to the operand's, followed by `pick`, which reads
the operand at those indices. `strided` builds the map for any view that steps through the operand
a fixed distance per index along each axis (a _strided view_), with the distances from `strides`;
`split` builds the one for broadcasting.

An operation along one axis, such as a reduction or a cumulative sum, works lane by lane. A _lane_
is the elements along one axis at fixed indices on every other axis. `lanes` lists the lanes of a
shape, and `withLanes` lays values computed per lane back out as the elements of a tensor.

-}

import Array exposing (Array)
import Tensor.Internal.Eval.U64 as U64
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Values exposing (Values(..))


{-| The elements of a run-time tensor, in row-major order, in the Elm type of its dtype's kind.

`F` holds the elements of a floating-point dtype, each as a 64-bit `Float` whatever the dtype's
width.

`I` holds the elements of an integer dtype, `ui64` ones under the u64 convention, and those of
`bool`, as 0 and 1.

-}
type Data
    = F (Array Float)
    | I (Array Int)


{-| A run-time tensor: its dtype, its shape, and its elements.

A scalar has the shape `[]` and one element. Neither the type, `pick` nor `fromValues` checks that
`data` agrees with the other two fields: `pick` takes the length of its result from its list of
indices and the constructor from its source, whatever `shape` and `dt` say, and `fromValues` takes
the length from its values.

-}
type alias T =
    { dt : DT, shape : List Int, data : Data }


{-| Returns the number of elements in a tensor of the given shape: the product of its sizes, which
is 1 for the scalar shape `[]`.
-}
size : List Int -> Int
size =
    List.product


{-| Returns the row-major strides of `shape`: for each axis, the distance in the flat array between
two elements whose indices differ by one along that axis. For the shape `[d1, d2, …, dn]` they are
`[d2·…·dn, …, dn, 1]`.
-}
strides : List Int -> List Int
strides shape =
    List.foldr (\d ( acc, s ) -> ( s :: acc, s * d )) ( [], 1 ) shape |> Tuple.first


{-| Returns `n` brought into the range of `dt` as fixed-width two's complement arithmetic would
leave it: modulo 2⁸ into −128 … 127 for `si8` and into 0 … 255 for `ui8`, modulo 2³² into
−2³¹ … 2³¹ − 1 for `si32`, and modulo 2⁶⁴ into −2⁶³ … 2⁶³ − 1 for `si64` and `ui64` (a `ui64` value
from 2⁶³ up is held as a negative `Int`, under the u64 convention). For `bool` it returns 1 for
any non-zero `n`, and 0 for zero. Any other dtype gets `n` back unchanged.

The residue is taken from `n` itself, so the result is exact for any `n` that an `Int` holds
exactly. Natively every `Int` already lies in the `si64` range.

-}
wrapInt : DT -> Int -> Int
wrapInt dt n =
    case dt of
        SI8 ->
            signed 128 (modBy 256 n)

        UI8 ->
            modBy 256 n

        SI32 ->
            signed 2147483648 (modBy 4294967296 n)

        SI64 ->
            U64.wrap n

        UI64 ->
            U64.wrap n

        Bool ->
            if n /= 0 then
                1

            else
                0

        _ ->
            n


{-| Returns the residue `r`, in 0 … 2 · `half` − 1, read as two's complement: `r` − 2 · `half` from
`half` up, and `r` itself below it.
-}
signed : Int -> Int -> Int
signed half r =
    if r >= half then
        r - 2 * half

    else
        r


{-| Returns whether `dt` is `si64` or `ui64`: an integer dtype as wide as a native `Int`, whose
arithmetic needs `Tensor.Internal.Eval.U64` to be exact under JavaScript.
-}
isWide : DT -> Bool
isWide dt =
    dt == SI64 || dt == UI64


{-| Builds a run-time tensor of dtype `dt` and shape `shape` from element values, converting them
to the Elm type of the dtype's kind.

Values given as floats are kept as they are for a floating-point dtype; for an integer dtype or
`bool` they are rounded with `round` and then wrapped with `wrapInt`. Values given as integers are
converted with `toFloat` for a floating-point dtype, and otherwise wrapped with `wrapInt`.

-}
fromValues : DT -> List Int -> Values -> T
fromValues dt shape vs =
    case vs of
        FloatValues l ->
            if P.isFloat dt then
                { dt = dt, shape = shape, data = F (Array.fromList l) }

            else
                { dt = dt, shape = shape, data = I (Array.fromList (List.map (round >> wrapInt dt) l)) }

        IntValues l ->
            if P.isFloat dt then
                { dt = dt, shape = shape, data = F (Array.fromList (List.map toFloat l)) }

            else
                { dt = dt, shape = shape, data = I (Array.fromList (List.map (wrapInt dt) l)) }


{-| Returns the element of `a` at flat index `i`, or 0 when `i` is outside `a`.
-}
getF : Array Float -> Int -> Float
getF a i =
    Maybe.withDefault 0 (Array.get i a)


{-| Returns the element of `a` at flat index `i`, or 0 when `i` is outside `a`.
-}
getI : Array Int -> Int -> Int
getI a i =
    Maybe.withDefault 0 (Array.get i a)


{-| Returns the elements of `t` as floats.

Float elements are returned as they are. Integer elements are converted with `toFloat`, except
that a `ui64` element is read as unsigned, with `U64.toFloatU`, so one from 2⁶³ up gives a
positive float. Above 2⁵³ a `Float` cannot hold every integer, so a large integer element may be
rounded.

-}
floatsOf : T -> Array Float
floatsOf t =
    case t.data of
        F a ->
            a

        I a ->
            if t.dt == UI64 then
                Array.map U64.toFloatU a

            else
                Array.map toFloat a


{-| Returns the elements of `t` as integers.

Integer elements are returned as they are. Float elements are rounded with `round`, and the result
is neither wrapped to `t`'s dtype nor checked against it.

-}
intsOf : T -> Array Int
intsOf t =
    case t.data of
        I a ->
            a

        F a ->
            Array.map round a



-- INDEX MAPS


{-| Returns the operand's flat index read by the result's flat index `k0`, in a strided view.

`axes` describes the result, outermost axis first: each pair is the result's size along that axis
and the operand's stride for it. The flat index returned is `base` plus, for each axis, the index
of `k0` along that axis times its stride. A stride of 0 repeats one element of the operand along
the axis, as a broadcast does. The operand's own `strides` taken in another order give a
transpose, and taken in order with smaller sizes and a `base` offset give a slice.

-}
strided : Int -> List ( Int, Int ) -> Int -> Int
strided base axes k0 =
    List.foldr
        (\( d, st ) ( k, acc ) ->
            if d <= 1 then
                ( k, acc )

            else
                ( k // d, acc + modBy d k * st )
        )
        ( k0, base )
        axes
        |> Tuple.second


{-| Returns the shape that `a` and `b` broadcast to, in NumPy's way: the two are aligned at their
last axes, the shorter is given leading axes of size 1, and each axis takes the size that is not 1.

The shapes are not checked. Where the two sizes differ and neither is 1, `a`'s size is taken.

-}
broadcastShapes : List Int -> List Int -> List Int
broadcastShapes a b =
    let
        n =
            max (List.length a) (List.length b)

        pad l =
            List.repeat (n - List.length l) 1 ++ l
    in
    List.map2
        (\x y ->
            if x == 1 then
                y

            else
                x
        )
        (pad a)
        (pad b)


{-| Returns the map from a flat index of `outShape` to the flat index of `inShape` it reads, when
`inShape` is broadcast to `outShape`.

Where `inShape` has no more axes than `outShape`, the shapes are aligned at their last axes. Along
an axis that `inShape` lacks, or where its size is 1, the same element is read for every index of
`outShape`. Equal shapes give `identity`. The sizes are not checked: an axis of `inShape` whose
size is neither 1 nor `outShape`'s is stepped through with its own stride, as though the sizes
agreed.

-}
split : List Int -> List Int -> (Int -> Int)
split outShape inShape =
    if outShape == inShape then
        identity

    else
        let
            off =
                List.length outShape - List.length inShape

            inPadded =
                List.repeat off 1 ++ inShape

            st =
                List.repeat off 0 ++ strides inShape

            axes =
                List.map3
                    (\od idim s ->
                        if idim == 1 then
                            ( od, 0 )

                        else
                            ( od, s )
                    )
                    outShape
                    inPadded
                    st
        in
        strided 0 axes


{-| Builds a run-time tensor of dtype `dt` and shape `shape` whose elements are those of `d` at the
flat indices `indices`, in order.

A negative index stands for the fill value: `fillF` when `d` holds floats, `fillI` when it holds
integers. An index past the end of `d` reads 0. The result takes its data constructor from `d` and
its length from `indices`; neither is compared with `dt` or `shape`.

-}
pick : DT -> List Int -> List Int -> ( Float, Int ) -> Data -> T
pick dt shape indices ( fillF, fillI ) d =
    { dt = dt
    , shape = shape
    , data =
        case d of
            F a ->
                F
                    (Array.fromList
                        (List.map
                            (\i ->
                                if i < 0 then
                                    fillF

                                else
                                    getF a i
                            )
                            indices
                        )
                    )

            I a ->
                I
                    (Array.fromList
                        (List.map
                            (\i ->
                                if i < 0 then
                                    fillI

                                else
                                    getI a i
                            )
                            indices
                        )
                    )
    }



-- LANES


{-| Returns the flat indices of every lane of `shape` along `axis`.

Each lane lists its elements from index 0 along the axis upwards. The lanes are listed in the
row-major order of `shape` with `axis` removed, so the j-th lane belongs at flat index j of a
result that drops the axis.

-}
lanes : List Int -> Int -> List (List Int)
lanes shape axis =
    let
        outer =
            size (List.take axis shape)

        n =
            Maybe.withDefault 1 (List.head (List.drop axis shape))

        inner =
            size (List.drop (axis + 1) shape)
    in
    List.concatMap
        (\o -> List.map (\i -> List.map (\k -> (o * n + k) * inner + i) (List.range 0 (n - 1))) (List.range 0 (inner - 1)))
        (List.range 0 (outer - 1))


{-| Returns the row-major elements of `shape` with its size along `axis` replaced by `m`, taken
from `ls`, lanes of length `m` listed in the order `lanes` gives for `shape` and `axis`.

Only the sizes before and after `axis` are read from `shape`. A missing lane, or an element
missing from a lane shorter than `m`, is skipped rather than refused, so the result is then shorter
than the shape says.

-}
withLanes : List Int -> Int -> Int -> List (List a) -> List a
withLanes shape axis m ls =
    let
        outer =
            size (List.take axis shape)

        inner =
            size (List.drop (axis + 1) shape)

        rows =
            Array.fromList (List.map Array.fromList ls)
    in
    List.concatMap
        (\o ->
            List.concatMap
                (\j ->
                    List.filterMap
                        (\i -> Array.get (o * inner + i) rows |> Maybe.andThen (Array.get j))
                        (List.range 0 (inner - 1))
                )
                (List.range 0 (m - 1))
        )
        (List.range 0 (outer - 1))
