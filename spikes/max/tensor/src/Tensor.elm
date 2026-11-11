module Tensor exposing
    ( Tensor, Mask, Dim, Shape, DType, Axis, Retag, Lift, Perm
    , R0, R1, R2, R3, R4, R5, One, Elems
    , Floating, Integral, F16, BF16, F32, F64, I8, I32, I64, U8, U64
    , float16, bfloat16, float32, float64, int8, int32, int64, uint8, uint64
    , dim, one, size, scalar, r1, r2, r3, r4, r5, shapeOf, dtypeName
    , float, int, constant, fillLike, zeros, ones, full, fromList, zerosLike, onesLike, fullLike, iota, arange, hannWindow
    , cast, castLike, toFloat, toInt
    , abs, negate, sign, exp, log, log1p, sqrt, rsqrt, sin, cos, acos, atanh, erf, floor, round, truncate
    , relu, sigmoid, tanh, gelu, geluTanh, silu, isInfinite, isNaN
    , plus, minus, times, dividedBy, modBy, pow, max, min, scale, shift
    , equals, notEquals, greaterThan, atLeast, lessThan, atMost
    , and, or, xor, not, select, indicator, maskBroadcast
    , matmul, matmul3, matmul4, matmul3By2, vecMat, matVec, dot, outer
    , sum, mean, maximum, minimum, argMax, argMin, cumsum, cumsumWith, logSumExp
    , sumAll, meanAll, maximumAll, minimumAll, minMax
    , softmax, logSoftmax
    , reshape, flatten, flattenTail3, flattenTail4, factorLast2, factorLast3, factorLast4, mergeLast2, mergeLast3, mergeLast4
    , transpose, permute, broadcast, broadcastTo, rows, columns, insertOne, dropOne
    , slice, sliceUpdate, concat, concat2, chunks, stack, unstack, flip, pad
    , take, rowsAt, pick, put, putAdd, triu, tril, lowerTriangle
    , stopGradient
    )

{-| Tensors as values, typed by kind, dtype and shape.

A `Tensor kind dtype shape` is an immutable expression: nothing is computed until a `Graph` is built
and run by MAX. The shape is a fixed-rank type of named dimensions, `R2 Batch Hidden`, so mixing up
dimensions, axes or dtypes is a compile error; sizes the types cannot compute are checked when the
graph is built.

Pipelines read left to right: `x |> plus y` is x + y, `x |> matmul w` is x @ w.

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I



-- TYPES


type alias Tensor kind dtype shape =
    I.Tensor kind dtype shape


type alias Mask shape =
    I.Mask shape


type alias Dim tag =
    I.Dim tag


type alias Shape s =
    I.Shape s


type alias DType kind dtype =
    I.DType kind dtype


type alias Axis s r c =
    I.Axis s r c


type alias Retag s t a c =
    I.Retag s t a c


type alias Lift n s t =
    I.Lift n s t


type alias Perm s t =
    I.Perm s t


type alias R0 =
    I.R0


type alias R1 a =
    I.R1 a


type alias R2 a b =
    I.R2 a b


type alias R3 a b c =
    I.R3 a b c


type alias R4 a b c d =
    I.R4 a b c d


type alias R5 a b c d e =
    I.R5 a b c d e


type alias One =
    I.One


{-| The shape an element-wise update sees (`Optim.custom`, `Param.mapElems`): only rank-free
operations apply to it.
-}
type alias Elems =
    I.Elems


type alias Floating =
    I.Floating


type alias Integral =
    I.Integral


type alias F16 =
    I.F16


type alias BF16 =
    I.BF16


type alias F32 =
    I.F32


type alias F64 =
    I.F64


type alias I8 =
    I.I8


type alias I32 =
    I.I32


type alias I64 =
    I.I64


type alias U8 =
    I.U8


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


float16 : DType Floating F16
float16 =
    I.DType F16


bfloat16 : DType Floating BF16
bfloat16 =
    I.DType BF16


float32 : DType Floating F32
float32 =
    I.DType F32


float64 : DType Floating F64
float64 =
    I.DType F64


int8 : DType Integral I8
int8 =
    I.DType SI8


int32 : DType Integral I32
int32 =
    I.DType SI32


int64 : DType Integral I64
int64 =
    I.DType SI64


uint8 : DType Integral U8
uint8 =
    I.DType UI8


uint64 : DType Integral U64
uint64 =
    I.DType UI64


dt : DType k d -> DT
dt (I.DType d) =
    d



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


size : Dim tag -> Int
size (I.Dim n) =
    n


scalar : Shape R0
scalar =
    I.Shape []


r1 : Dim a -> Shape (R1 a)
r1 (I.Dim a) =
    I.Shape [ a ]


r2 : Dim a -> Dim b -> Shape (R2 a b)
r2 (I.Dim a) (I.Dim b) =
    I.Shape [ a, b ]


r3 : Dim a -> Dim b -> Dim c -> Shape (R3 a b c)
r3 (I.Dim a) (I.Dim b) (I.Dim c) =
    I.Shape [ a, b, c ]


r4 : Dim a -> Dim b -> Dim c -> Dim d -> Shape (R4 a b c d)
r4 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) =
    I.Shape [ a, b, c, d ]


r5 : Dim a -> Dim b -> Dim c -> Dim d -> Dim e -> Shape (R5 a b c d e)
r5 (I.Dim a) (I.Dim b) (I.Dim c) (I.Dim d) (I.Dim e) =
    I.Shape [ a, b, c, d, e ]


{-| The sizes, known when the tensor is made (1 at a broadcast axis not yet sized).
-}
shapeOf : Tensor k d s -> List Int
shapeOf x =
    E.shape (un x)


dtypeName : Tensor k d s -> String
dtypeName x =
    P.dtName (E.dtype (un x))



-- CONSTRUCTION


float : Float -> Tensor Floating F32 R0
float f =
    wrap (E.scalar F32 f)


int : Int -> Tensor Integral I64 R0
int n =
    wrap (E.scalar SI64 (Basics.toFloat n))


constant : DType k d -> Float -> Tensor k d R0
constant d v =
    wrap (E.scalar (dt d) v)


{-| A scalar spread to the shape of a template: `fillLike rate grad`.
-}
fillLike : Tensor k d R0 -> Tensor k d s -> Tensor k d s
fillLike c x =
    wrap (O.broadcastTo (E.shape (un x)) (un c))


full : DType k d -> Float -> Shape s -> Tensor k d s
full d v (I.Shape s) =
    wrap (O.broadcastTo s (E.scalar (dt d) v))


zeros : DType k d -> Shape s -> Tensor k d s
zeros d =
    full d 0


ones : DType k d -> Shape s -> Tensor k d s
ones d =
    full d 1


{-| Row-major values; their number must be the shape's size (checked when the graph is built).
-}
fromList : DType k d -> Shape s -> List Float -> Tensor k d s
fromList d (I.Shape s) values =
    wrap (E.const (dt d) s values)


zerosLike : Tensor k d s -> Tensor k d s
zerosLike =
    map1 O.zerosLike


onesLike : Tensor k d s -> Tensor k d s
onesLike =
    map1 O.onesLike


fullLike : Float -> Tensor k d s -> Tensor k d s
fullLike v =
    map1 (O.fullLike v)


{-| 0, 1 .. n - 1.
-}
iota : Dim n -> Tensor Integral I64 (R1 n)
iota (I.Dim n) =
    wrap (O.range 0 1 n)


arange : { start : Int, step : Int } -> Dim n -> Tensor Integral I64 (R1 n)
arange r (I.Dim n) =
    wrap (O.range r.start r.step n)


{-| w[i] = ½ (1 - cos (2π i / N)), N = n if periodic, else n - 1.
-}
hannWindow : { periodic : Bool } -> DType Floating d -> Dim n -> Tensor Floating d (R1 n)
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


cast : DType k d -> Tensor k0 d0 s -> Tensor k d s
cast d =
    map1 (O.cast (dt d))


castLike : Tensor k d t -> Tensor k0 d0 s -> Tensor k d s
castLike t =
    map1 (O.cast (E.dtype (un t)))


toFloat : Tensor k d s -> Tensor Floating F32 s
toFloat =
    map1 (O.cast F32)


toInt : Tensor k d s -> Tensor Integral I64 s
toInt =
    map1 (O.cast SI64)



-- ELEMENT-WISE


abs : Tensor k d s -> Tensor k d s
abs =
    map1 (O.unary Abs)


negate : Tensor k d s -> Tensor k d s
negate =
    map1 O.neg


sign : Tensor k d s -> Tensor k d s
sign =
    map1 O.sign


exp : Tensor Floating d s -> Tensor Floating d s
exp =
    map1 (O.unary Exp)


log : Tensor Floating d s -> Tensor Floating d s
log =
    map1 (O.unary Log)


log1p : Tensor Floating d s -> Tensor Floating d s
log1p =
    map1 (O.unary Log1p)


sqrt : Tensor Floating d s -> Tensor Floating d s
sqrt =
    map1 (O.unary Sqrt)


rsqrt : Tensor Floating d s -> Tensor Floating d s
rsqrt =
    map1 (O.unary Rsqrt)


sin : Tensor Floating d s -> Tensor Floating d s
sin =
    map1 (O.unary Sin)


cos : Tensor Floating d s -> Tensor Floating d s
cos =
    map1 (O.unary Cos)


acos : Tensor Floating d s -> Tensor Floating d s
acos =
    map1 (O.unary Acos)


atanh : Tensor Floating d s -> Tensor Floating d s
atanh =
    map1 (O.unary Atanh)


erf : Tensor Floating d s -> Tensor Floating d s
erf =
    map1 (O.unary Erf)


floor : Tensor Floating d s -> Tensor Floating d s
floor =
    map1 (O.unary Floor)


{-| Half to even.
-}
round : Tensor Floating d s -> Tensor Floating d s
round =
    map1 (O.unary Round)


truncate : Tensor Floating d s -> Tensor Floating d s
truncate =
    map1 (O.unary Trunc)


relu : Tensor k d s -> Tensor k d s
relu =
    map1 (O.unary Relu)


sigmoid : Tensor Floating d s -> Tensor Floating d s
sigmoid =
    map1 (O.unary Sigmoid)


tanh : Tensor Floating d s -> Tensor Floating d s
tanh =
    map1 (O.unary Tanh)


{-| x Φ(x), exact.
-}
gelu : Tensor Floating d s -> Tensor Floating d s
gelu =
    map1 (O.unary Gelu)


geluTanh : Tensor Floating d s -> Tensor Floating d s
geluTanh =
    map1 (O.unary GeluTanh)


silu : Tensor Floating d s -> Tensor Floating d s
silu =
    map1 (O.unary Silu)


isInfinite : Tensor Floating d s -> Mask s
isInfinite x =
    mask (O.unary IsInf (un x))


isNaN : Tensor Floating d s -> Mask s
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


times : Tensor k d s -> Tensor k d s -> Tensor k d s
times =
    map2 O.mul


{-| `x |> dividedBy y` is x / y.
-}
dividedBy : Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d s
dividedBy =
    map2 O.div


{-| `x |> modBy m`: the remainder with the sign of `m`, as `Basics.modBy`.
-}
modBy : Tensor Integral d s -> Tensor Integral d s -> Tensor Integral d s
modBy =
    map2 (O.binary Mod)


{-| `x |> pow y` is x ** y.
-}
pow : Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d s
pow =
    map2 (O.binary Pow)


{-| Element-wise: `x |> max y`. (`maximum` is the reduction, as `List.maximum` is.)
-}
max : Tensor k d s -> Tensor k d s -> Tensor k d s
max =
    map2 (O.binary Max2)


min : Tensor k d s -> Tensor k d s -> Tensor k d s
min =
    map2 (O.binary Min2)


{-| `x |> scale k` is x * k.
-}
scale : Float -> Tensor Floating d s -> Tensor Floating d s
scale k =
    map1 (\x -> O.mul x (O.scalarLike k x))


{-| `x |> shift k` is x + k.
-}
shift : Float -> Tensor Floating d s -> Tensor Floating d s
shift k =
    map1 (\x -> O.add x (O.scalarLike k x))



-- COMPARISONS AND MASKS


compare : (Expr -> Expr -> Expr) -> Tensor k d s -> Tensor k d s -> Mask s
compare f y x =
    mask (f (un x) (un y))


equals : Tensor k d s -> Tensor k d s -> Mask s
equals =
    compare O.eq


notEquals : Tensor k d s -> Tensor k d s -> Mask s
notEquals =
    compare O.ne


{-| `x |> greaterThan y` is x > y.
-}
greaterThan : Tensor k d s -> Tensor k d s -> Mask s
greaterThan =
    compare O.gt


atLeast : Tensor k d s -> Tensor k d s -> Mask s
atLeast =
    compare O.ge


lessThan : Tensor k d s -> Tensor k d s -> Mask s
lessThan =
    compare O.lt


atMost : Tensor k d s -> Tensor k d s -> Mask s
atMost =
    compare O.le


and : Mask s -> Mask s -> Mask s
and (I.Mask y) (I.Mask x) =
    mask (O.and_ x y)


or : Mask s -> Mask s -> Mask s
or (I.Mask y) (I.Mask x) =
    mask (O.or_ x y)


xor : Mask s -> Mask s -> Mask s
xor (I.Mask y) (I.Mask x) =
    mask (O.binary Xor x y)


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


matmul3 : Tensor k d (R3 n b c) -> Tensor k d (R3 n a b) -> Tensor k d (R3 n a c)
matmul3 w x =
    wrap (O.matmul (un x) (un w))


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


dot : Tensor k d (R1 a) -> Tensor k d (R1 a) -> Tensor k d R0
dot y x =
    wrap (O.matmul (un x) (un y))


{-| `x |> outer y`: x[i] * y[j].
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


sum : Axis s r c -> Tensor k d s -> Tensor k d r
sum (I.Axis i) =
    map1 (O.reduce ReduceSum i)


mean : Axis s r c -> Tensor Floating d s -> Tensor Floating d r
mean (I.Axis i) =
    map1 (O.reduce ReduceMean i)


maximum : Axis s r c -> Tensor k d s -> Tensor k d r
maximum (I.Axis i) =
    map1 (O.reduce ReduceMax i)


minimum : Axis s r c -> Tensor k d s -> Tensor k d r
minimum (I.Axis i) =
    map1 (O.reduce ReduceMin i)


argMax : Axis s r c -> Tensor k d s -> Tensor Integral I64 r
argMax (I.Axis i) =
    map1 (O.reduce ArgMax i)


argMin : Axis s r c -> Tensor k d s -> Tensor Integral I64 r
argMin (I.Axis i) =
    map1 (O.reduce ArgMin i)


cumsum : Axis s r c -> Tensor k d s -> Tensor k d s
cumsum =
    cumsumWith { exclusive = False, reverse = False }


cumsumWith : { exclusive : Bool, reverse : Bool } -> Axis s r c -> Tensor k d s -> Tensor k d s
cumsumWith cfg (I.Axis i) =
    map1 (O.cumsum i cfg.exclusive cfg.reverse)


{-| log (sum (exp x)), stable.
-}
logSumExp : Axis s r c -> Tensor Floating d s -> Tensor Floating d r
logSumExp (I.Axis i) =
    map1 (O.logSumExp i)


sumAll : Tensor k d s -> Tensor k d R0
sumAll =
    map1 O.sumAll


meanAll : Tensor Floating d s -> Tensor Floating d R0
meanAll =
    map1 O.meanAll


maximumAll : Tensor k d s -> Tensor k d R0
maximumAll =
    map1 O.maxAll


minimumAll : Tensor k d s -> Tensor k d R0
minimumAll =
    map1 O.minAll


minMax : Tensor k d s -> { min : Tensor k d R0, max : Tensor k d R0 }
minMax x =
    { min = minimumAll x, max = maximumAll x }


softmax : Axis s r c -> Tensor Floating d s -> Tensor Floating d s
softmax (I.Axis i) =
    map1 (O.softmax i)


logSoftmax : Axis s r c -> Tensor Floating d s -> Tensor Floating d s
logSoftmax (I.Axis i) =
    map1 (O.logSoftmax i)



-- SHAPE


{-| Build time checks the element counts agree.
-}
reshape : Shape t -> Tensor k d s -> Tensor k d t
reshape (I.Shape s) =
    map1 (O.reshape s)


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


flattenTail4 : Dim m -> Tensor k d (R4 n a b c) -> Tensor k d (R2 n m)
flattenTail4 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


factorLast2 : Dim a -> Dim b -> Tensor k d (R1 m) -> Tensor k d (R2 a b)
factorLast2 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 0 [ a, b ])


factorLast3 : Dim a -> Dim b -> Tensor k d (R2 x m) -> Tensor k d (R3 x a b)
factorLast3 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 1 [ a, b ])


factorLast4 : Dim a -> Dim b -> Tensor k d (R3 x y m) -> Tensor k d (R4 x y a b)
factorLast4 (I.Dim a) (I.Dim b) =
    map1 (keepFirst 2 [ a, b ])


mergeLast2 : Dim m -> Tensor k d (R2 a b) -> Tensor k d (R1 m)
mergeLast2 (I.Dim m) =
    map1 (keepFirst 0 [ m ])


mergeLast3 : Dim m -> Tensor k d (R3 x a b) -> Tensor k d (R2 x m)
mergeLast3 (I.Dim m) =
    map1 (keepFirst 1 [ m ])


mergeLast4 : Dim m -> Tensor k d (R4 x y a b) -> Tensor k d (R3 x y m)
mergeLast4 (I.Dim m) =
    map1 (keepFirst 2 [ m ])


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


permute : Perm s t -> Tensor k d s -> Tensor k d t
permute (I.Perm swaps) =
    map1 (\x -> O.transpose (permutation (E.rank x) swaps) x)


{-| An axis of size 1 that the next element-wise operation broadcasts to its partner's size.
Anything else meeting it unsized is a build error.
-}
broadcast : Axis t s c -> Tensor k d s -> Tensor k d t
broadcast (I.Axis i) =
    map1 (O.broadcastAxis i)


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


columns : Tensor k d (R1 a) -> Tensor k d (R2 a b)
columns =
    map1 (O.broadcastAxis 1)


insertOne : Axis t s One -> Tensor k d s -> Tensor k d t
insertOne (I.Axis i) =
    map1 (O.insertAxis i)


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


pad : Retag s t a c -> { before : Int, after : Int, value : Float } -> Dim c -> Tensor k d s -> Tensor k d t
pad (I.Retag i) cfg (I.Dim c) =
    map1 (\x -> expectSize i c "pad" (O.pad i cfg.before cfg.after cfg.value x))


{-| Gather along one axis: `x |> take retag indices`.
-}
take : Retag s t a c -> Tensor Integral i (R1 c) -> Tensor k d s -> Tensor k d t
take (I.Retag i) idx =
    map1 (\x -> O.gather i x (O.cast SI64 (un idx)))


rowsAt : Tensor Integral i (R1 n) -> Tensor k d (R2 v m) -> Tensor k d (R2 n m)
rowsAt idx =
    map1 (\x -> O.gather 0 x (O.cast SI64 (un idx)))


{-| One element per row: `x |> pick indices` is x[i, indices[i]].
-}
pick : Tensor Integral i (R1 n) -> Tensor k d (R2 n c) -> Tensor k d (R1 n)
pick idx =
    map1 (O.pick (un idx))


toFrontPerm : Int -> Int -> List Int
toFrontPerm i r =
    i :: List.filter ((/=) i) (List.range 0 (r - 1))


inverse : List Int -> List Int
inverse p =
    List.indexedMap Tuple.pair p |> List.sortBy Tuple.second |> List.map Tuple.first


scatterAlong : (Expr -> Expr -> Expr -> Expr) -> Int -> Expr -> Expr -> Expr -> Expr
scatterAlong f i idx upd x =
    let
        p =
            toFrontPerm i (E.rank x)
    in
    O.transpose (inverse p) (f (O.transpose p x) (O.transpose p upd) (O.cast SI64 idx))


{-| `x |> put retag indices updates`: x with the slices at `indices` replaced.
-}
put : Retag s t a c -> Tensor Integral i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
put (I.Retag i) idx upd =
    map1 (scatterAlong O.scatterRows i (un idx) (un upd))


{-| The same, adding the updates (repeated indices add up).
-}
putAdd : Retag s t a c -> Tensor Integral i (R1 c) -> Tensor k d t -> Tensor k d s -> Tensor k d s
putAdd (I.Retag i) idx upd =
    map1 (scatterAlong O.scatterRowsAdd i (un idx) (un upd))


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


stopGradient : Tensor k d s -> Tensor k d s
stopGradient =
    map1 O.stopGradient
