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

{-| Tensors as values, typed by element type, dtype and shape.

A `Tensor e dtype shape` is an immutable expression: nothing is computed until a `Graph` is built
and run by MAX. The shape is a fixed-rank type of named dimensions, `R2 Batch Hidden`, so mixing up
dimensions, axes or dtypes is a compile error; sizes the types cannot compute are checked when the
graph is built.

Pipelines read left to right: `x |> plus y` is x + y, `x |> matmul w` is x @ w.


# Types

@docs Tensor, Mask, Dim, Shape, DType, Axis, Retag, Lift, Perm


# Shapes

The ranks a shape type can have, and the tag of a size-1 axis.

@docs R0, R1, R2, R3, R4, R5, One, Elems


# Dtypes

A tensor's first type parameter is the Elm type of its elements: `Float` for the floating dtypes
(`Tensor Float F32 s`) and `Int` for the integer ones (`Tensor Int I64 s`). Values given to
`constant`, `full`, `fromList`, `fullLikeInt` and `padInt` have that type, so integers never pass
through `Float`: on eco's native code, where `Int` is 64-bit, they are exact to 64 bits. (Under
JavaScript an `Int` is exact only to 2⁵³.) An integer that does not fit its dtype, such as 300 for
`uint8`, is a build error.

A u64 element is the `Int` with the same 64 bits: 2⁶³ … 2⁶⁴ − 1 are written and read as negative
`Int`s (`fromList uint64 shape [ -1 ]` is 2⁶⁴ − 1).

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

Binary operations read left to right in a pipeline: `x |> minus y` is x - y.

@docs plus, minus, times, dividedBy, modBy, pow, max, min, scale, shift


# Comparisons and masks

@docs equals, notEquals, greaterThan, atLeast, lessThan, atMost, and, or, xor, not, select, indicator, maskBroadcast


# Linear algebra

@docs matmul, matmul3, matmul4, matmul3By2, vecMat, matVec, dot, outer


# Reductions

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
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values



-- TYPES


{-| A tensor expression of an element type (`Float` or `Int`), a dtype (`F32`, `I64`, ...) and a shape
(`R2 Batch Hidden`). Nothing is computed until a `Graph` is built and run.
-}
type alias Tensor e dtype shape =
    I.Tensor e dtype shape


{-| A boolean tensor of a shape: what comparisons make and `select` consumes.
-}
type alias Mask shape =
    I.Mask shape


{-| A dimension: an axis's size, typed by its tag (a constructor you declare, `type Hidden = Hidden`).
Made by `dim`.
-}
type alias Dim tag =
    I.Dim tag


{-| A whole shape, typed by its rank and tags: `r2 batch hidden : Shape (R2 Batch Hidden)`.
-}
type alias Shape s =
    I.Shape s


{-| An element type, with the Elm type of its elements: `float32 : DType Float F32`, `int64 : DType Int I64`.
-}
type alias DType e dtype =
    I.DType e dtype


{-| Which axis an operation removes or inserts, typed by the shape with it (`s`), the shape without it
(`r`) and its tag (`c`). `Tensor.Axis` has one for every rank and position.
-}
type alias Axis s r c =
    I.Axis s r c


{-| Which axis an operation resizes: the shape before (`s`) and after (`t`), the axis's tag before
(`a`) and after (`c`). `Tensor.Axis` has one for every rank and position.
-}
type alias Retag s t a c =
    I.Retag s t a c


{-| A leading axis tagged `n` prepended: shape `s` becomes `t` (`stack`, `unstack`, `Transform.vmap`).
-}
type alias Lift n s t =
    I.Lift n s t


{-| A reordering of the axes of shape `s` into shape `t`, as swaps of two axes (`Tensor.Axis.swap01of2`).
-}
type alias Perm s t =
    I.Perm s t


{-| The shape of a scalar.
-}
type alias R0 =
    I.R0


{-| The shape of rank 1 whose axis is tagged `a`.
-}
type alias R1 a =
    I.R1 a


{-| The shape of rank 2 with axes tagged `a` and `b`, outermost first.
-}
type alias R2 a b =
    I.R2 a b


{-| The shape of rank 3, outermost axis first.
-}
type alias R3 a b c =
    I.R3 a b c


{-| The shape of rank 4, outermost axis first.
-}
type alias R4 a b c d =
    I.R4 a b c d


{-| The shape of rank 5, outermost axis first.
-}
type alias R5 a b c d e =
    I.R5 a b c d e


{-| The tag of a real size-1 axis (`one`, `insertOne`, `dropOne`).
-}
type alias One =
    I.One


{-| The shape an element-wise update sees (`Optim.custom`, `Param.mapElems`): only rank-free
operations apply to it.
-}
type alias Elems =
    I.Elems


{-| IEEE half precision.
-}
type alias F16 =
    I.F16


{-| bfloat16: f32's exponent range with an 8-bit significand.
-}
type alias BF16 =
    I.BF16


{-| IEEE single precision.
-}
type alias F32 =
    I.F32


{-| IEEE double precision.
-}
type alias F64 =
    I.F64


{-| Signed 8-bit integers.
-}
type alias I8 =
    I.I8


{-| Signed 32-bit integers.
-}
type alias I32 =
    I.I32


{-| Signed 64-bit integers.
-}
type alias I64 =
    I.I64


{-| Unsigned 8-bit integers.
-}
type alias U8 =
    I.U8


{-| Unsigned 64-bit integers.
-}
type alias U64 =
    I.U64


wrap : Expr -> Tensor k d s
wrap =
    I.Tensor


un : Tensor k d s -> Expr
un =
    I.tensor


map1 : (Expr -> Expr) -> Tensor k d s -> Tensor k2 d2 t
map1 f x =
    wrap (f (un x))


mask : Expr -> Mask s
mask =
    I.Mask



-- DTYPES


{-| f16 elements.
-}
float16 : DType Float F16
float16 =
    I.DType F16 Values.FloatValues


{-| bf16 elements.
-}
bfloat16 : DType Float BF16
bfloat16 =
    I.DType BF16 Values.FloatValues


{-| f32 elements.
-}
float32 : DType Float F32
float32 =
    I.DType F32 Values.FloatValues


{-| f64 elements.
-}
float64 : DType Float F64
float64 =
    I.DType F64 Values.FloatValues


{-| Signed 8-bit integer elements.
-}
int8 : DType Int I8
int8 =
    I.DType SI8 Values.IntValues


{-| Signed 32-bit integer elements.
-}
int32 : DType Int I32
int32 =
    I.DType SI32 Values.IntValues


{-| Signed 64-bit integer elements.
-}
int64 : DType Int I64
int64 =
    I.DType SI64 Values.IntValues


{-| Unsigned 8-bit integer elements.
-}
uint8 : DType Int U8
uint8 =
    I.DType UI8 Values.IntValues


{-| Unsigned 64-bit integer elements.
-}
uint64 : DType Int U64
uint64 =
    I.DType UI64 Values.IntValues


dt : DType k d -> DT
dt =
    I.dtOf


conv : DType k d -> List k -> Values.Values
conv =
    I.valuesOf



-- DIMENSIONS AND SHAPES


{-| A dimension: its tag's constructor and its size. `hidden = dim Hidden 128`.
-}
dim : tag -> Int -> Dim tag
dim _ n =
    I.Dim n


{-| The dimension of a real size-1 axis (a grey image's channel), as `insertOne` makes.
-}
one : Dim One
one =
    I.Dim 1


{-| The size of a dimension.
-}
size : Dim tag -> Int
size (I.Dim n) =
    n


{-| The shape of a scalar.
-}
scalar : Shape R0
scalar =
    I.Shape []


{-| A rank-1 shape: `r1 hidden`.
-}
r1 : Dim a -> Shape (R1 a)
r1 (I.Dim a) =
    I.Shape [ a ]


{-| A rank-2 shape, outermost dimension first: `r2 batch hidden`.
-}
r2 : Dim a -> Dim b -> Shape (R2 a b)
r2 (I.Dim a) (I.Dim b) =
    I.Shape [ a, b ]


{-| A rank-3 shape, outermost dimension first.
-}
r3 : Dim a -> Dim b -> Dim c -> Shape (R3 a b c)
r3 (I.Dim a) (I.Dim b) (I.Dim c) =
    I.Shape [ a, b, c ]


{-| A rank-4 shape, outermost dimension first.
-}
r4 : Dim a -> Dim b -> Dim c -> Dim d -> Shape (R4 a b c d)
r4 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) =
    I.Shape [ a, b, c, d ]


{-| A rank-5 shape, outermost dimension first.
-}
r5 : Dim a -> Dim b -> Dim c -> Dim d -> Dim e -> Shape (R5 a b c d e)
r5 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) (I.Dim e) =
    I.Shape [ a, b, c, d, e ]


{-| The sizes, known when the tensor is made (1 at a broadcast axis not yet sized).
-}
shapeOf : Tensor k d s -> List Int
shapeOf x =
    E.shape (un x)


{-| The dtype as MAX names it: `"f32"`, `"bf16"`, `"si64"`, ...
-}
dtypeName : Tensor k d s -> String
dtypeName x =
    P.dtName (E.dtype (un x))



-- CONSTRUCTION


{-| An f32 scalar.
-}
float : Float -> Tensor Float F32 R0
float f =
    wrap (E.scalar F32 f)


{-| An i64 scalar (exact: the `Int` never passes through `Float`).
-}
int : Int -> Tensor Int I64 R0
int n =
    wrap (E.constValues SI64 [] (Values.IntValues [ n ]))


{-| A scalar of a dtype, given as the dtype's kind: `constant bfloat16 0.5`, `constant uint8 200`.
An integer outside the dtype's range (300 for `uint8`) is a build error.
-}
constant : DType e d -> e -> Tensor e d R0
constant d v =
    wrap (E.constValues (dt d) [] (conv d [ v ]))


{-| A scalar spread to the shape of a template: `fillLike rate grad`.
-}
fillLike : Tensor k d R0 -> Tensor k d s -> Tensor k d s
fillLike c x =
    wrap (O.broadcastTo (E.shape (un x)) (un c))


{-| Every element `v`: `full float32 0.5 (r2 batch hidden)`, `full int64 7 (r1 n)`.
-}
full : DType e d -> e -> Shape s -> Tensor e d s
full d v (I.Shape s) =
    wrap (O.broadcastTo s (E.constValues (dt d) [] (conv d [ v ])))


{-| Every element 0.
-}
zeros : DType e d -> Shape s -> Tensor e d s
zeros d (I.Shape s) =
    wrap (O.broadcastTo s (E.scalar (dt d) 0))


{-| Every element 1.
-}
ones : DType e d -> Shape s -> Tensor e d s
ones d (I.Shape s) =
    wrap (O.broadcastTo s (E.scalar (dt d) 1))


{-| Row-major values of the dtype's kind: `fromList float32 (r1 three) [ 1, 2.5, 4 ]`,
`fromList int64 (r1 two) [ 7, -3 ]`. Their number must be the shape's size, and integers must fit
the dtype (both checked when the graph is built).
-}
fromList : DType e d -> Shape s -> List e -> Tensor e d s
fromList d (I.Shape s) values =
    wrap (E.constValues (dt d) s (conv d values))


{-| Zeros of another tensor's dtype and shape.
-}
zerosLike : Tensor k d s -> Tensor k d s
zerosLike =
    map1 O.zerosLike


{-| Ones of another tensor's dtype and shape.
-}
onesLike : Tensor k d s -> Tensor k d s
onesLike =
    map1 O.onesLike


{-| `v` everywhere, in another floating tensor's dtype and shape.
-}
fullLike : Float -> Tensor Float d s -> Tensor Float d s
fullLike v =
    map1 (O.fullLike v)


{-| `v` everywhere, in another integer tensor's dtype and shape (exact; it must fit the dtype).
-}
fullLikeInt : Int -> Tensor Int d s -> Tensor Int d s
fullLikeInt v =
    map1 (O.fullLikeValues (Values.IntValues [ v ]))


{-| 0, 1 .. n - 1.
-}
iota : Dim n -> Tensor Int I64 (R1 n)
iota (I.Dim n) =
    wrap (O.range 0 1 n)


{-| `start`, `start + step`, ... : as many values as the dimension says.
-}
arange : { start : Int, step : Int } -> Dim n -> Tensor Int I64 (R1 n)
arange r (I.Dim n) =
    wrap (O.range r.start r.step n)


{-| w[i] = ½ (1 - cos (2π i / N)), N = n if periodic, else n - 1.
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


{-| Convert the elements to another dtype.
-}
cast : DType k d -> Tensor k0 d0 s -> Tensor k d s
cast d =
    map1 (O.cast (dt d))


{-| Convert the elements to another tensor's dtype: `x |> castLike y`.
-}
castLike : Tensor k d t -> Tensor k0 d0 s -> Tensor k d s
castLike t =
    map1 (O.cast (E.dtype (un t)))


{-| Convert the elements to f32.
-}
toFloat : Tensor k d s -> Tensor Float F32 s
toFloat =
    map1 (O.cast F32)


{-| Convert the elements to i64.
-}
toInt : Tensor k d s -> Tensor Int I64 s
toInt =
    map1 (O.cast SI64)



-- ELEMENT-WISE


{-| Absolute value, element-wise.
-}
abs : Tensor k d s -> Tensor k d s
abs =
    map1 (O.unary Abs)


{-| -x, element-wise.
-}
negate : Tensor k d s -> Tensor k d s
negate =
    map1 O.neg


{-| -1, 0 or 1 by the sign of each element.
-}
sign : Tensor k d s -> Tensor k d s
sign =
    map1 O.sign


{-| `e ** x`, element-wise.
-}
exp : Tensor Float d s -> Tensor Float d s
exp =
    map1 (O.unary Exp)


{-| The natural logarithm, element-wise.
-}
log : Tensor Float d s -> Tensor Float d s
log =
    map1 (O.unary Log)


{-| log (1 + x), accurate for small x.
-}
log1p : Tensor Float d s -> Tensor Float d s
log1p =
    map1 (O.unary Log1p)


{-| Square root, element-wise.
-}
sqrt : Tensor Float d s -> Tensor Float d s
sqrt =
    map1 (O.unary Sqrt)


{-| 1 / sqrt x, element-wise.
-}
rsqrt : Tensor Float d s -> Tensor Float d s
rsqrt =
    map1 (O.unary Rsqrt)


{-| Sine, element-wise (radians).
-}
sin : Tensor Float d s -> Tensor Float d s
sin =
    map1 (O.unary Sin)


{-| Cosine, element-wise (radians).
-}
cos : Tensor Float d s -> Tensor Float d s
cos =
    map1 (O.unary Cos)


{-| Arc cosine, element-wise.
-}
acos : Tensor Float d s -> Tensor Float d s
acos =
    map1 (O.unary Acos)


{-| Inverse hyperbolic tangent, element-wise.
-}
atanh : Tensor Float d s -> Tensor Float d s
atanh =
    map1 (O.unary Atanh)


{-| The error function, element-wise.
-}
erf : Tensor Float d s -> Tensor Float d s
erf =
    map1 (O.unary Erf)


{-| Round down, element-wise.
-}
floor : Tensor Float d s -> Tensor Float d s
floor =
    map1 (O.unary Floor)


{-| Half to even.
-}
round : Tensor Float d s -> Tensor Float d s
round =
    map1 (O.unary Round)


{-| Round towards zero, element-wise.
-}
truncate : Tensor Float d s -> Tensor Float d s
truncate =
    map1 (O.unary Trunc)


{-| max x 0, element-wise.
-}
relu : Tensor k d s -> Tensor k d s
relu =
    map1 (O.unary Relu)


{-| `1 / (1 + e ** -x)`, element-wise.
-}
sigmoid : Tensor Float d s -> Tensor Float d s
sigmoid =
    map1 (O.unary Sigmoid)


{-| Hyperbolic tangent, element-wise.
-}
tanh : Tensor Float d s -> Tensor Float d s
tanh =
    map1 (O.unary Tanh)


{-| x Φ(x), exact.
-}
gelu : Tensor Float d s -> Tensor Float d s
gelu =
    map1 (O.unary Gelu)


{-| GELU with the tanh approximation.
-}
geluTanh : Tensor Float d s -> Tensor Float d s
geluTanh =
    map1 (O.unary GeluTanh)


{-| x · sigmoid x (also called swish).
-}
silu : Tensor Float d s -> Tensor Float d s
silu =
    map1 (O.unary Silu)


{-| Where an element is +∞ or -∞.
-}
isInfinite : Tensor Float d s -> Mask s
isInfinite x =
    mask (O.unary IsInf (un x))


{-| Where an element is NaN.
-}
isNaN : Tensor Float d s -> Mask s
isNaN x =
    mask (O.unary IsNaN (un x))


map2 : (Expr -> Expr -> Expr) -> Tensor k d s -> Tensor k d s -> Tensor k d s
map2 f y x =
    wrap (f (un x) (un y))


{-| `x |> plus y` is x + y.
-}
plus : Tensor k d s -> Tensor k d s -> Tensor k d s
plus =
    map2 O.add


{-| `x |> minus y` is x - y.
-}
minus : Tensor k d s -> Tensor k d s -> Tensor k d s
minus =
    map2 O.sub


{-| `x |> times y` is `x * y`, element-wise.
-}
times : Tensor k d s -> Tensor k d s -> Tensor k d s
times =
    map2 O.mul


{-| `x |> dividedBy y` is x / y.
-}
dividedBy : Tensor Float d s -> Tensor Float d s -> Tensor Float d s
dividedBy =
    map2 O.div


{-| `x |> modBy m`: the remainder with the sign of `m`, as `Basics.modBy`.
-}
modBy : Tensor Int d s -> Tensor Int d s -> Tensor Int d s
modBy =
    map2 (O.binary Mod)


{-| `x |> pow y` is `x ** y`.
-}
pow : Tensor Float d s -> Tensor Float d s -> Tensor Float d s
pow =
    map2 (O.binary Pow)


{-| Element-wise: `x |> max y`. (`maximum` is the reduction, as `List.maximum` is.)
-}
max : Tensor k d s -> Tensor k d s -> Tensor k d s
max =
    map2 (O.binary Max2)


{-| Element-wise: `x |> min y`. (`minimum` is the reduction.)
-}
min : Tensor k d s -> Tensor k d s -> Tensor k d s
min =
    map2 (O.binary Min2)


{-| `x |> scale k` is `x * k`.
-}
scale : Float -> Tensor Float d s -> Tensor Float d s
scale k =
    map1 (\x -> O.mul x (O.scalarLike k x))


{-| `x |> shift k` is x + k.
-}
shift : Float -> Tensor Float d s -> Tensor Float d s
shift k =
    map1 (\x -> O.add x (O.scalarLike k x))



-- COMPARISONS AND MASKS


compare : (Expr -> Expr -> Expr) -> Tensor k d s -> Tensor k d s -> Mask s
compare f y x =
    mask (f (un x) (un y))


{-| `x |> equals y` is x == y.
-}
equals : Tensor k d s -> Tensor k d s -> Mask s
equals =
    compare O.eq


{-| `x |> notEquals y` is x /= y.
-}
notEquals : Tensor k d s -> Tensor k d s -> Mask s
notEquals =
    compare O.ne


{-| `x |> greaterThan y` is x > y.
-}
greaterThan : Tensor k d s -> Tensor k d s -> Mask s
greaterThan =
    compare O.gt


{-| `x |> atLeast y` is x >= y.
-}
atLeast : Tensor k d s -> Tensor k d s -> Mask s
atLeast =
    compare O.ge


{-| `x |> lessThan y` is x < y.
-}
lessThan : Tensor k d s -> Tensor k d s -> Mask s
lessThan =
    compare O.lt


{-| `x |> atMost y` is x <= y.
-}
atMost : Tensor k d s -> Tensor k d s -> Mask s
atMost =
    compare O.le


{-| Where both masks hold.
-}
and : Mask s -> Mask s -> Mask s
and (I.Mask y) (I.Mask x) =
    mask (O.and_ x y)


{-| Where either mask holds.
-}
or : Mask s -> Mask s -> Mask s
or (I.Mask y) (I.Mask x) =
    mask (O.or_ x y)


{-| Where exactly one of the masks holds.
-}
xor : Mask s -> Mask s -> Mask s
xor (I.Mask y) (I.Mask x) =
    mask (O.binary Xor x y)


{-| Where the mask does not hold.
-}
not : Mask s -> Mask s
not (I.Mask x) =
    mask (O.not_ x)


{-| `select mask whereTrue whereFalse` (not a pipeline operation).
-}
select : Mask s -> Tensor k d s -> Tensor k d s -> Tensor k d s
select (I.Mask c) a b =
    wrap (O.select c (un a) (un b))


{-| 1 where the mask holds, 0 elsewhere.
-}
indicator : DType k d -> Mask s -> Tensor k d s
indicator d (I.Mask m) =
    wrap (O.indicator (dt d) m)


{-| A mask with a new axis that the next operation broadcasts, as `broadcast` does for tensors.
-}
maskBroadcast : Axis t s c -> Mask s -> Mask t
maskBroadcast (I.Axis i) (I.Mask m) =
    mask (O.broadcastAxis i m)


{-| True on and below the diagonal of a square tensor: the causal mask.
-}
lowerTriangle : Tensor k d (R2 a a) -> Mask (R2 a a)
lowerTriangle x =
    let
        ones_ =
            O.fullLike 1 (O.cast F32 (un x))
    in
    mask (O.gt (O.bandPart -1 0 ones_) (O.scalarLike 0 ones_))



-- LINEAR ALGEBRA


{-| `x |> matmul w` is x @ w.
-}
matmul : Tensor k d (R2 b c) -> Tensor k d (R2 a b) -> Tensor k d (R2 a c)
matmul w x =
    wrap (O.matmul (un x) (un w))


{-| `matmul` for each matrix of a batch: `x |> matmul3 w`.
-}
matmul3 : Tensor k d (R3 n b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul3 w x =
    wrap (O.matmul (un x) (un w))


{-| `matmul` over two leading batch axes.
-}
matmul4 : Tensor k d (R4 m n b c) -> Tensor k d (R4 m n a b) -> Tensor k d (R4 m n a c)
matmul4 w x =
    wrap (O.matmul (un x) (un w))


{-| A batch of matrices times one matrix (the weight is shared across the batch).
-}
matmul3By2 : Tensor k d (R2 b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul3By2 w x =
    wrap (O.matmul (un x) (un w))


{-| `v |> vecMat m` is v @ m.
-}
vecMat : Tensor k d (R2 a b) -> Tensor k d (R1 a) -> Tensor k d (R1 b)
vecMat m v =
    wrap (O.matmul (un v) (un m))


{-| `m |> matVec v` is m @ v.
-}
matVec : Tensor k d (R1 b) -> Tensor k d (R2 a b) -> Tensor k d (R1 a)
matVec v m =
    wrap (O.matmul (un m) (un v))


{-| The inner product of two vectors: `x |> dot y`.
-}
dot : Tensor k d (R1 a) -> Tensor k d (R1 a) -> Tensor k d R0
dot y x =
    wrap (O.matmul (un x) (un y))


{-| `x |> outer y`: `x[i] * y[j]`.
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


{-| The sum along an axis, which the result drops: `x |> sum Axis.axis1of2`.
-}
sum : Axis s r c -> Tensor k d s -> Tensor k d r
sum (I.Axis i) =
    map1 (O.reduce ReduceSum i)


{-| The mean along an axis, which the result drops.
-}
mean : Axis s r c -> Tensor Float d s -> Tensor Float d r
mean (I.Axis i) =
    map1 (O.reduce ReduceMean i)


{-| The largest value along an axis, which the result drops.
-}
maximum : Axis s r c -> Tensor k d s -> Tensor k d r
maximum (I.Axis i) =
    map1 (O.reduce ReduceMax i)


{-| The smallest value along an axis, which the result drops.
-}
minimum : Axis s r c -> Tensor k d s -> Tensor k d r
minimum (I.Axis i) =
    map1 (O.reduce ReduceMin i)


{-| The index of the largest value along an axis, which the result drops.
-}
argMax : Axis s r c -> Tensor k d s -> Tensor Int I64 r
argMax (I.Axis i) =
    map1 (O.reduce ArgMax i)


{-| The index of the smallest value along an axis, which the result drops.
-}
argMin : Axis s r c -> Tensor k d s -> Tensor Int I64 r
argMin (I.Axis i) =
    map1 (O.reduce ArgMin i)


{-| The running sum along an axis, each element included in its own sum.
-}
cumsum : Axis s r c -> Tensor k d s -> Tensor k d s
cumsum =
    cumsumWith { exclusive = False, reverse = False }


{-| `cumsum`, optionally `exclusive` (each element left out of its own sum) or in `reverse` (summing
from the end of the axis).
-}
cumsumWith : { exclusive : Bool, reverse : Bool } -> Axis s r c -> Tensor k d s -> Tensor k d s
cumsumWith cfg (I.Axis i) =
    map1 (O.cumsum i cfg.exclusive cfg.reverse)


{-| log (sum (exp x)), stable.
-}
logSumExp : Axis s r c -> Tensor Float d s -> Tensor Float d r
logSumExp (I.Axis i) =
    map1 (O.logSumExp i)


{-| The sum of every element.
-}
sumAll : Tensor k d s -> Tensor k d R0
sumAll =
    map1 O.sumAll


{-| The mean of every element.
-}
meanAll : Tensor Float d s -> Tensor Float d R0
meanAll =
    map1 O.meanAll


{-| The largest element.
-}
maximumAll : Tensor k d s -> Tensor k d R0
maximumAll =
    map1 O.maxAll


{-| The smallest element.
-}
minimumAll : Tensor k d s -> Tensor k d R0
minimumAll =
    map1 O.minAll


{-| The smallest and the largest element.
-}
minMax : Tensor k d s -> { min : Tensor k d R0, max : Tensor k d R0 }
minMax x =
    { min = minimumAll x, max = maximumAll x }


{-| exp x / sum (exp x) along an axis: each slice along it sums to 1.
-}
softmax : Axis s r c -> Tensor Float d s -> Tensor Float d s
softmax (I.Axis i) =
    map1 (O.softmax i)


{-| log (softmax x) along an axis, computed stably.
-}
logSoftmax : Axis s r c -> Tensor Float d s -> Tensor Float d s
logSoftmax (I.Axis i) =
    map1 (O.logSoftmax i)



-- SHAPE


{-| Build time checks the element counts agree.
-}
reshape : Shape t -> Tensor k d s -> Tensor k d t
reshape (I.Shape s) =
    map1 (O.reshape s)


{-| Every element in one axis, in row-major order.
-}
flatten : Dim m -> Tensor k d s -> Tensor k d (R1 m)
flatten (I.Dim m) =
    map1 (O.reshape [ m ])


keepFirst : Int -> List Int -> Expr -> Expr
keepFirst n tail x =
    O.reshape (List.take n (E.shape x) ++ tail) x


{-| Everything after the first axis as one axis (a batch of images to a batch of vectors).
-}
flattenTail3 : Dim m -> Tensor k d (R3 n a b) -> Tensor k d (R2 n m)
flattenTail3 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| `flattenTail3` for rank 4 (a batch of multi-channel images to a batch of vectors).
-}
flattenTail4 : Dim m -> Tensor k d (R4 n a b c) -> Tensor k d (R2 n m)
flattenTail4 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| A vector as a matrix of the two dimensions, row-major (build time checks the sizes agree).
-}
factorLast2 : Dim a -> Dim b -> Tensor k d (R1 m) -> Tensor k d (R2 a b)
factorLast2 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 0 [ a, b ])


{-| The last axis split into two, row-major: the inverse of `mergeLast3`.
-}
factorLast3 : Dim a -> Dim b -> Tensor k d (R2 x m) -> Tensor k d (R3 x a b)
factorLast3 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 1 [ a, b ])


{-| The last axis split into two, row-major: the inverse of `mergeLast4`.
-}
factorLast4 : Dim a -> Dim b -> Tensor k d (R3 x y m) -> Tensor k d (R4 x y a b)
factorLast4 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 2 [ a, b ])


{-| A matrix as a vector, row-major: the inverse of `factorLast2`.
-}
mergeLast2 : Dim m -> Tensor k d (R2 a b) -> Tensor k d (R1 m)
mergeLast2 (I.Dim m) =
    map1 (keepFirst 0 [ m ])


{-| The last two axes as one, row-major (heads × head size back to the model width).
-}
mergeLast3 : Dim m -> Tensor k d (R3 x a b) -> Tensor k d (R2 x m)
mergeLast3 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


{-| The last two axes as one, row-major.
-}
mergeLast4 : Dim m -> Tensor k d (R4 x y a b) -> Tensor k d (R3 x y m)
mergeLast4 (I.Dim m) =
    map1 (keepFirst 2 [ m ])


{-| Swap a matrix's rows and columns.
-}
transpose : Tensor k d (R2 a b) -> Tensor k d (R2 b a)
transpose =
    map1 (O.transpose [ 1, 0 ])


{-| The permutation the swaps make: result axis k reads operand axis `p[k]`.
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


{-| Reorder the axes: `x |> permute Axis.swap12of4`.
-}
permute : Perm s t -> Tensor k d s -> Tensor k d t
permute (I.Perm swaps) =
    map1 (\x -> O.transpose (permutation (E.rank x) swaps) x)


{-| An axis of size 1 that the next element-wise operation broadcasts to its partner's size.
Anything else meeting it unsized is a build error.
-}
broadcast : Axis t s c -> Tensor k d s -> Tensor k d t
broadcast (I.Axis i) =
    map1 (O.broadcastAxis i)


{-| A new axis at the given position, every slice along it a copy of the operand.
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


{-| The vector as every row of a matrix (`plus (rows bias)`).
-}
rows : Tensor k d (R1 b) -> Tensor k d (R2 a b)
rows =
    map1 (O.broadcastAxis 0)


{-| The vector as every column of a matrix.
-}
columns : Tensor k d (R1 a) -> Tensor k d (R2 a b)
columns =
    map1 (O.broadcastAxis 1)


{-| A new axis of size 1 (tagged `One`) at the given position.
-}
insertOne : Axis t s One -> Tensor k d s -> Tensor k d t
insertOne (I.Axis i) =
    map1 (O.insertAxis i)


{-| Drop an axis of size 1.
-}
dropOne : Axis s r One -> Tensor k d s -> Tensor k d r
dropOne (I.Axis i) =
    map1 (O.dropAxis i)


at : Int -> List Int -> Int
at i l =
    List.head (List.drop i l) |> Maybe.withDefault 0


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


expectSize : Int -> Int -> String -> Expr -> Expr
expectSize axis c what e =
    if E.poisoned e || at axis (E.shape e) == c then
        e

    else
        E.failWith (what ++ ": the result has " ++ String.fromInt (at axis (E.shape e)) ++ " along axis " ++ String.fromInt axis ++ ", but its dimension says " ++ String.fromInt c) e


{-| `slice retag start size`: `size` elements along one axis from `start`.
-}
slice : Retag s t a c -> Int -> Dim c -> Tensor k d s -> Tensor k d t
slice (I.Retag i) start (I.Dim c) =
    map1 (\x -> O.slice (setAt i start (List.map (\_ -> 0) (E.shape x))) (setAt i c (E.shape x)) x)


{-| `x |> sliceUpdate retag start update`: x with the slice from `start` replaced.
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

    else
        wrap (O.concat i pieces)


{-| The tensors one after another along one axis; the dimension is the total size (checked).
-}
concat : Retag s t a c -> Dim c -> List (Tensor k d s) -> Tensor k d t
concat (I.Retag i) (I.Dim c) xs =
    wrap (expectSize i c "concat" (O.concat i (List.map un xs)))


{-| `concat2 rx ry size x y`: x then y along one axis (not a pipeline operation).
-}
concat2 : Retag s t a c -> Retag u t b c -> Dim c -> Tensor k d s -> Tensor k d u -> Tensor k d t
concat2 (I.Retag i) _ (I.Dim c) x y =
    wrap (expectSize i c "concat2" (O.concat i [ un x, un y ]))


{-| Equal chunks of `size` along one axis (build time checks `size` divides the axis).
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


{-| Build time checks the list's length against `n`.
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


{-| The slices along the leading axis: the inverse of `stack`.
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


{-| The elements along an axis in reverse order.
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


{-| `before` and `after` elements of `value` around one axis; the dimension is the padded size
(checked).
-}
pad : Retag s t a c -> { before : Int, after : Int, value : Float } -> Dim c -> Tensor Float d s -> Tensor Float d t
pad (I.Retag i) cfg (I.Dim c) =
    map1 (\x -> expectSize i c "pad" (O.pad i cfg.before cfg.after cfg.value x))


{-| `pad` for integer tensors: the fill value is exact and must fit the dtype.
-}
padInt : Retag s t a c -> { before : Int, after : Int, value : Int } -> Dim c -> Tensor Int d s -> Tensor Int d t
padInt (I.Retag i) cfg (I.Dim c) =
    map1 (\x -> expectSize i c "padInt" (O.padInt i cfg.before cfg.after cfg.value x))


{-| Gather along one axis: `x |> take retag indices`.
-}
take : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d s -> Tensor k d t
take (I.Retag i) idx =
    map1 (\x -> O.gather i x (O.cast SI64 (un idx)))


{-| The rows at the indices, in their order (an embedding lookup): `table |> rowsAt ids`.
-}
rowsAt : Tensor Int i (R1 n) -> Tensor k d (R2 v m) -> Tensor k d (R2 n m)
rowsAt idx =
    map1 (\x -> O.gather 0 x (O.cast SI64 (un idx)))


{-| One element per row: `x |> pick indices` is x[i, indices[i]].
-}
pick : Tensor Int i (R1 n) -> Tensor k d (R2 n c) -> Tensor k d (R1 n)
pick idx =
    map1 (O.pick (un idx))


{-| `x |> put retag indices updates`: x with the slices at `indices` replaced.
-}
put : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
put (I.Retag i) idx upd =
    map1 (\x -> O.scatterAxis i x (un upd) (O.cast SI64 (un idx)))


{-| The same, adding the updates (repeated indices add up).
-}
putAdd : Retag s t a c -> Tensor Int i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
putAdd (I.Retag i) idx upd =
    map1 (\x -> O.scatterAxisAdd i x (un upd) (O.cast SI64 (un idx)))


{-| Zero below the k-th diagonal.
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


{-| Zero above the k-th diagonal.
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


{-| The same value, but no gradient flows back through it.
-}
stopGradient : Tensor k d s -> Tensor k d s
stopGradient =
    map1 O.stopGradient


{-| `x |> quickGelu`: x · sigmoid(1.702 x), the GELU approximation CLIP uses.
-}
quickGelu : Tensor Float d s -> Tensor Float d s
quickGelu =
    map1 (\e -> O.mul e (O.unary P.Sigmoid (O.mul e (O.scalarLike 1.702 e))))


{-| The `k` largest values along the retagged axis, largest first, and their indices:
`logits |> topK Axis.retag1of2 (T.dim Top 5)`. No gradient (differentiating it is refused).
-}
topK : Retag s t a c -> Dim c -> Tensor k d s -> ( Tensor k d t, Tensor Int I64 t )
topK (I.Retag i) (I.Dim k) x =
    let
        ( v, ix ) =
            O.topK True i k (un x)
    in
    ( wrap v, wrap ix )


{-| The `k` smallest, smallest first, and their indices.
-}
bottomK : Retag s t a c -> Dim c -> Tensor k d s -> ( Tensor k d t, Tensor Int I64 t )
bottomK (I.Retag i) (I.Dim k) x =
    let
        ( v, ix ) =
            O.topK False i k (un x)
    in
    ( wrap v, wrap ix )


{-| The values along an axis in order, and the indices they came from (`take` with them gives the
sorted values back). No gradient. On a GPU only the last axis can be sorted.
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
    ( wrap v, wrap ix )
