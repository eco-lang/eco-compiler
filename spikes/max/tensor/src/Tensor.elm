module Tensor exposing
    ( Tensor, Mask, Dim, Shape, DType, Axis, Retag, Lift, Perm
    , R0, R1, R2, R3, R4, R5, One, Elems
    , F16, BF16, F32, F64, I8, I32, I64, U8, U64, float16, bfloat16, float32, float64, int8, int32, int64, uint8, uint64
    , dim, one, size, scalar, r1, r2, r3, r4, r5, shapeOf, dtypeName
    , float, int, constant, fillLike, zeros, ones, full, fromList, zerosLike, onesLike, fullLike, fullLikeInt, iota, arange, hannWindow
    , cast, castLike, toFloat, toInt
    , abs, negate, sign, exp, log, log1p, sqrt, rsqrt, sin, cos, acos, atanh, erf, floor, round, truncate
    , relu, sigmoid, tanh, gelu, geluTanh, silu, quickGelu, isInfinite, isNaN
    , plus, minus, times, dividedBy, modBy, pow, max, min, scale, shift
    , equals, notEquals, greaterThan, atLeast, lessThan, atMost, and, or, xor, not, select, indicator, maskBroadcast
    , matmul, matmul3, matmul4, matmul3By2, vecMat, matVec, dot, outer
    , sum, mean, maximum, minimum, argMax, argMin, cumsum, cumsumWith, logSumExp, topK, bottomK, sort, sumAll, meanAll, maximumAll, minimumAll, minMax
    , softmax, logSoftmax
    , reshape, flatten, flattenTail3, flattenTail4, factorLast2, factorLast3, factorLast4, mergeLast2, mergeLast3, mergeLast4
    , transpose, permute, broadcast, broadcastTo, rows, columns, insertOne, dropOne
    , slice, sliceUpdate, concat, concat2, chunks, stack, unstack, flip, pad, padInt
    , take, rowsAt, pick, put, putAdd, triu, tril, lowerTriangle
    , stopGradient
    )

{-| Tensors are what a computation in this package is written with, and this module defines the
`Tensor` type, the types that go with it, and operations that make a new tensor from others.

A tensor is a description of a computation, not its elements. Making one works out its shape and
dtype, but computes no element values. Those are computed only when the tensor is run: by MAX,
given a `Graph` that `Max` writes out, or in plain Elm by `Tensor.Eval`, which runs a `Graph`,
or a tensor that reads no graph input.

A tensor's type, `Tensor kind dtype shape`, has three parameters. The _kind_ is the Elm type of its
elements, `Float` or `Int`. The dtype is a tag such as `F32` or `I64`. The shape is a _rank type_,
`R0` to `R5`, or the `Elems` described under Shapes. A rank type fixes the number of axes and gives
each a tag: `Tensor Float F32 (R2 Batch Hidden)` is a matrix of `f32` elements whose outer axis is
tagged `Batch`. An _axis tag_ is a type the user declares, such as `type Batch = Batch`, and names
an axis without giving its size. Mixing up axes, ranks, kinds or dtypes is therefore a compile
error, but sizes are not in the types: two `Dim Batch` values may hold different sizes.

Sizes are checked when each tensor is made instead. An operation that finds its operands do not fit,
in size or otherwise, still gives a tensor, but one carrying a _build error_: a message saying what
did not fit. Tensors built on it are marked as failed too. `Graph.build` can report build errors of
the tensors its outputs depend on, and `Tensor.Eval.floats`, `ints` and `mask` return those of the
tensor they are given. Index values are not checked this way: an index outside its axis, given to
`take`, `rowsAt`, `put` or `putAdd`, is not a build error, and `Tensor.Eval` refuses it when it
runs; `pick` gives 0 for one in a row of finite values.

An element-wise operation does no implicit broadcasting. Its operands must have one shape, except
that a scalar is spread over the other operand; an axis of size 1 is not stretched to match a
larger one. To add a vector to every row of a matrix, a _broadcast axis_ is made for the rows:
`broadcast`, `rows`, `columns` and `maskBroadcast` add an axis of size 1 whose size is not known
yet, and the next element-wise operation gives it its partner's size there, unless the partner is a
scalar or has a broadcast axis there too, when it stays a broadcast axis. A broadcast axis passes
unchanged through the element-wise functions of one tensor, and through
`transpose` and `permute`; `insertOne`, `dropOne` and the functions that make broadcast axes keep
those already there; and `matmul3` and `matmul4` treat one on a batch axis as an element-wise
operation does. Most other operations refuse a tensor with one, with a build error, and so does
`Graph.build` for an output that still has one. `shapeOf` reports a broadcast axis as 1, and the
constructors that copy another tensor's shape, such as `zerosLike`, make a real axis of size 1
there.

Functions take the tensor they act on last, so that a pipeline reads left to right. For a function
of two tensors that puts the second operand first: `x |> minus y` is x − y, and so is `minus y x`.
This holds for the arithmetic, the comparisons, `and`, `or` and `xor`, and the products, where
`x |> matmul w` is x @ w. `select` and `concat2` take their operands in reading order instead.


# Types

@docs Tensor, Mask, Dim, Shape, DType, Axis, Retag, Lift, Perm


# Shapes

`One` is the tag that `one` and `insertOne` give a real axis of size 1, and `Elems` stands for a
shape that may be any.

@docs R0, R1, R2, R3, R4, R5, One, Elems


# Dtypes

A tensor's kind is fixed by its dtype: `Float` for the floating-point dtypes
(`Tensor Float F32 s`) and `Int` for the integer ones (`Tensor Int I64 s`). The values given to
`int`, `constant`, `full`, `fromList`, `fullLikeInt` and `padInt` have that type, so an integer
given to them is kept as an `Int` and never converted to `Float`. In native code, where an `Int`
has 64 bits, every 64-bit value is therefore exact; under JavaScript an `Int` holds every integer
exactly only up to 2⁵³. An integer that `int8`, `int32` or `uint8` cannot hold, such as 300 for
`uint8`, is a build error; `int64` and `uint64` accept every `Int`.

A `uint64` element is the `Int` with the same 64 bits, so 2⁶³ … 2⁶⁴ − 1 are given and read as
negative `Int`s: `fromList uint64 (r1 n) [ -1 ]` holds 2⁶⁴ − 1.

@docs F16, BF16, F32, F64, I8, I32, I64, U8, U64, float16, bfloat16, float32, float64, int8, int32, int64, uint8, uint64


# Dimensions and shapes

@docs dim, one, size, scalar, r1, r2, r3, r4, r5, shapeOf, dtypeName


# Construction

@docs float, int, constant, fillLike, zeros, ones, full, fromList, zerosLike, onesLike, fullLike, fullLikeInt, iota, arange, hannWindow


# Casts

@docs cast, castLike, toFloat, toInt


# Element-wise functions

@docs abs, negate, sign, exp, log, log1p, sqrt, rsqrt, sin, cos, acos, atanh, erf, floor, round, truncate


# Activations

@docs relu, sigmoid, tanh, gelu, geluTanh, silu, quickGelu, isInfinite, isNaN


# Arithmetic

@docs plus, minus, times, dividedBy, modBy, pow, max, min, scale, shift


# Comparisons and masks

The comparisons work element by element and give a mask. In `Tensor.Eval` a comparison with a NaN
on either side is false, `notEquals` included.

@docs equals, notEquals, greaterThan, atLeast, lessThan, atMost, and, or, xor, not, select, indicator, maskBroadcast


# Linear algebra

@docs matmul, matmul3, matmul4, matmul3By2, vecMat, matVec, dot, outer


# Reductions

`sum`, `mean`, `maximum`, `minimum`, `argMax`, `argMin` and `logSumExp` take an `Axis` naming the
axis they reduce, and their result has that axis removed: `x |> sum Axis.axis1of2` sums each row of
a matrix. The functions ending in `All` reduce every element to a scalar.

@docs sum, mean, maximum, minimum, argMax, argMin, cumsum, cumsumWith, logSumExp, topK, bottomK, sort, sumAll, meanAll, maximumAll, minimumAll, minMax


# Softmax

@docs softmax, logSoftmax


# Reshaping

@docs reshape, flatten, flattenTail3, flattenTail4, factorLast2, factorLast3, factorLast4, mergeLast2, mergeLast3, mergeLast4


# Axes

@docs transpose, permute, broadcast, broadcastTo, rows, columns, insertOne, dropOne


# Slicing and joining

@docs slice, sliceUpdate, concat, concat2, chunks, stack, unstack, flip, pad, padInt


# Indexing

@docs take, rowsAt, pick, put, putAdd, triu, tril, lowerTriangle


# Gradients

@docs stopGradient

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))
import Tensor.Internal.Shape as Shape
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values



-- TYPES


{-| A tensor: a description of a computation whose result has elements of the Elm type `e`
(`Float` or `Int`), the dtype `dtype` (`F32`, `I64` ..) and a shape typed by `shape`
(`R2 Batch Hidden`).

Making a tensor computes no elements, as the module documentation describes.

-}
type alias Tensor e dtype shape =
    I.Tensor e dtype shape


{-| A tensor of booleans, with a shape type but no kind or dtype parameter. The comparisons,
`isInfinite` and `isNaN` make one, and `select`, `and`, `or`, `xor` and `not` take one; `indicator`
turns one into numbers.
-}
type alias Mask shape =
    I.Mask shape


{-| The size of one axis, typed by the axis's tag: `dim Hidden 128 : Dim Hidden`.

The size is a value, not part of the type, so two `Dim Hidden`s may hold different sizes, and
nothing requires a size to be positive. Sizes are compared when tensors are made.

-}
type alias Dim tag =
    I.Dim tag


{-| The sizes of a tensor's axes, typed by a rank type and so by the number of axes and their tags:
`r2 batch hidden : Shape (R2 Batch Hidden)`. `scalar` and `r1` .. `r5` make one.
-}
type alias Shape s =
    I.Shape s


{-| An element type, typed by the Elm type of its elements and its dtype tag:
`float32 : DType Float F32`, `int64 : DType Int I64`. The values are `float16` .. `uint64`; there is
none for masks.
-}
type alias DType e dtype =
    I.DType e dtype


{-| One axis, named by its position and typed by the shape with the axis (`s`), the shape without it
(`r`) and the axis's tag (`c`).

The same value serves an operation that removes the axis, reading it as going from `s` to `r`
(`sum`, `argMax` and the other reductions), and one that inserts it, reading it backwards from `r`
to `s` (`broadcast`, `broadcastTo`, `insertOne`, `maskBroadcast`). Operations that keep the axis,
such as `softmax`, `cumsum`, `flip` and `sort`, use only its position. Values come from the
generated `Tensor.Axis`, such as `Axis.axis1of2` and `Axis.last2`.

-}
type alias Axis s r c =
    I.Axis s r c


{-| One axis that an operation keeps in place but may resize, typed by two shapes that are the same
apart from that axis (`s` and `t`) and the axis's tag in each (`a` in `s`, `c` in `t`). `slice`,
`concat`, `pad`, `take` and `topK` take one, with a `Dim c` for the new size where they need it.
Values come from the generated `Tensor.Axis` (`Axis.retag1of2`).
-}
type alias Retag s t a c =
    I.Retag s t a c


{-| A statement that shape `t` is shape `s` with a leading axis tagged `n` added in front. It names
no axis and holds nothing else: `stack` and `unstack` take one for its type alone. Values come from
the generated `Tensor.Axis` (`Axis.liftRank1`).
-}
type alias Lift n s t =
    I.Lift n s t


{-| A reordering of the axes of shape `s` into shape `t`, made of swaps of two axes, as
`Tensor.Axis.swap01of2` and the like make and `Tensor.Axis.andThen` joins.
-}
type alias Perm s t =
    I.Perm s t


{-| The rank type of a scalar, which has no axes.
-}
type alias R0 =
    I.R0


{-| The rank type of a vector, whose one axis is tagged `a`.
-}
type alias R1 a =
    I.R1 a


{-| The rank type of a matrix, whose axes are tagged `a` and `b`, outermost first.
-}
type alias R2 a b =
    I.R2 a b


{-| The rank type of a shape with three axes, tagged outermost first.
-}
type alias R3 a b c =
    I.R3 a b c


{-| The rank type of a shape with four axes, tagged outermost first.
-}
type alias R4 a b c d =
    I.R4 a b c d


{-| The rank type of a shape with five axes, tagged outermost first.
-}
type alias R5 a b c d e =
    I.R5 a b c d e


{-| The axis tag of a real axis of size 1, as `one` and `insertOne` make and `dropOne` removes.

The tag does not make an axis real: `broadcast`, `rows` and `columns` leave the tag of their new
axis free, so a broadcast axis may be tagged `One` too.

-}
type alias One =
    I.One


{-| A shape parameter standing for whatever shape a tensor has, so that one function can be applied
to every tensor of a model (`Optim.custom`, `Param.mapElems`). It is not a rank type, so only the
functions here that accept a tensor of any shape accept one typed with it.
-}
type alias Elems =
    I.Elems


{-| The dtype tag of `float16`: IEEE half precision.
-}
type alias F16 =
    I.F16


{-| The dtype tag of `bfloat16`: a 16-bit float with `f32`'s exponent range.
-}
type alias BF16 =
    I.BF16


{-| The dtype tag of `float32`: IEEE single precision.
-}
type alias F32 =
    I.F32


{-| The dtype tag of `float64`: IEEE double precision.
-}
type alias F64 =
    I.F64


{-| The dtype tag of `int8`: signed 8-bit integers.
-}
type alias I8 =
    I.I8


{-| The dtype tag of `int32`: signed 32-bit integers.
-}
type alias I32 =
    I.I32


{-| The dtype tag of `int64`: signed 64-bit integers.
-}
type alias I64 =
    I.I64


{-| The dtype tag of `uint8`: unsigned 8-bit integers.
-}
type alias U8 =
    I.U8


{-| The dtype tag of `uint64`: unsigned 64-bit integers.
-}
type alias U64 =
    I.U64


{-| Returns the tensor that `e` stands for, typed as the caller's signature says. Nothing compares
the type with `e`'s own shape and dtype, so each function here must give the type that fits.
-}
wrap : Expr -> Tensor k d s
wrap =
    I.Tensor


{-| Returns the expression a tensor stands for.
-}
un : Tensor k d s -> Expr
un =
    I.tensor


{-| Returns the tensor whose expression is `f` applied to `x`'s, typed as the caller's signature
says.
-}
map1 : (Expr -> Expr) -> Tensor k d s -> Tensor k2 d2 t
map1 f x =
    wrap (f (un x))


{-| Returns the mask that `e` stands for.
-}
mask : Expr -> Mask s
mask =
    I.Mask



-- DTYPES


{-| The dtype `f16`, of `Float` elements.
-}
float16 : DType Float F16
float16 =
    I.DType F16 Values.FloatValues


{-| The dtype `bf16`, of `Float` elements.
-}
bfloat16 : DType Float BF16
bfloat16 =
    I.DType BF16 Values.FloatValues


{-| The dtype `f32`, of `Float` elements.
-}
float32 : DType Float F32
float32 =
    I.DType F32 Values.FloatValues


{-| The dtype `f64`, of `Float` elements.
-}
float64 : DType Float F64
float64 =
    I.DType F64 Values.FloatValues


{-| The dtype `si8`, of `Int` elements from −128 to 127.
-}
int8 : DType Int I8
int8 =
    I.DType SI8 Values.IntValues


{-| The dtype `si32`, of `Int` elements from −2³¹ to 2³¹ − 1.
-}
int32 : DType Int I32
int32 =
    I.DType SI32 Values.IntValues


{-| The dtype `si64`, of signed 64-bit `Int` elements.
-}
int64 : DType Int I64
int64 =
    I.DType SI64 Values.IntValues


{-| The dtype `ui8`, of `Int` elements from 0 to 255.
-}
uint8 : DType Int U8
uint8 =
    I.DType UI8 Values.IntValues


{-| The dtype `ui64`, of unsigned 64-bit elements, each given as the `Int` with the same 64 bits.
-}
uint64 : DType Int U64
uint64 =
    I.DType UI64 Values.IntValues


{-| Returns the dtype a `DType` stands for.
-}
dt : DType k d -> DT
dt =
    I.dtOf


{-| Returns `vs` as the element values of a constant of the dtype `d`: `FloatValues` for a
floating-point dtype and `IntValues` for an integer one, as the dtype values above choose.
-}
conv : DType k d -> List k -> Values.Values
conv =
    I.valuesOf



-- DIMENSIONS AND SHAPES


{-| Returns a dimension of size `n` for the axis tag whose constructor is given:
`hidden = dim Hidden 128`. The constructor is used only for its type, and any `Int` is accepted as
the size, zero and negative included.
-}
dim : tag -> Int -> Dim tag
dim _ n =
    I.Dim n


{-| The dimension of a real axis of size 1, tagged `One`, such as a grey image's channel axis.
-}
one : Dim One
one =
    I.Dim 1


{-| Returns the size a dimension holds.
-}
size : Dim tag -> Int
size (I.Dim n) =
    n


{-| The shape of a scalar, which has no axes.
-}
scalar : Shape R0
scalar =
    I.Shape []


{-| Returns the vector shape of one dimension: `r1 hidden`.
-}
r1 : Dim a -> Shape (R1 a)
r1 (I.Dim a) =
    I.Shape [ a ]


{-| Returns the matrix shape of two dimensions, outermost first: `r2 batch hidden`.
-}
r2 : Dim a -> Dim b -> Shape (R2 a b)
r2 (I.Dim a) (I.Dim b) =
    I.Shape [ a, b ]


{-| Returns the shape of three dimensions, outermost first.
-}
r3 : Dim a -> Dim b -> Dim c -> Shape (R3 a b c)
r3 (I.Dim a) (I.Dim b) (I.Dim c) =
    I.Shape [ a, b, c ]


{-| Returns the shape of four dimensions, outermost first.
-}
r4 : Dim a -> Dim b -> Dim c -> Dim d -> Shape (R4 a b c d)
r4 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) =
    I.Shape [ a, b, c, d ]


{-| Returns the shape of five dimensions, outermost first.
-}
r5 : Dim a -> Dim b -> Dim c -> Dim d -> Dim e -> Shape (R5 a b c d e)
r5 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) (I.Dim e) =
    I.Shape [ a, b, c, d, e ]


{-| Returns the sizes of `x`'s axes, outermost first, as they were worked out when `x` was made. A
broadcast axis is reported as 1. For a tensor with a build error the sizes may be a stand-in, such
as its first operand's.
-}
shapeOf : Tensor k d s -> List Int
shapeOf x =
    E.shape (un x)


{-| Returns the name of `x`'s dtype, such as `"f32"`, `"bf16"`, `"si64"` or `"ui8"`: a signed
integer dtype's name starts `si` and an unsigned one's `ui`, unlike the names `int64` and `I64`. For
a tensor with a build error the dtype may be a stand-in, as for `shapeOf`.
-}
dtypeName : Tensor k d s -> String
dtypeName x =
    P.dtName (E.dtype (un x))



-- CONSTRUCTION


{-| Returns the `f32` scalar `f`.
-}
float : Float -> Tensor Float F32 R0
float f =
    wrap (E.scalar F32 f)


{-| Returns the `int64` scalar `n`, kept as an `Int` rather than converted to `Float`.
-}
int : Int -> Tensor Int I64 R0
int n =
    wrap (E.constValues SI64 [] (Values.IntValues [ n ]))


{-| Returns the scalar `v` of the dtype `d`, given in the dtype's kind: `constant bfloat16 0.5`,
`constant uint8 200`. An integer that the dtype cannot hold, such as 300 for `uint8`, is a build
error.
-}
constant : DType e d -> e -> Tensor e d R0
constant d v =
    wrap (E.constValues (dt d) [] (conv d [ v ]))


{-| Returns a tensor of `x`'s shape whose every element is the scalar `c`, which may be any scalar
tensor, not only a constant: `fillLike rate grad`. A broadcast axis of `x` is a real axis of size 1
in the result. The values of `x` are not read, but an `x` that failed to build fails the result
with its build error.
-}
fillLike : Tensor k d R0 -> Tensor k d s -> Tensor k d s
fillLike c x =
    wrap (O.broadcastTo (E.shape (un x)) (un c) |> E.inherit (un x))


{-| Returns a tensor of the dtype `d` and the shape `s` whose every element is `v`:
`full float32 0.5 (r2 batch hidden)`, `full int64 7 (r1 n)`. An integer that the dtype cannot hold
is a build error, as for `constant`.
-}
full : DType e d -> e -> Shape s -> Tensor e d s
full d v (I.Shape s) =
    wrap (O.broadcastTo s (E.constValues (dt d) [] (conv d [ v ])))


{-| Returns a tensor of the dtype and shape given whose every element is 0.
-}
zeros : DType e d -> Shape s -> Tensor e d s
zeros d (I.Shape s) =
    wrap (O.broadcastTo s (E.scalar (dt d) 0))


{-| Returns a tensor of the dtype and shape given whose every element is 1.
-}
ones : DType e d -> Shape s -> Tensor e d s
ones d (I.Shape s) =
    wrap (O.broadcastTo s (E.scalar (dt d) 1))


{-| Returns the tensor of the dtype `d` and the shape `s` holding `values` in row-major order:
`fromList float32 (r1 three) [ 1, 2.5, 4 ]`, `fromList int64 (r1 two) [ 7, -3 ]`. A number of values
other than the number of elements of `s` is a build error, and so is an integer that the dtype
cannot hold.
-}
fromList : DType e d -> Shape s -> List e -> Tensor e d s
fromList d (I.Shape s) values =
    wrap (E.constValues (dt d) s (conv d values))


{-| Returns a tensor of `x`'s dtype and shape whose every element is 0. A broadcast axis of `x` is a
real axis of size 1 in the result. The values of `x` are not read, but an `x` that failed to build
fails the result with its build error.
-}
zerosLike : Tensor k d s -> Tensor k d s
zerosLike =
    map1 O.zerosLike


{-| Returns a tensor of `x`'s dtype and shape whose every element is 1. A broadcast axis of `x` is a
real axis of size 1 in the result. An `x` that failed to build fails the result with its build
error, as for `zerosLike`.
-}
onesLike : Tensor k d s -> Tensor k d s
onesLike =
    map1 O.onesLike


{-| Returns a tensor of the floating-point `x`'s dtype and shape whose every element is `v`. A
broadcast axis of `x` is a real axis of size 1 in the result. An `x` that failed to build fails the
result with its build error, as for `zerosLike`.
-}
fullLike : Float -> Tensor Float d s -> Tensor Float d s
fullLike v =
    map1 (O.fullLike v)


{-| Returns a tensor of the integer `x`'s dtype and shape whose every element is `v`, kept as an
`Int`. A `v` that the dtype cannot hold is a build error. A broadcast axis of `x` is a real axis of
size 1 in the result. An `x` that failed to build fails the result with its build error, as for
`zerosLike`.
-}
fullLikeInt : Int -> Tensor Int d s -> Tensor Int d s
fullLikeInt v =
    map1 (O.fullLikeValues (Values.IntValues [ v ]))


{-| Returns the `int64` vector 0, 1, … , n − 1, where n is the size of `n`.
-}
iota : Dim n -> Tensor Int I64 (R1 n)
iota (I.Dim n) =
    wrap (O.range 0 1 n)


{-| Returns the `int64` vector `start`, `start + step`, `start + 2 * step`, … with as many elements as
the size of `n`.
-}
arange : { start : Int, step : Int } -> Dim n -> Tensor Int I64 (R1 n)
arange r (I.Dim n) =
    wrap (O.range r.start r.step n)


{-| Returns the Hann window of n points in the dtype `d`, n being the size of `n`: element i is
½ − ½ cos (2π i / N), where N is n when `periodic` and the larger of n − 1 and 1 otherwise.
-}
hannWindow : { periodic : Bool } -> DType Float d -> Dim n -> Tensor Float d (R1 n)
hannWindow cfg d (I.Dim n) =
    let
        big =
            if cfg.periodic then
                n

            else
                Basics.max 1 (n - 1)

        i =
            O.cast (dt d) (O.range 0 1 n)

        angle =
            O.mul i (O.scalarLike (2 * pi / Basics.toFloat big) i)

        c =
            O.unary Cos angle
    in
    wrap (O.sub (O.scalarLike 0.5 c) (O.mul (O.scalarLike 0.5 c) c))



-- CASTS


{-| Returns `x` with each element converted to the dtype `d`.
-}
cast : DType k d -> Tensor k0 d0 s -> Tensor k d s
cast d =
    map1 (O.cast (dt d))


{-| Returns `x` with each element converted to the dtype of `y`, whose values are not used:
`x |> castLike y`. A `y` that failed to build fails the result with its build error.
-}
castLike : Tensor k d t -> Tensor k0 d0 s -> Tensor k d s
castLike t =
    map1 (O.cast (E.dtype (un t)) >> E.inherit (un t))


{-| Returns `x` with each element converted to `f32`.
-}
toFloat : Tensor k d s -> Tensor Float F32 s
toFloat =
    map1 (O.cast F32)


{-| Returns `x` with each element converted to `si64`.
-}
toInt : Tensor k d s -> Tensor Int I64 s
toInt =
    map1 (O.cast SI64)



-- ELEMENT-WISE


{-| Returns the absolute value of each element.
-}
abs : Tensor k d s -> Tensor k d s
abs =
    map1 (O.unary Abs)


{-| Returns each element negated. For `uint8` and `uint64` tensors it is a build error, because the
package's record of what MAX compiles lists it as refused for them.
-}
negate : Tensor k d s -> Tensor k d s
negate =
    map1 O.neg


{-| Returns −1, 0 or 1, in `x`'s dtype, for each element that is negative, zero or positive. A NaN
gives 0, being neither greater nor less than zero.

The result is chosen between constants of `x`'s shape, so a broadcast axis of `x` is a real axis of
size 1 in it.

-}
sign : Tensor k d s -> Tensor k d s
sign =
    map1 O.sign


{-| Returns e raised to each element.
-}
exp : Tensor Float d s -> Tensor Float d s
exp =
    map1 (O.unary Exp)


{-| Returns the natural logarithm of each element.
-}
log : Tensor Float d s -> Tensor Float d s
log =
    map1 (O.unary Log)


{-| Returns log (1 + x) of each element x.
-}
log1p : Tensor Float d s -> Tensor Float d s
log1p =
    map1 (O.unary Log1p)


{-| Returns the square root of each element.
-}
sqrt : Tensor Float d s -> Tensor Float d s
sqrt =
    map1 (O.unary Sqrt)


{-| Returns 1 / sqrt x of each element x.
-}
rsqrt : Tensor Float d s -> Tensor Float d s
rsqrt =
    map1 (O.unary Rsqrt)


{-| Returns the sine of each element, in radians.
-}
sin : Tensor Float d s -> Tensor Float d s
sin =
    map1 (O.unary Sin)


{-| Returns the cosine of each element, in radians.
-}
cos : Tensor Float d s -> Tensor Float d s
cos =
    map1 (O.unary Cos)


{-| Returns the arc cosine of each element.
-}
acos : Tensor Float d s -> Tensor Float d s
acos =
    map1 (O.unary Acos)


{-| Returns the inverse hyperbolic tangent of each element.
-}
atanh : Tensor Float d s -> Tensor Float d s
atanh =
    map1 (O.unary Atanh)


{-| Returns the error function of each element.
-}
erf : Tensor Float d s -> Tensor Float d s
erf =
    map1 (O.unary Erf)


{-| Returns each element rounded down to a whole number.
-}
floor : Tensor Float d s -> Tensor Float d s
floor =
    map1 (O.unary Floor)


{-| Returns each element rounded to the nearest whole number. In `Tensor.Eval` a value halfway
between two goes to the even one.
-}
round : Tensor Float d s -> Tensor Float d s
round =
    map1 (O.unary Round)


{-| Returns each element rounded towards zero to a whole number.
-}
truncate : Tensor Float d s -> Tensor Float d s
truncate =
    map1 (O.unary Trunc)


{-| Returns each element, or 0 where it is below 0.
-}
relu : Tensor k d s -> Tensor k d s
relu =
    map1 (O.unary Relu)


{-| Returns 1 / (1 + e⁻ˣ) of each element x.
-}
sigmoid : Tensor Float d s -> Tensor Float d s
sigmoid =
    map1 (O.unary Sigmoid)


{-| Returns the hyperbolic tangent of each element.
-}
tanh : Tensor Float d s -> Tensor Float d s
tanh =
    map1 (O.unary Tanh)


{-| Returns x · Φ(x) of each element x, Φ being the standard normal distribution function: the
erf form of GELU.
-}
gelu : Tensor Float d s -> Tensor Float d s
gelu =
    map1 (O.unary Gelu)


{-| Returns the GELU of each element by its tanh approximation.
-}
geluTanh : Tensor Float d s -> Tensor Float d s
geluTanh =
    map1 (O.unary GeluTanh)


{-| Returns x · sigmoid x of each element x, also called swish.
-}
silu : Tensor Float d s -> Tensor Float d s
silu =
    map1 (O.unary Silu)


{-| Returns the mask of where `x` is +∞ or −∞.
-}
isInfinite : Tensor Float d s -> Mask s
isInfinite x =
    mask (O.unary IsInf (un x))


{-| Returns the mask of where `x` is NaN.
-}
isNaN : Tensor Float d s -> Mask s
isNaN x =
    mask (O.unary IsNaN (un x))


{-| Returns the tensor whose expression is `f` applied to `x`'s and `y`'s, in that order, where `y`
is given first: the argument order that makes a pipeline `x |> op y` read as `x op y`.
-}
map2 : (Expr -> Expr -> Expr) -> Tensor k d s -> Tensor k d s -> Tensor k d s
map2 f y x =
    wrap (f (un x) (un y))


{-| Returns x + y, element by element: `x |> plus y`.
-}
plus : Tensor k d s -> Tensor k d s -> Tensor k d s
plus =
    map2 O.add


{-| Returns x − y, element by element: `x |> minus y`.
-}
minus : Tensor k d s -> Tensor k d s -> Tensor k d s
minus =
    map2 O.sub


{-| Returns x · y, element by element: `x |> times y`.
-}
times : Tensor k d s -> Tensor k d s -> Tensor k d s
times =
    map2 O.mul


{-| Returns x / y, element by element: `x |> dividedBy y`.
-}
dividedBy : Tensor Float d s -> Tensor Float d s -> Tensor Float d s
dividedBy =
    map2 O.div


{-| Returns the remainder of each element of `x` divided by the matching element of `m`:
`x |> modBy m`. In `Tensor.Eval` the remainder has the sign of `m`, as `Basics.modBy`'s does,
`uint64` elements are divided as unsigned numbers, and a 0 anywhere in `m` stops
the run with an error.
-}
modBy : Tensor Int d s -> Tensor Int d s -> Tensor Int d s
modBy =
    map2 (O.binary Mod)


{-| Returns x raised to the power y, element by element: `x |> pow y`.
-}
pow : Tensor Float d s -> Tensor Float d s -> Tensor Float d s
pow =
    map2 (O.binary Pow)


{-| Returns the larger of x and y at each element: `x |> max y`. In `Tensor.Eval` a NaN operand is
ignored, so the result is NaN only where both are. `maximum` is the reduction along an axis.
-}
max : Tensor k d s -> Tensor k d s -> Tensor k d s
max =
    map2 (O.binary Max2)


{-| Returns the smaller of x and y at each element: `x |> min y`. In `Tensor.Eval` a NaN operand is
ignored, as for `max`. `minimum` is the reduction along an axis.
-}
min : Tensor k d s -> Tensor k d s -> Tensor k d s
min =
    map2 (O.binary Min2)


{-| Returns `x` with each element multiplied by `k`: `x |> scale k`.
-}
scale : Float -> Tensor Float d s -> Tensor Float d s
scale k =
    map1 (\x -> O.mul x (O.scalarLike k x))


{-| Returns `x` with `k` added to each element: `x |> shift k`.
-}
shift : Float -> Tensor Float d s -> Tensor Float d s
shift k =
    map1 (\x -> O.add x (O.scalarLike k x))



-- COMPARISONS AND MASKS


{-| Returns the mask that `f` gives for `x` and `y`, in that order, where `y` is given first, as
`map2` orders them.
-}
compare : (Expr -> Expr -> Expr) -> Tensor k d s -> Tensor k d s -> Mask s
compare f y x =
    mask (f (un x) (un y))


{-| Returns the mask of where x == y: `x |> equals y`.
-}
equals : Tensor k d s -> Tensor k d s -> Mask s
equals =
    compare O.eq


{-| Returns the mask of where x /= y: `x |> notEquals y`.
-}
notEquals : Tensor k d s -> Tensor k d s -> Mask s
notEquals =
    compare O.ne


{-| Returns the mask of where x > y: `x |> greaterThan y`.
-}
greaterThan : Tensor k d s -> Tensor k d s -> Mask s
greaterThan =
    compare O.gt


{-| Returns the mask of where x >= y: `x |> atLeast y`.
-}
atLeast : Tensor k d s -> Tensor k d s -> Mask s
atLeast =
    compare O.ge


{-| Returns the mask of where x < y: `x |> lessThan y`. It is `greaterThan` with its operands
swapped.
-}
lessThan : Tensor k d s -> Tensor k d s -> Mask s
lessThan =
    compare O.lt


{-| Returns the mask of where x <= y: `x |> atMost y`. It is `atLeast` with its operands swapped.
-}
atMost : Tensor k d s -> Tensor k d s -> Mask s
atMost =
    compare O.le


{-| Returns the mask of where both masks hold.
-}
and : Mask s -> Mask s -> Mask s
and (I.Mask y) (I.Mask x) =
    mask (O.and_ x y)


{-| Returns the mask of where either mask holds.
-}
or : Mask s -> Mask s -> Mask s
or (I.Mask y) (I.Mask x) =
    mask (O.or_ x y)


{-| Returns the mask of where exactly one of the masks holds.
-}
xor : Mask s -> Mask s -> Mask s
xor (I.Mask y) (I.Mask x) =
    mask (O.binary Xor x y)


{-| Returns the mask of where the mask does not hold.
-}
not : Mask s -> Mask s
not (I.Mask x) =
    mask (O.not_ x)


{-| Returns `whereTrue`'s element where the mask holds and `whereFalse`'s where it does not:
`select mask whereTrue whereFalse`, in reading order rather than pipeline order.
-}
select : Mask s -> Tensor k d s -> Tensor k d s -> Tensor k d s
select (I.Mask c) a b =
    wrap (O.select c (un a) (un b))


{-| Returns 1 where the mask holds and 0 where it does not, in the dtype `d`.
-}
indicator : DType k d -> Mask s -> Tensor k d s
indicator d (I.Mask m) =
    wrap (O.indicator (dt d) m)


{-| Returns the mask with a new broadcast axis where `axis` names one, as `broadcast` does for a
tensor.
-}
maskBroadcast : Axis t s c -> Mask s -> Mask t
maskBroadcast (I.Axis i) (I.Mask m) =
    mask (O.broadcastAxis i m)


{-| Returns the mask that is true on and below the main diagonal of a matrix of `x`'s shape, whose
values are not used: the causal mask. The type gives both axes one tag, which does not make their
sizes equal, and a matrix that is not square is accepted.
-}
lowerTriangle : Tensor k d (R2 a a) -> Mask (R2 a a)
lowerTriangle x =
    let
        ones_ =
            O.fullLike 1 (O.cast F32 (un x))
    in
    mask (O.gt (O.bandPart -1 0 ones_) (O.scalarLike 0 ones_))



-- LINEAR ALGEBRA


{-| Returns the matrix product x @ w: `x |> matmul w`.
-}
matmul : Tensor k d (R2 b c) -> Tensor k d (R2 a b) -> Tensor k d (R2 a c)
matmul w x =
    wrap (O.matmul (un x) (un w))


{-| Returns the product of each of the `n` matrices of `x` with the matching matrix of `w`:
`x |> matmul3 w`. A batch axis of size 1 in one operand takes the other's size, so `x` with one
matrix and `w` with five give five products.
-}
matmul3 : Tensor k d (R3 n b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul3 w x =
    wrap (O.matmul (un x) (un w))


{-| Returns the product of each matrix of `x` with the matching matrix of `w`, over two leading
batch axes: `x |> matmul4 w`. A batch axis of size 1 in one operand takes the other's size.
-}
matmul4 : Tensor k d (R4 m n b c) -> Tensor k d (R4 m n a b) -> Tensor k d (R4 m n a c)
matmul4 w x =
    wrap (O.matmul (un x) (un w))


{-| Returns the product of each of the `n` matrices of `x` with the one matrix `w`:
`x |> matmul3By2 w`.
-}
matmul3By2 : Tensor k d (R2 b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul3By2 w x =
    wrap (O.matmul (un x) (un w))


{-| Returns the vector–matrix product v @ m: `v |> vecMat m`.
-}
vecMat : Tensor k d (R2 a b) -> Tensor k d (R1 a) -> Tensor k d (R1 b)
vecMat m v =
    wrap (O.matmul (un v) (un m))


{-| Returns the matrix–vector product m @ v: `m |> matVec v`.
-}
matVec : Tensor k d (R1 b) -> Tensor k d (R2 a b) -> Tensor k d (R1 a)
matVec v m =
    wrap (O.matmul (un m) (un v))


{-| Returns the inner product of two vectors, a scalar: `x |> dot y`.
-}
dot : Tensor k d (R1 a) -> Tensor k d (R1 a) -> Tensor k d R0
dot y x =
    wrap (O.matmul (un x) (un y))


{-| Returns the outer product of two vectors, whose element (i, j) is x[i] · y[j]: `x |> outer y`.
-}
outer : Tensor k d (R1 b) -> Tensor k d (R1 a) -> Tensor k d (R2 a b)
outer y x =
    let
        a =
            un x

        b =
            un y
    in
    wrap (O.matmul (O.reshape [ List.product (E.shape a), 1 ] a) (O.reshape [ 1, List.product (E.shape b) ] b))



-- REDUCTIONS


{-| Returns the sums of `x` along the axis `axis` names: `x |> sum Axis.axis1of2`.
-}
sum : Axis s r c -> Tensor k d s -> Tensor k d r
sum (I.Axis i) =
    map1 (O.reduce ReduceSum i)


{-| Returns the means of `x` along the axis `axis` names.
-}
mean : Axis s r c -> Tensor Float d s -> Tensor Float d r
mean (I.Axis i) =
    map1 (O.reduce ReduceMean i)


{-| Returns the largest elements of `x` along the axis `axis` names.
-}
maximum : Axis s r c -> Tensor k d s -> Tensor k d r
maximum (I.Axis i) =
    map1 (O.reduce ReduceMax i)


{-| Returns the smallest elements of `x` along the axis `axis` names.
-}
minimum : Axis s r c -> Tensor k d s -> Tensor k d r
minimum (I.Axis i) =
    map1 (O.reduce ReduceMin i)


{-| Returns the position, along the axis `axis` names, of the largest element at each position of
the other axes.
-}
argMax : Axis s r c -> Tensor k d s -> Tensor Int I64 r
argMax (I.Axis i) =
    map1 (O.reduce ArgMax i)


{-| Returns the position, along the axis `axis` names, of the smallest element at each position of
the other axes.
-}
argMin : Axis s r c -> Tensor k d s -> Tensor Int I64 r
argMin (I.Axis i) =
    map1 (O.reduce ArgMin i)


{-| Returns the running sums of `x` along the axis `axis` names, which is kept: each element is the
sum of the elements up to and including it.
-}
cumsum : Axis s r c -> Tensor k d s -> Tensor k d s
cumsum =
    cumsumWith { exclusive = False, reverse = False }


{-| Returns the running sums that `cumsum` returns, but with `exclusive` each element leaves itself
out of its sum, and with `reverse` the sums run from the end of the axis.
-}
cumsumWith : { exclusive : Bool, reverse : Bool } -> Axis s r c -> Tensor k d s -> Tensor k d s
cumsumWith cfg (I.Axis i) =
    map1 (O.cumsum i cfg.exclusive cfg.reverse)


{-| Returns log (sum (exp x)) along the axis `axis` names.

The largest element along the axis is subtracted before the exponentials and added back after the
log, which keeps the exponentials from overflowing. Where that largest element is +∞ or −∞, as
along an axis holding only −∞, the result is NaN.

-}
logSumExp : Axis s r c -> Tensor Float d s -> Tensor Float d r
logSumExp (I.Axis i) =
    map1 (O.logSumExp i)


{-| Returns the sum of every element.
-}
sumAll : Tensor k d s -> Tensor k d R0
sumAll =
    map1 O.sumAll


{-| Returns the mean of every element.
-}
meanAll : Tensor Float d s -> Tensor Float d R0
meanAll =
    map1 O.meanAll


{-| Returns the largest element.
-}
maximumAll : Tensor k d s -> Tensor k d R0
maximumAll =
    map1 O.maxAll


{-| Returns the smallest element.
-}
minimumAll : Tensor k d s -> Tensor k d R0
minimumAll =
    map1 O.minAll


{-| Returns the smallest and the largest element.
-}
minMax : Tensor k d s -> { min : Tensor k d R0, max : Tensor k d R0 }
minMax x =
    { min = minimumAll x, max = maximumAll x }


{-| Returns exp x / sum (exp x) along the axis `axis` names, which is kept, so that the elements
along it sum to 1.
-}
softmax : Axis s r c -> Tensor Float d s -> Tensor Float d s
softmax (I.Axis i) =
    map1 (O.softmax i)


{-| Returns log (softmax x) along the axis `axis` names, which is kept.
-}
logSoftmax : Axis s r c -> Tensor Float d s -> Tensor Float d s
logSoftmax (I.Axis i) =
    map1 (O.logSoftmax i)



-- SHAPE


{-| Returns `x`'s elements, in row-major order, in the shape `t`. A number of elements other than
`x`'s is a build error, and so is a broadcast axis in `x`.
-}
reshape : Shape t -> Tensor k d s -> Tensor k d t
reshape (I.Shape s) =
    map1 (O.reshape s)


{-| Returns every element of `x`, in row-major order, along one axis of size `m`. A size other than
`x`'s number of elements is a build error.
-}
flatten : Dim m -> Tensor k d s -> Tensor k d (R1 m)
flatten (I.Dim m) =
    map1 (O.reshape [ m ])


{-| Returns `x` reshaped to its first `n` sizes followed by `tail`. It is a reshape, so a different
number of elements, or a broadcast axis in `x`, is a build error.
-}
keepFirst : Int -> List Int -> Expr -> Expr
keepFirst n tail x =
    O.reshape (List.take n (E.shape x) ++ tail) x


{-| Returns `x` with everything after its first axis flattened, in row-major order, into one axis of
size `m`, such as a batch of images to a batch of vectors. A size other than the product of the
flattened axes' sizes is a build error, unless `x`'s first axis has size 0.
-}
flattenTail3 : Dim m -> Tensor k d (R3 n a b) -> Tensor k d (R2 n m)
flattenTail3 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| Returns what `flattenTail3` returns, for a tensor of rank 4, such as a batch of multi-channel
images.
-}
flattenTail4 : Dim m -> Tensor k d (R4 n a b c) -> Tensor k d (R2 n m)
flattenTail4 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| Returns the vector as a matrix of the sizes of `a` and `b`, filled row by row: the inverse of
`mergeLast2`. Sizes whose product is not the vector's size are a build error.
-}
factorLast2 : Dim a -> Dim b -> Tensor k d (R1 m) -> Tensor k d (R2 a b)
factorLast2 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 0 [ a, b ])


{-| Returns `x` with its last axis split, row-major, into two of the sizes of `a` and `b`: the
inverse of `mergeLast3`. Sizes whose product is not the last axis's size are a build error,
unless `x`'s first axis has size 0.
-}
factorLast3 : Dim a -> Dim b -> Tensor k d (R2 x m) -> Tensor k d (R3 x a b)
factorLast3 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 1 [ a, b ])


{-| Returns `x` with its last axis split, row-major, into two of the sizes of `a` and `b`: the
inverse of `mergeLast4`. Sizes whose product is not the last axis's size are a build error,
unless one of `x`'s first two axes has size 0.
-}
factorLast4 : Dim a -> Dim b -> Tensor k d (R3 x y m) -> Tensor k d (R4 x y a b)
factorLast4 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 2 [ a, b ])


{-| Returns the matrix as a vector of size `m`, row by row: the inverse of `factorLast2`. A size
other than the matrix's number of elements is a build error.
-}
mergeLast2 : Dim m -> Tensor k d (R2 a b) -> Tensor k d (R1 m)
mergeLast2 (I.Dim m) =
    map1 (keepFirst 0 [ m ])


{-| Returns `x` with its last two axes merged, row-major, into one of size `m`, such as heads ×
head size back to a model width: the inverse of `factorLast3`. A size other than the product of the
two axes' sizes is a build error, unless `x`'s first axis has size 0.
-}
mergeLast3 : Dim m -> Tensor k d (R3 x a b) -> Tensor k d (R2 x m)
mergeLast3 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| Returns `x` with its last two axes merged, row-major, into one of size `m`: the inverse of
`factorLast4`. A size other than the product of the two axes' sizes is a build error, unless one
of `x`'s first two axes has size 0.
-}
mergeLast4 : Dim m -> Tensor k d (R4 x y a b) -> Tensor k d (R3 x y m)
mergeLast4 (I.Dim m) =
    map1 (keepFirst 2 [ m ])


{-| Returns the transpose of a matrix: its rows become its columns.
-}
transpose : Tensor k d (R2 a b) -> Tensor k d (R2 b a)
transpose =
    map1 (O.transpose [ 1, 0 ])


{-| Returns the permutation of `r` axes that `swaps` make, applied in order to the axes in their
original order: entry k is the axis of the operand that axis k of the result reads.
-}
permutation : Int -> List ( Int, Int ) -> List Int
permutation r swaps =
    List.foldl
        (\( i, j ) p ->
            let
                pi =
                    List.head (List.drop i p) |> Maybe.withDefault i

                pj =
                    List.head (List.drop j p) |> Maybe.withDefault j
            in
            List.indexedMap
                (\k v ->
                    if k == i then
                        pj

                    else if k == j then
                        pi

                    else
                        v
                )
                p
        )
        (List.range 0 (r - 1))
        swaps


{-| Returns `x` with its axes reordered as `perm` says: `x |> permute Axis.swap12of4`.
-}
permute : Perm s t -> Tensor k d s -> Tensor k d t
permute (I.Perm swaps) =
    map1 (\x -> O.transpose (permutation (E.rank x) swaps) x)


{-| Returns `x` with a new broadcast axis where `axis` names one: an axis of size 1 whose size is
not known yet. The module documentation says which operations give it a size and which keep it;
most others refuse it with a build error.
-}
broadcast : Axis t s c -> Tensor k d s -> Tensor k d t
broadcast (I.Axis i) =
    map1 (O.broadcastAxis i)


{-| Returns `x` with a new axis of size `c` where `axis` names one, every slice along it a copy of
`x`. Unlike `broadcast`, it gives the axis its size at once. A broadcast axis already in `x` is a
build error.
-}
broadcastTo : Dim c -> Axis t s c -> Tensor k d s -> Tensor k d t
broadcastTo (I.Dim c) (I.Axis i) =
    map1
        (\x ->
            let
                s =
                    E.shape x
            in
            O.broadcastTo (List.take i s ++ (c :: List.drop i s)) (O.insertAxis i x)
        )


{-| Returns a matrix whose every row is the vector, the rows being a broadcast axis:
`x |> plus (rows bias)`.
-}
rows : Tensor k d (R1 b) -> Tensor k d (R2 a b)
rows =
    map1 (O.broadcastAxis 0)


{-| Returns a matrix whose every column is the vector, the columns being a broadcast axis.
-}
columns : Tensor k d (R1 a) -> Tensor k d (R2 a b)
columns =
    map1 (O.broadcastAxis 1)


{-| Returns `x` with a new real axis of size 1, tagged `One`, where `axis` names one. Unlike the
axis `broadcast` adds, it keeps size 1.
-}
insertOne : Axis t s One -> Tensor k d s -> Tensor k d t
insertOne (I.Axis i) =
    map1 (O.insertAxis i)


{-| Returns `x` without the axis `axis` names, which is meant to have size 1. Dropping an axis of
another size is a build error, unless `x` has no elements. Dropping a broadcast axis is a build
error.
-}
dropOne : Axis s r One -> Tensor k d s -> Tensor k d r
dropOne (I.Axis i) =
    map1 (O.dropAxis i)


{-| Returns the element at index `i` of `l`, or 0 past its end. A negative `i` reads element 0.
-}
at : Int -> List Int -> Int
at i l =
    List.head (List.drop i l) |> Maybe.withDefault 0


{-| Returns `l` with its element at index `i` replaced by `v`, or `l` unchanged when `i` is outside
it.
-}
setAt : Int -> Int -> List Int -> List Int
setAt i v l =
    List.indexedMap
        (\k x ->
            if k == i then
                v

            else
                x
        )
        l


{-| Returns `e`, failed with a build error naming `what` unless its size along `axis` is `c`. A
poisoned `e` is returned as it is, since its size may then be a stand-in.
-}
expectSize : Int -> Int -> String -> Expr -> Expr
expectSize axis c what e =
    if E.poisoned e || at axis (E.shape e) == c then
        e

    else
        E.failWith (what ++ ": the result has " ++ String.fromInt (at axis (E.shape e)) ++ " along axis " ++ String.fromInt axis ++ ", but its dimension says " ++ String.fromInt c) e


{-| Returns the `size` elements of `x` from `start` along the axis `retag` names, every other axis
whole: `x |> slice retag start size`. A block that does not lie within the axis is a build error.
-}
slice : Retag s t a c -> Int -> Dim c -> Tensor k d s -> Tensor k d t
slice (I.Retag i) start (I.Dim c) =
    map1 (\x -> O.slice (setAt i start (List.map (\_ -> 0) (E.shape x))) (setAt i c (E.shape x)) x)


{-| Returns `x` with the elements from `start` along the axis `retag` names replaced by `update`,
which covers as many of them as its own size along that axis: `x |> sliceUpdate retag start update`.
An update that does not lie within the axis is a build error, and so is one whose dtype, sizes on
the other axes or broadcast axes differ from `x`'s.
-}
sliceUpdate : Retag s t a c -> Int -> Tensor k d t -> Tensor k d s -> Tensor k d s
sliceUpdate (I.Retag i) start upd x =
    let
        xe =
            un x

        u =
            un upd

        s =
            E.shape xe

        n =
            at i s

        len =
            at i (E.shape u)

        zerosAt =
            List.map (\_ -> 0) s

        before =
            O.slice zerosAt (setAt i start s) xe

        after =
            O.slice (setAt i (start + len) zerosAt) (setAt i (n - start - len) s) xe

        pieces =
            List.filter (\p -> at i (E.shape p) > 0) [ before, u, after ]
    in
    if start < 0 || start + len > n then
        wrap (E.failWith ("sliceUpdate: " ++ String.fromInt len ++ " elements from " ++ String.fromInt start ++ " do not fit in " ++ String.fromInt n) xe)

    else if len == n then
        -- The update is the whole result: no Concat compares it with x.
        if E.poisoned u || E.poisoned xe || E.meta u == E.meta xe then
            wrap (E.inherit xe u)

        else
            wrap (E.failWith ("sliceUpdate: the update is " ++ describe u ++ " but x is " ++ describe xe) xe)

    else
        wrap (O.concat i pieces)


{-| Returns `e`'s dtype and shape as messages write them, such as `f32[2, 3]`, with each broadcast
axis's position after the shape.
-}
describe : Expr -> String
describe e =
    P.dtName (E.dtype e)
        ++ Shape.showShape (E.shape e)
        ++ (if List.isEmpty (E.pending e) then
                ""

            else
                " (broadcast at " ++ String.join ", " (List.map String.fromInt (E.pending e)) ++ ")"
           )


{-| Returns the tensors one after another along the axis `retag` names. `size` must be the total
size along that axis, the tensors must agree on every other axis, and the list must not be empty;
each is a build error otherwise.
-}
concat : Retag s t a c -> Dim c -> List (Tensor k d s) -> Tensor k d t
concat (I.Retag i) (I.Dim c) xs =
    wrap (expectSize i c "concat" (O.concat i (List.map un xs)))


{-| Returns `x` followed by `y` along the axis `rx` names, in reading order rather than pipeline
order: `concat2 rx ry size x y`. `ry` must name the same axis of `y`, and `size` must be the total
size along that axis; each is a build error otherwise.
-}
concat2 : Retag s t a c -> Retag u t b c -> Dim c -> Tensor k d s -> Tensor k d u -> Tensor k d t
concat2 (I.Retag i) (I.Retag j) (I.Dim c) x y =
    let
        e =
            O.concat i [ un x, un y ]
    in
    if i /= j then
        wrap (E.failWith ("concat2: the retags name different axes, " ++ String.fromInt i ++ " and " ++ String.fromInt j) e)

    else
        wrap (expectSize i c "concat2" e)


{-| Returns the consecutive slices of `size` elements of `x` along the axis `retag` names, in order.
When `size` is not positive or does not divide that axis's size, the result is instead a list of
one tensor, carrying a build error.
-}
chunks : Retag s t a c -> Dim c -> Tensor k d s -> List (Tensor k d t)
chunks (I.Retag i) (I.Dim c) x =
    let
        xe =
            un x

        s =
            E.shape xe

        n =
            at i s
    in
    if c <= 0 || Basics.modBy c n /= 0 then
        [ wrap (E.failWith ("chunks: " ++ String.fromInt c ++ " does not divide " ++ String.fromInt n) xe) ]

    else
        List.map (\k -> wrap (O.slice (setAt i (k * c) (List.map (\_ -> 0) s)) (setAt i c s) xe)) (List.range 0 (n // c - 1))


{-| Returns the tensors stacked, in order, along a new leading axis. The number of tensors must be
the size of `n`, the tensors must have one shape, and the list must not be empty; each is a build
error otherwise.
-}
stack : Lift n s t -> Dim n -> List (Tensor k d s) -> Tensor k d t
stack _ (I.Dim n) xs =
    let
        e =
            O.concat 0 (List.map (un >> O.insertAxis 0) xs)
    in
    if List.length xs /= n then
        wrap (E.failWith ("stack: " ++ String.fromInt (List.length xs) ++ " tensors, but the dimension says " ++ String.fromInt n) e)

    else
        wrap e


{-| Returns the slices of `x` along its leading axis, in order, each without that axis: the inverse
of `stack`.
-}
unstack : Lift n s t -> Tensor k d t -> List (Tensor k d s)
unstack _ x =
    let
        xe =
            un x

        s =
            E.shape xe
    in
    List.map
        (\k -> wrap (O.dropAxis 0 (O.slice (setAt 0 k (List.map (\_ -> 0) s)) (setAt 0 1 s) xe)))
        (List.range 0 (at 0 s - 1))


{-| Returns `x` with its elements along the axis `axis` names in reverse order.
-}
flip : Axis s r c -> Tensor k d s -> Tensor k d s
flip (I.Axis i) =
    map1
        (\x ->
            let
                n =
                    at i (E.shape x)
            in
            O.gather i x (O.range (n - 1) -1 n)
        )


{-| Returns `x` with `before` elements added before it and `after` after it along the axis `retag`
names, each `value`. `size` must be the padded size, and neither count may be negative; each is a
build error otherwise.
-}
pad : Retag s t a c -> { before : Int, after : Int, value : Float } -> Dim c -> Tensor Float d s -> Tensor Float d t
pad (I.Retag i) cfg (I.Dim c) =
    map1 (\x -> expectSize i c "pad" (O.pad i cfg.before cfg.after cfg.value x))


{-| Returns what `pad` returns, for an integer tensor, with the fill `value` kept as an `Int`. A fill
that the dtype cannot hold is a build error, even when both counts are 0.
-}
padInt : Retag s t a c -> { before : Int, after : Int, value : Int } -> Dim c -> Tensor Int d s -> Tensor Int d t
padInt (I.Retag i) cfg (I.Dim c) =
    map1 (\x -> expectSize i c "padInt" (O.padInt i cfg.before cfg.after cfg.value x))


{-| Returns the slices of `x` along the axis `retag` names at the positions in `indices`, in their
order, so that the axis gets the indices' length: `x |> take retag indices`. An index outside the
axis is not a build error; `Tensor.Eval` refuses it when it runs.
-}
take : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d s -> Tensor k d t
take (I.Retag i) idx =
    map1 (\x -> O.gather i x (O.cast SI64 (un idx)))


{-| Returns the rows of the matrix at the positions in `ids`, in their order, as an embedding lookup
does: `table |> rowsAt ids`. An index outside the matrix is not a build error; `Tensor.Eval` refuses
it when it runs.
-}
rowsAt : Tensor Int i (R1 n) -> Tensor k d (R2 v m) -> Tensor k d (R2 n m)
rowsAt idx =
    map1 (\x -> O.gather 0 x (O.cast SI64 (un idx)))


{-| Returns one element of each row of `x`, the one at column `indices[i]` of row i:
`x |> pick indices`.

The other elements of a row, NaN and ±∞ included, do not change its result. An index outside
0 … c − 1 gives 0, with no error.

-}
pick : Tensor Int i (R1 n) -> Tensor k d (R2 n c) -> Tensor k d (R1 n)
pick idx =
    map1 (O.pick (un idx))


{-| Returns `x` with its slices along the axis `retag` names at the positions in `indices` replaced
by the slices of `updates`, in order: `x |> put retag indices updates`. An index outside the axis
is not a build error; `Tensor.Eval` refuses it when it runs.
-}
put : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
put (I.Retag i) idx upd =
    map1 (\x -> O.scatterAxis i x (un upd) (O.cast SI64 (un idx)))


{-| Returns what `put` returns, but with each slice of `updates` added to the slice of `x` at its
index instead of replacing it, so that the updates at a repeated index add up.
-}
putAdd : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
putAdd (I.Retag i) idx upd =
    map1 (\x -> O.scatterAxisAdd i x (un upd) (O.cast SI64 (un idx)))


{-| Returns the matrix with every element below diagonal `k` set to zero, diagonal `k` being the
elements whose column minus row is `k`: those with column − row < `k` are zeroed.

For `k` above 0 the zeros are made by subtracting the elements from themselves, so a NaN, +∞ or −∞
there gives NaN instead of 0.

-}
triu : Int -> Tensor k d (R2 a b) -> Tensor k d (R2 a b)
triu k =
    map1
        (\x ->
            if k <= 0 then
                O.bandPart -k -1 x

            else
                O.sub x (O.bandPart -1 (k - 1) x)
        )


{-| Returns the matrix with every element above diagonal `k` set to zero, diagonal `k` being the
elements whose column minus row is `k`: those with column − row > `k` are zeroed.

For `k` below 0 the zeros are made by subtracting the elements from themselves, so a NaN, +∞ or −∞
there gives NaN instead of 0.

-}
tril : Int -> Tensor k d (R2 a b) -> Tensor k d (R2 a b)
tril k =
    map1
        (\x ->
            if k >= 0 then
                O.bandPart -1 k x

            else
                O.sub x (O.bandPart (-k - 1) -1 x)
        )


{-| Returns `x` with its values unchanged, through which no gradient is passed back.
-}
stopGradient : Tensor k d s -> Tensor k d s
stopGradient =
    map1 O.stopGradient


{-| Returns x · sigmoid (1.702 x) of each element x, an approximation of `gelu`.
-}
quickGelu : Tensor Float d s -> Tensor Float d s
quickGelu =
    map1 (\e -> O.mul e (O.unary P.Sigmoid (O.mul e (O.scalarLike 1.702 e))))


{-| Returns the `k` largest elements of `x` along the axis `retag` names, largest first, and their
positions along that axis: `logits |> topK Axis.retag1of2 (dim Top 5)`. A `k` below 1 or above the
axis's size is a build error.

A reverse-mode gradient through the values, such as `Transform.grad` takes, gives a build error,
reported only if something being built or evaluated depends on that gradient; the positions carry
no gradient. `Max` refuses for a GPU a top-k along any axis but the last.

-}
topK : Retag s t a c -> Dim c -> Tensor k d s -> ( Tensor k d t, Tensor Int I64 t )
topK (I.Retag i) (I.Dim k) x =
    let
        ( v, ix ) =
            O.topK True i k (un x)
    in
    ( wrap v, wrap ix )


{-| Returns the `k` smallest elements of `x` along the axis `retag` names, smallest first, and their
positions along that axis. Otherwise it is `topK`, with the same build errors and gradient and GPU
refusals.
-}
bottomK : Retag s t a c -> Dim c -> Tensor k d s -> ( Tensor k d t, Tensor Int I64 t )
bottomK (I.Retag i) (I.Dim k) x =
    let
        ( v, ix ) =
            O.topK False i k (un x)
    in
    ( wrap v, wrap ix )


{-| Returns the elements of `x` sorted along the axis `axis` names, smallest first or, with
`descending`, largest first, and the positions along that axis they came from. It is `topK` or
`bottomK` with `k` the whole axis, with their gradient and GPU refusals, except along an axis of
size 0, where it gives `x` itself and an empty `int64` tensor of `x`'s shape.
-}
sort : { descending : Bool } -> Axis s r c -> Tensor k d s -> ( Tensor k d s, Tensor Int I64 s )
sort cfg (I.Axis i) x =
    let
        e =
            un x

        n =
            List.drop i (E.shape e) |> List.head |> Maybe.withDefault 1

        ( v, ix ) =
            O.topK cfg.descending i n e
    in
    if n == 0 && List.isEmpty (E.pending e) then
        ( x, wrap (E.const SI64 (E.shape e) [] |> E.inherit e) )

    else
        ( wrap v, wrap ix )
