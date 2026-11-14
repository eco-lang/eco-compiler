module Tensor.Internal.Eval.Prim exposing (apply)

{-| The evaluator runs expressions in plain Elm instead of on MAX, and this module holds the
semantics of every primitive there: `apply` takes a primitive, the values of its operands, its
params and the meta of its result, and computes the result.

`apply` expects the meta to be the shape and dtype `Tensor.Internal.Shape.rule` gives for the
primitive and its operands, and relies on it instead of checking again. The result takes its shape
from the meta, and its dtype too, apart from the few primitives `apply` lists. Operand shapes are
not compared here, and a read outside an operand through `Tensor.Internal.Eval.Core`'s `getF` or
`getI` gives 0 rather than an error. Some of the errors `apply` returns are about element values,
which no shape rule sees: an index outside its axis in a gather or scatter, an integer `Mod` by
zero, a float cast to an integer dtype that cannot hold it, and, under JavaScript only, an `si64` or
`ui64` result that no `Int` there holds exactly (described below). A random draw of more than 2³¹
elements is also refused, and so is a convolution with a stride below 1. The rest refuse operands
or params of an unexpected form. Every message
begins with the primitive's `Tensor.Internal.Prim.name` and `": "`, as in
`"modBy: integer division by zero"`.

Element values are held as `Tensor.Internal.Eval.Core` describes. A float is an f64 whatever its
dtype, and nothing here rounds it to the dtype, a cast to a float dtype included.

Integer results wrap as fixed-width two's complement arithmetic wraps them, and are meant to be the
same under JavaScript, where an `Int` is a double that holds every integer only up to 2⁵³, as
natively, where it has 64 bits. For `si8`, `ui8`, `si32` and `bool` the arithmetic is done on
`Int`s, with products taken modulo 2³² (`U64.mulLow32`) so that none passes 2⁵³, and the result is
passed through `wrapInt`: once per element for an element-wise primitive, once per lane
(`Tensor.Internal.Eval.Core`'s term for the elements along one axis at fixed indices on every other
axis) for a sum or a mean, and at every step of a dot product, a cumulative sum or a scatter that
adds. For `si64` and `ui64` the sums, differences, products, means and dot products are those of
`Tensor.Internal.Eval.U64`, exact modulo 2⁶⁴. Natively every such result is an `Int`; under
JavaScript one past 2⁵³ that no double holds exactly is refused, with a message saying so, rather
than rounded. Other primitives on `si64` and `ui64`, such as a negation or a cast, pass their
result through `wrapInt`, which wraps it modulo 2⁶⁴. A `ui64` element is ordered as an unsigned
number, its remainder and its mean are taken as one, and equality compares the bits. An integer
mean is the lane's sum, wrapped for `si64` and `ui64`, divided by its length and rounded toward
zero.

Most of the care in the float rules is about NaN. The module takes MAX on the CPU to treat NaN as
follows, and does the same: the comparisons `Gt`, `Ge`, `Eq` and `Ne` are false when either operand
is NaN, `Ne` included; `Max2`, `Min2`, `ReduceMax`, `ReduceMin` and `MaxPool` ignore NaN, and give
NaN only when every value they compare is NaN; and `ArgMax` and `ArgMin` skip NaN. Beyond that,
top-k ranks NaN above every number, `Relu` keeps NaN, and a cast to a mask (a `bool` tensor) makes
NaN true. Sums, means, cumulative sums, average pooling and softmax treat NaN no differently from
any other number, so it reaches their results through the arithmetic. Under JavaScript Elm compares
two variables through a function that answers "greater" whenever either is NaN, so `x > y` is true
when either is NaN; the rules above therefore test for NaN explicitly instead of relying on a
comparison.

-}

import Array exposing (Array)
import Tensor.Internal.Eval.Core as C exposing (Data(..), T, getF, getI)
import Tensor.Internal.Eval.Math as M
import Tensor.Internal.Eval.Random as R
import Tensor.Internal.Eval.U64 as U64
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))
import Tensor.Internal.Shape exposing (Meta)


{-| The outcome of computing a primitive: the run-time tensor, or a message saying why it could not
be computed.
-}
type alias Out =
    Result String T


{-| Returns the value of primitive `p` applied to the operand values `args` with params `params`,
where `out` is the meta of the result, or a message beginning with `p`'s name and `": "`.

The result has `out`'s shape and dtype, except that some primitives set their own: `Eq`, `Ne`,
`Gt`, `Ge`, `IsInf` and `IsNaN` give `bool`; `ArgMax`, `ArgMin`, `TopKIndices` and `Range` give
`si64`; `Reshape` and `StopGradient` keep the operand's dtype; and `XentLogits` gives the shape
`[]`. A primitive given a number of operands it does not take is refused.

-}
apply : Prim -> List T -> Params -> Meta -> Out
apply p args params out =
    let
        fail msg =
            Err (P.name p ++ ": " ++ msg)
    in
    case P.family p of
        P.Unary ->
            case args of
                [ x ] ->
                    unary p x params out |> Result.mapError (\m -> P.name p ++ ": " ++ m)

                _ ->
                    fail "expects one operand"

        P.Binary ->
            case args of
                [ a, b ] ->
                    binary p a b out |> Result.mapError (\m -> P.name p ++ ": " ++ m)

                _ ->
                    fail "expects two operands"

        P.Ternary ->
            case args of
                [ c, x, y ] ->
                    Ok (select c x y out)

                _ ->
                    fail "expects three operands"

        P.Other ->
            other p args params out |> Result.mapError (\m -> P.name p ++ ": " ++ m)



-- ELEMENT-WISE


{-| Returns `f` applied to every element of a float tensor, with the meta's dtype and shape, or a
message refusing integer data.
-}
mapF : (Float -> Float) -> T -> Meta -> Out
mapF f x out =
    case x.data of
        F a ->
            Ok { dt = out.dtype, shape = out.shape, data = F (Array.map f a) }

        I _ ->
            Err ("needs a floating-point tensor, not " ++ P.dtName x.dt)


{-| Returns the mask of `f` applied to every element of a float tensor, with the meta's shape, or a
message refusing integer data.
-}
boolsF : (Float -> Bool) -> T -> Meta -> Out
boolsF f x out =
    case x.data of
        F a ->
            Ok { dt = Bool, shape = out.shape, data = I (Array.map (f >> fromBool) a) }

        I _ ->
            Err ("needs a floating-point tensor, not " ++ P.dtName x.dt)


{-| Returns the mask element for `b`: 1 for `True` and 0 for `False`.
-}
fromBool : Bool -> Int
fromBool b =
    if b then
        1

    else
        0


{-| Returns `x` with the meta's dtype and shape, and with `f` applied to each element of float
data, or `g` applied to each element of integer data and the result wrapped to the meta's dtype.
-}
mapBoth : (Float -> Float) -> (Int -> Int) -> T -> Meta -> T
mapBoth f g x out =
    { dt = out.dtype
    , shape = out.shape
    , data =
        case x.data of
            F a ->
                F (Array.map f a)

            I a ->
                I (Array.map (g >> C.wrapInt out.dtype) a)
    }


{-| Returns the value of a one-operand element-wise primitive, or a message.

The primitives that need a float operand refuse integer data. `Abs` is the identity on `ui8`,
`ui64` and `bool`, and `Relu` on `ui8` and `ui64`; on other integers both are wrapped, so `Abs` of
the `si8` −128 is −128. On floats `Relu` gives 0 for anything not above 0, but keeps NaN. `Round`
rounds a value halfway between two whole numbers to the even one. `Not` is 1 − n on a mask's
elements. `StopGradient` returns the operand unchanged but for the meta's shape.

-}
unary : Prim -> T -> Params -> Meta -> Out
unary p x params out =
    case p of
        Abs ->
            Ok
                (mapBoth Basics.abs
                    (if x.dt == UI64 || x.dt == UI8 || x.dt == Bool then
                        identity

                     else
                        Basics.abs
                    )
                    x
                    out
                )

        Neg ->
            Ok (mapBoth Basics.negate Basics.negate x out)

        Exp ->
            mapF M.exp x out

        Log ->
            mapF M.log x out

        Log1p ->
            mapF M.log1p x out

        Sqrt ->
            mapF sqrt x out

        Rsqrt ->
            mapF (\v -> 1 / sqrt v) x out

        Sin ->
            mapF sin x out

        Cos ->
            mapF cos x out

        Acos ->
            mapF acos x out

        Atanh ->
            mapF M.atanh x out

        Erf ->
            mapF M.erf x out

        Floor ->
            mapF M.floorF x out

        Round ->
            mapF M.roundEven x out

        Trunc ->
            mapF M.truncF x out

        Relu ->
            Ok
                (mapBoth
                    (\v ->
                        if v > 0 then
                            v

                        else if isNaN v then
                            v

                        else
                            0
                    )
                    (if x.dt == UI64 || x.dt == UI8 then
                        identity

                     else
                        Basics.max 0
                    )
                    x
                    out
                )

        Sigmoid ->
            mapF M.sigmoid x out

        Tanh ->
            mapF M.tanh x out

        Gelu ->
            mapF M.gelu x out

        GeluTanh ->
            mapF M.geluTanh x out

        Silu ->
            mapF M.silu x out

        IsInf ->
            boolsF isInfinite x out

        IsNaN ->
            boolsF isNaN x out

        Not ->
            Ok (mapBoth identity (\n -> 1 - n) x out)

        Cast ->
            cast x out

        StopGradient ->
            Ok { x | shape = out.shape }

        _ ->
            Err "not a unary primitive"


{-| Returns `x` converted to the meta's dtype, or a message.

To a float dtype the elements are read with `C.floatsOf`, so a `ui64` element is read as unsigned,
and nothing is rounded to the target's precision. To `bool` an element is true when it is not 0,
and a float NaN is true as well. Between integer dtypes an element is wrapped with `wrapInt`. From a
float to an integer dtype a value is truncated toward zero; NaN, ±∞ and a value whose truncation the
dtype cannot hold are refused, and the message names the first such element.

-}
cast : T -> Meta -> Out
cast x out =
    let
        target =
            out.dtype

        done data =
            Ok { dt = target, shape = out.shape, data = data }
    in
    if P.isFloat target then
        done (F (C.floatsOf x))

    else if target == Bool then
        case x.data of
            F a ->
                done (I (Array.map (\v -> fromBool (isNaN v || v /= 0)) a))

            I a ->
                done (I (Array.map (\v -> fromBool (v /= 0)) a))

    else
        case x.data of
            I a ->
                done (I (Array.map (C.wrapInt target) a))

            F a ->
                let
                    ( lo, hi ) =
                        intRange target

                    one v =
                        if isNaN v || isInfinite v then
                            Err ("cannot convert " ++ String.fromFloat v ++ " to " ++ P.dtName target)

                        else
                            let
                                t =
                                    M.truncF v
                            in
                            if t < lo || t >= hi then
                                Err ("cannot convert " ++ String.fromFloat v ++ " to " ++ P.dtName target ++ ": out of range")

                            else if target == UI64 then
                                Ok (U64.fromFloatU t)

                            else
                                Ok (round t)
                in
                Array.foldr (\v acc -> Result.map2 (::) (one v) acc) (Ok []) a
                    |> Result.andThen (\l -> done (I (Array.fromList l)))


{-| Returns the range of an integer dtype's values as floats, the first bound included and the
second excluded. Every dtype other than `si8`, `ui8`, `si32` and `ui64` gets the range of `si64`.
-}
intRange : DT -> ( Float, Float )
intRange dt =
    case dt of
        SI8 ->
            ( -128, 128 )

        UI8 ->
            ( 0, 256 )

        SI32 ->
            ( -2147483648, 2147483648 )

        UI64 ->
            ( 0, U64.two64 )

        _ ->
            ( -(2 ^ 63), 2 ^ 63 )


{-| Returns `f` of the elements of `a` and `b` at each flat index of `shape`, in row-major order,
with `ta`'s and `tb`'s shapes broadcast to `shape` by `C.split`. `ta` and `tb` supply only those
shapes; the elements are read from `a` and `b` with `getA` and `getB`.
-}
zip2 : List Int -> T -> T -> (Array a -> Int -> x) -> Array a -> (Array b -> Int -> y) -> Array b -> (x -> y -> c) -> List c
zip2 shape ta tb getA a getB b f =
    let
        ia =
            C.split shape ta.shape

        ib =
            C.split shape tb.shape
    in
    List.map (\k -> f (getA a (ia k)) (getB b (ib k))) (List.range 0 (C.size shape - 1))


{-| Returns the values in `l`, or, when any is `Nothing`, the message that an element of a result
of dtype `dt` has no exact `Int`. Only `Tensor.Internal.Eval.U64`'s arithmetic on `si64` and `ui64`
gives `Nothing`, and only under JavaScript.
-}
allExact : DT -> List (Maybe Int) -> Result String (List Int)
allExact dt l =
    List.foldr
        (\m acc ->
            case m of
                Just v ->
                    Result.map ((::) v) acc

                Nothing ->
                    Err ("an element of the " ++ P.dtName dt ++ " result is past 2^53, where an Int under JavaScript cannot hold it exactly")
        )
        (Ok [])
        l


{-| Returns the value of a two-operand element-wise primitive, or a message.

Both operands must hold the same kind of data, floats or integers; otherwise the message is
`"dtypes differ"`.

On floats, `Mod` is x − y · ⌊x / y⌋, which is NaN when y is 0. `Max2` and `Min2` ignore a NaN
operand, giving NaN only when both are, and on equal operands, such as 0 and −0, give the first. The
comparisons are false when either operand is NaN, `Ne` included. `And`, `Or` and `Xor` are refused.

On integers, results are wrapped to the meta's dtype; `Add`, `Sub` and `Mul` on `si64` and `ui64`
are refused under JavaScript where a result has no exact `Int`. `Mod` is refused if any element of the
divisor is 0; otherwise it is `modBy`, whose result has the divisor's sign, or `U64.modU` for
`ui64`. `Max2`, `Min2`, `Gt` and `Ge` order `ui64` elements as unsigned, while `Eq` and `Ne` compare
the bits. `And`, `Or` and `Xor` take any element other than 0 as true. `Div` and `Pow` are refused.

-}
binary : Prim -> T -> T -> Meta -> Out
binary p ta tb out =
    case ( ta.data, tb.data ) of
        ( F a, F b ) ->
            let
                floats f =
                    Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList (zip2 out.shape ta tb getF a getF b f)) }

                bools f =
                    Ok { dt = Bool, shape = out.shape, data = I (Array.fromList (zip2 out.shape ta tb getF a getF b (\x y -> fromBool (f x y)))) }
            in
            case p of
                Add ->
                    floats (+)

                Sub ->
                    floats (-)

                Mul ->
                    floats (*)

                Div ->
                    floats (/)

                Pow ->
                    floats (^)

                Mod ->
                    floats (\x y -> x - y * M.floorF (x / y))

                Max2 ->
                    floats
                        (\x y ->
                            if isNaN x || (not (isNaN y) && y > x) then
                                y

                            else
                                x
                        )

                Min2 ->
                    floats
                        (\x y ->
                            if isNaN x || (not (isNaN y) && y < x) then
                                y

                            else
                                x
                        )

                -- unlike IEEE, under JavaScript Elm's x > y is True when either is NaN
                Gt ->
                    bools (\x y -> not (isNaN x || isNaN y) && x > y)

                Ge ->
                    bools (\x y -> not (isNaN x || isNaN y) && x >= y)

                Eq ->
                    bools (\x y -> not (isNaN x || isNaN y) && x == y)

                -- unlike Elm's /=, false when either is NaN
                Ne ->
                    bools (\x y -> not (isNaN x || isNaN y) && x /= y)

                _ ->
                    Err ("needs integer or mask tensors, not " ++ P.dtName ta.dt)

        ( I a, I b ) ->
            let
                u64 =
                    ta.dt == UI64

                ints f =
                    Ok { dt = out.dtype, shape = out.shape, data = I (Array.fromList (zip2 out.shape ta tb getI a getI b (\x y -> C.wrapInt out.dtype (f x y)))) }

                bools f =
                    Ok { dt = Bool, shape = out.shape, data = I (Array.fromList (zip2 out.shape ta tb getI a getI b (\x y -> fromBool (f x y)))) }

                exact f =
                    allExact out.dtype (zip2 out.shape ta tb getI a getI b f)
                        |> Result.map (\l -> { dt = out.dtype, shape = out.shape, data = I (Array.fromList l) })

                wide =
                    C.isWide out.dtype

                cmp =
                    order ta.dt
            in
            case p of
                Add ->
                    if wide then
                        exact U64.add

                    else
                        ints (+)

                Sub ->
                    if wide then
                        exact U64.sub

                    else
                        ints (-)

                Mul ->
                    if wide then
                        exact U64.mul

                    else
                        ints U64.mulLow32

                Mod ->
                    if List.member 0 (Array.toList b) then
                        Err "integer division by zero"

                    else if u64 then
                        ints U64.modU

                    else
                        ints (\x y -> modBy y x)

                Max2 ->
                    ints
                        (\x y ->
                            if cmp x y == LT then
                                y

                            else
                                x
                        )

                Min2 ->
                    ints
                        (\x y ->
                            if cmp x y == GT then
                                y

                            else
                                x
                        )

                Eq ->
                    bools (==)

                Ne ->
                    bools (/=)

                Gt ->
                    bools (\x y -> cmp x y == GT)

                Ge ->
                    bools (\x y -> cmp x y /= LT)

                And ->
                    ints (\x y -> fromBool (x /= 0 && y /= 0))

                Or ->
                    ints (\x y -> fromBool (x /= 0 || y /= 0))

                Xor ->
                    ints (\x y -> fromBool ((x /= 0) /= (y /= 0)))

                _ ->
                    Err ("needs a floating-point tensor, not " ++ P.dtName ta.dt)

        _ ->
            Err "dtypes differ"


{-| Returns, at each element of the meta's shape, `x`'s element where the mask `c` is not 0 and
`y`'s where it is 0, with all three broadcast to that shape. If `x` and `y` hold different kinds of
data, one floats and the other integers, `x`'s data is returned unchanged.
-}
select : T -> T -> T -> Meta -> T
select c x y out =
    let
        n =
            C.size out.shape

        ic =
            C.split out.shape c.shape

        ix =
            C.split out.shape x.shape

        iy =
            C.split out.shape y.shape

        cs =
            C.intsOf c

        ks =
            List.range 0 (n - 1)
    in
    { dt = out.dtype
    , shape = out.shape
    , data =
        case ( x.data, y.data ) of
            ( F a, F b ) ->
                F
                    (Array.fromList
                        (List.map
                            (\k ->
                                if getI cs (ic k) /= 0 then
                                    getF a (ix k)

                                else
                                    getF b (iy k)
                            )
                            ks
                        )
                    )

            ( I a, I b ) ->
                I
                    (Array.fromList
                        (List.map
                            (\k ->
                                if getI cs (ic k) /= 0 then
                                    getI a (ix k)

                                else
                                    getI b (iy k)
                            )
                            ks
                        )
                    )

            _ ->
                x.data
    }



-- EVERYTHING ELSE


{-| Returns the value of a primitive outside the element-wise families, or a message. A primitive
given operands its case does not match is refused with `"not implemented for these operands"`.

The reductions reduce the axis that is the first entry of `params.a`. Keeping the axis with size 1
or removing it leaves the results in the same order, so only the meta's shape reflects that choice.
On an empty lane the float mean, maximum and minimum are NaN, and the integer ones are 0.

`Transpose`, `BroadcastTo`, `Slice`, `Pad` and `BandPart` compute no new element: each picks the
operand's elements, or a fill, with `C.pick`. `Pad` fills float data with the first entry of
`params.f`, 0 when it is empty. It fills integer data with the first entry of `params.b` when there
is one, and otherwise with that float fill rounded. `BandPart` sets the elements outside the band
to 0, which is false in a mask.

`Random` takes as its seed element 0 of its operand, read as an integer. A distribution kind of 1
draws from `Tensor.Internal.Eval.Random.normal`, and any other kind from its `uniform`. The result
holds float data whatever the meta's dtype.

`XentLogits` is the mean over rows, the first axis, of minus the sum along the row of target times
the log-softmax of the logits; the row count is taken as at least 1.

`LayerNorm` normalises each lane along the last axis to (v − mean) / √(variance + ε) · gain + bias,
where the variance divides by the lane's length, not one less, and ε is the first entry of
`params.f`, or 10⁻⁵ when it is empty.

-}
other : Prim -> List T -> Params -> Meta -> Out
other p args params out =
    case ( p, args ) of
        ( ReduceSum, [ x ] ) ->
            reduce x
                params
                out
                (List.foldl (+) 0)
                (if C.isWide out.dtype then
                    U64.sum

                 else
                    List.foldl (+) 0 >> Just
                )

        ( ReduceMean, [ x ] ) ->
            reduce x
                params
                out
                (\l -> List.sum l / toFloat (List.length l))
                (if C.isWide out.dtype then
                    U64.mean (out.dtype == UI64)

                 else
                    \l -> Just (List.sum l // Basics.max 1 (List.length l))
                )

        ( ReduceMax, [ x ] ) ->
            reduce x params out (ignoringNaN Basics.max) (extreme x.dt GT >> Just)

        ( ReduceMin, [ x ] ) ->
            reduce x params out (ignoringNaN Basics.min) (extreme x.dt LT >> Just)

        ( ArgMax, [ x ] ) ->
            arg x params out GT

        ( ArgMin, [ x ] ) ->
            arg x params out LT

        ( Softmax, [ x ] ) ->
            alongF x (first params.a) out softmax

        ( LogSoftmax, [ x ] ) ->
            alongF x (first params.a) out logSoftmax

        ( CumSum, [ x ] ) ->
            cumsum x params out

        ( MatMul, [ a, b ] ) ->
            matmul a b out

        ( Reshape, [ x ] ) ->
            Ok { x | shape = out.shape }

        ( Transpose, [ x ] ) ->
            let
                st =
                    C.strides x.shape

                axes =
                    List.map2 (\d i -> ( d, Maybe.withDefault 0 (List.head (List.drop i st)) )) out.shape params.a
            in
            Ok (C.pick out.dtype out.shape (List.map (C.strided 0 axes) (range (C.size out.shape))) ( 0, 0 ) x.data)

        ( BroadcastTo, [ x ] ) ->
            Ok (C.pick out.dtype out.shape (List.map (C.split out.shape x.shape) (range (C.size out.shape))) ( 0, 0 ) x.data)

        ( Slice, [ x ] ) ->
            let
                st =
                    C.strides x.shape

                base =
                    List.sum (List.map2 (*) params.a st)
            in
            Ok (C.pick out.dtype out.shape (List.map (C.strided base (List.map2 Tuple.pair params.b st)) (range (C.size out.shape))) ( 0, 0 ) x.data)

        ( Concat, _ :: _ ) ->
            Ok (concat (first params.a) args out)

        ( Pad, [ x ] ) ->
            case params.a of
                [ axis, before, _ ] ->
                    let
                        ( outer, n, inner ) =
                            dims x.shape axis

                        m =
                            dimAt axis out.shape

                        src k =
                            let
                                i =
                                    modBy inner k

                                j =
                                    modBy m (k // inner)

                                o =
                                    k // (inner * m)

                                j0 =
                                    j - before
                            in
                            if j0 < 0 || j0 >= n then
                                -1

                            else
                                (o * n + j0) * inner + i

                        fill =
                            Maybe.withDefault 0 (List.head params.f)

                        fillI =
                            case params.b of
                                v :: _ ->
                                    v

                                [] ->
                                    round fill
                    in
                    Ok (C.pick out.dtype out.shape (List.map src (range (outer * m * inner))) ( fill, fillI ) x.data)

                _ ->
                    Err "bad parameters"

        ( Gather, [ x, idx ] ) ->
            gather (first params.a) x idx out

        ( ScatterRows, [ x, upd, idx ] ) ->
            scatter 0 False x upd (C.intsOf idx |> Array.toList) out

        ( ScatterRowsAdd, [ x, upd, idx ] ) ->
            scatter 0 True x upd (C.intsOf idx |> Array.toList) out

        ( ScatterAxis, [ x, upd, idx ] ) ->
            scatter (first params.a) False x upd (C.intsOf idx |> Array.toList) out

        ( ScatterAxisAdd, [ x, upd, idx ] ) ->
            scatter (first params.a) True x upd (C.intsOf idx |> Array.toList) out

        ( BandPart, [ x ] ) ->
            case params.a of
                [ lower, upper ] ->
                    let
                        r =
                            List.length x.shape

                        rows =
                            dimAt (r - 2) x.shape

                        cols =
                            dimAt (r - 1) x.shape

                        keep k =
                            let
                                j =
                                    modBy cols k

                                i =
                                    modBy rows (k // cols)
                            in
                            (lower < 0 || i - j <= lower) && (upper < 0 || j - i <= upper)
                    in
                    Ok
                        (C.pick out.dtype
                            out.shape
                            (List.map
                                (\k ->
                                    if keep k then
                                        k

                                    else
                                        -1
                                )
                                (range (C.size x.shape))
                            )
                            ( 0, 0 )
                            x.data
                        )

                _ ->
                    Err "bad parameters"

        ( Range, [] ) ->
            case params.a of
                [ start, step, n ] ->
                    Ok { dt = SI64, shape = out.shape, data = I (Array.fromList (List.map (\k -> start + step * k) (range n))) }

                _ ->
                    Err "bad parameters"

        ( Random, [ seedT ] ) ->
            case ( params.a, params.f ) of
                ( kind :: _ :: _, [ a, b ] ) ->
                    let
                        n =
                            C.size out.shape

                        seed =
                            getI (C.intsOf seedT) 0
                    in
                    if n > 2147483648 then
                        Err "more than 2^31 elements in one draw"

                    else
                        Ok
                            { dt = out.dtype
                            , shape = out.shape
                            , data =
                                F
                                    (Array.fromList
                                        (if kind == 1 then
                                            R.normal seed n a b

                                         else
                                            R.uniform seed n a b
                                        )
                                    )
                            }

                _ ->
                    Err "bad parameters"

        ( XentLogits, [ logits, targets ] ) ->
            let
                rows =
                    dimAt 0 logits.shape

                ls =
                    C.lanes logits.shape 1

                l =
                    C.floatsOf logits

                t =
                    C.floatsOf targets

                rowLoss lane =
                    List.map2 (\lv tv -> tv * lv) (logSoftmax (List.map (getF l) lane)) (List.map (getF t) lane) |> List.sum
            in
            Ok { dt = out.dtype, shape = [], data = F (Array.fromList [ -(List.sum (List.map rowLoss ls)) / toFloat (Basics.max 1 rows) ]) }

        ( LayerNorm, [ x, gain, bias ] ) ->
            let
                eps =
                    Maybe.withDefault 1.0e-5 (List.head params.f)

                g =
                    Array.toList (C.floatsOf gain)

                b =
                    Array.toList (C.floatsOf bias)

                one lane =
                    let
                        n =
                            toFloat (List.length lane)

                        mean =
                            List.sum lane / n

                        var =
                            List.sum (List.map (\v -> (v - mean) * (v - mean)) lane) / n

                        s =
                            sqrt (var + eps)
                    in
                    List.map3 (\v gv bv -> (v - mean) / s * gv + bv) lane g b
            in
            alongF x (List.length x.shape - 1) out one

        ( Conv, [ x, f ] ) ->
            conv False x f params out

        ( ConvTranspose, [ x, f ] ) ->
            conv True x f params out

        ( MaxPool, [ x ] ) ->
            pool True x params out

        ( AvgPool, [ x ] ) ->
            pool False x params out

        ( TopKValues, [ x ] ) ->
            topK False x params out

        ( TopKIndices, [ x ] ) ->
            topK True x params out

        _ ->
            Err "not implemented for these operands"


{-| Returns the list 0, 1, …, n − 1, which is empty when n is 0 or less.
-}
range : Int -> List Int
range n =
    List.range 0 (n - 1)


{-| Returns the first entry of a params list, or 0 when it is empty, so a missing axis reads as
axis 0.
-}
first : List Int -> Int
first l =
    Maybe.withDefault 0 (List.head l)


{-| Returns the size of axis `i` of a shape, or 1 when `i` is the shape's rank or more. A negative
`i` is read as 0.
-}
dimAt : Int -> List Int -> Int
dimAt i l =
    Maybe.withDefault 1 (List.head (List.drop i l))


{-| Returns the product of the sizes before `axis`, the size of `axis`, and the product of the
sizes after it.
-}
dims : List Int -> Int -> ( Int, Int, Int )
dims shape axis =
    ( C.size (List.take axis shape), dimAt axis shape, C.size (List.drop (axis + 1) shape) )


{-| Returns `f` folded over the elements of `l` that are not NaN, or NaN when there is none. With
`Basics.max` or `Basics.min` it is the largest or smallest number in `l`, ignoring NaN.
-}
ignoringNaN : (Float -> Float -> Float) -> List Float -> Float
ignoringNaN f l =
    case List.filter (\v -> not (isNaN v)) l of
        h :: rest ->
            List.foldl f h rest

        [] ->
            0 / 0


{-| Returns the largest (`want` is `GT`) or smallest (`LT`) of a lane of integer elements of dtype
`dt`, ordered by `order`, or 0 for an empty lane.
-}
extreme : DT -> Order -> List Int -> Int
extreme dt want l =
    case l of
        h :: rest ->
            List.foldl
                (\v best ->
                    if order dt v best == want then
                        v

                    else
                        best
                )
                h
                rest

        [] ->
            0


{-| Compares two integer elements of dtype `dt`: as unsigned numbers for `ui64`, and as signed
ones otherwise.
-}
order : DT -> Int -> Int -> Order
order dt a b =
    if dt == UI64 then
        U64.compareU a b

    else
        compare a b


{-| Returns one element for each lane of `x` along the axis that is the first entry of
`params.a`, in the order `C.lanes` lists them: `ff` of the lane's elements for float data, or `fi`'s
result on them, wrapped to the meta's dtype, for integer data. A lane for which `fi` gives `Nothing`
makes the result a message.
-}
reduce : T -> Params -> Meta -> (List Float -> Float) -> (List Int -> Maybe Int) -> Out
reduce x params out ff fi =
    let
        axis =
            first params.a

        ls =
            C.lanes x.shape axis
    in
    case x.data of
        F a ->
            Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList (List.map (\lane -> ff (List.map (getF a) lane)) ls)) }

        I a ->
            allExact out.dtype (List.map (\lane -> Maybe.map (C.wrapInt out.dtype) (fi (List.map (getI a) lane))) ls)
                |> Result.map (\l -> { dt = out.dtype, shape = out.shape, data = I (Array.fromList l) })


{-| Returns, as `si64`, the position along the axis that is the first entry of `params.a` of the
largest (`want` is `GT`) or smallest (`LT`) element of each lane, the lowest position on ties.

Integer elements are ordered by `order`. Float elements that are NaN are skipped, so a lane whose
elements are all NaN gives 0, as does an empty lane.

-}
arg : T -> Params -> Meta -> Order -> Out
arg x params out want =
    let
        ls =
            C.lanes x.shape (first params.a)

        bestI vs =
            case vs of
                [] ->
                    0

                h :: rest ->
                    List.foldl
                        (\v ( i, ( bi, bv ) ) ->
                            if order x.dt v bv == want then
                                ( i + 1, ( i, v ) )

                            else
                                ( i + 1, ( bi, bv ) )
                        )
                        ( 1, ( 0, h ) )
                        rest
                        |> Tuple.second
                        |> Tuple.first
    in
    case x.data of
        F a ->
            Ok { dt = SI64, shape = out.shape, data = I (Array.fromList (List.map (\lane -> bestF want (List.map (getF a) lane)) ls)) }

        I a ->
            Ok { dt = SI64, shape = out.shape, data = I (Array.fromList (List.map (\lane -> bestI (List.map (getI a) lane)) ls)) }


{-| Returns the position in `vs` of the largest (`want` is `GT`) or smallest (`LT`) float that is
not NaN, the lowest position on ties, or 0 when there is none.
-}
bestF : Order -> List Float -> Int
bestF want vs =
    List.foldl
        (\( i, v ) best ->
            if isNaN v then
                best

            else
                case best of
                    Nothing ->
                        Just ( i, v )

                    Just ( _, bv ) ->
                        if compare v bv == want then
                            Just ( i, v )

                        else
                            best
        )
        Nothing
        (List.indexedMap Tuple.pair vs)
        |> Maybe.map Tuple.first
        |> Maybe.withDefault 0


{-| Returns `x` with `f` applied to each of its lanes along `axis`, read as floats, and each result
laid out where its lane was. The result holds float data with the meta's dtype and shape, and `f`
is expected to return a lane as long as the one it was given.
-}
alongF : T -> Int -> Meta -> (List Float -> List Float) -> Out
alongF x axis out f =
    let
        a =
            C.floatsOf x

        ls =
            C.lanes x.shape axis
    in
    Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList (C.withLanes x.shape axis (dimAt axis x.shape) (List.map (\lane -> f (List.map (getF a) lane)) ls))) }


{-| Returns the softmax of a lane: each eᵛ divided by their sum, computed as e^(v − m), with m the
lane's maximum, so that no exponential overflows. A lane that holds NaN, or whose maximum is +∞ or
−∞, gives NaN throughout.
-}
softmax : List Float -> List Float
softmax l =
    let
        m =
            List.foldl Basics.max (-1 / 0) l

        es =
            List.map (\v -> M.exp (v - m)) l

        s =
            List.sum es
    in
    List.map (\e -> e / s) es


{-| Returns the log-softmax of a lane: each v − m − ln Σ e^(v − m), with m the lane's maximum. As
with `softmax`, a lane that holds NaN, or whose maximum is +∞ or −∞, gives NaN throughout.
-}
logSoftmax : List Float -> List Float
logSoftmax l =
    let
        m =
            List.foldl Basics.max (-1 / 0) l

        s =
            List.sum (List.map (\v -> M.exp (v - m)) l)

        ls =
            M.log s
    in
    List.map (\v -> v - m - ls) l


{-| Returns the running sums of `x` along an axis, with `params.a` holding the axis, the exclusive
flag and the reverse flag, or a message when it has fewer than three entries. Integer sums are
wrapped to the meta's dtype at every step; for `si64` and `ui64` a running sum that has no exact
`Int`, which happens only under JavaScript, is refused.
-}
cumsum : T -> Params -> Meta -> Out
cumsum x params out =
    case params.a of
        axis :: exclusive :: reverse :: _ ->
            let
                n =
                    dimAt axis x.shape

                ls =
                    C.lanes x.shape axis

                scan : (v -> v -> v) -> v -> List v -> List v
                scan add zero lane =
                    let
                        ordered =
                            if reverse == 1 then
                                List.reverse lane

                            else
                                lane

                        sums =
                            List.foldl (\v ( acc, s ) -> ( add s v :: acc, add s v )) ( [], zero ) ordered |> Tuple.first |> List.reverse

                        shifted =
                            if exclusive == 1 then
                                zero :: List.take (n - 1) sums

                            else
                                sums
                    in
                    if reverse == 1 then
                        List.reverse shifted

                    else
                        shifted
            in
            case x.data of
                F a ->
                    Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList (C.withLanes x.shape axis n (List.map (\lane -> scan (+) 0 (List.map (getF a) lane)) ls))) }

                I a ->
                    let
                        step =
                            if C.isWide out.dtype then
                                \s v -> Maybe.andThen (\s0 -> Maybe.andThen (U64.add s0) v) s

                            else
                                Maybe.map2 (\s0 v0 -> C.wrapInt out.dtype (s0 + v0))
                    in
                    allExact out.dtype (C.withLanes x.shape axis n (List.map (\lane -> scan step (Just 0) (List.map (getI a >> Just) lane)) ls))
                        |> Result.map (\l -> { dt = out.dtype, shape = out.shape, data = I (Array.fromList l) })

        _ ->
            Err "bad parameters"


{-| Returns the matrix product of `ta` and `tb` by NumPy's `matmul` rules.

A rank-1 `ta` is read as one row and a rank-1 `tb` as one column; the meta's shape already lacks
the axis that adds. The axes before the last two are batch axes, broadcast with
`C.broadcastShapes`. The length summed over is `ta`'s last axis, and `tb`'s is not compared with it.
An integer dot product is wrapped to the meta's dtype: for `si64` and `ui64` it is
`U64.dot`, and refused where it has no exact `Int`, which happens only under JavaScript; for the
other integer dtypes each product is taken modulo 2³² and the running sum wrapped at every step.
Operands holding different kinds of data give `ta`'s data unchanged.

-}
matmul : T -> T -> Meta -> Out
matmul ta tb out =
    let
        sa =
            if List.length ta.shape == 1 then
                1 :: ta.shape

            else
                ta.shape

        sb =
            if List.length tb.shape == 1 then
                tb.shape ++ [ 1 ]

            else
                tb.shape

        ra =
            List.length sa

        rb =
            List.length sb

        m =
            dimAt (ra - 2) sa

        k =
            dimAt (ra - 1) sa

        n =
            dimAt (rb - 1) sb

        batchA =
            List.take (ra - 2) sa

        batchB =
            List.take (rb - 2) sb

        batch =
            C.broadcastShapes batchA batchB

        nb =
            C.size batch

        ia =
            C.split batch batchA

        ib =
            C.split batch batchB

        cells =
            List.concatMap
                (\bi ->
                    let
                        offA =
                            ia bi * m * k

                        offB =
                            ib bi * k * n
                    in
                    List.concatMap (\r -> List.map (\c -> ( offA + r * k, offB + c )) (range n)) (range m)
                )
                (range nb)

        ks =
            range k

        done data =
            { dt = out.dtype, shape = out.shape, data = data }
    in
    case ( ta.data, tb.data ) of
        ( F a, F b ) ->
            Ok (done (F (Array.fromList (List.map (\( ra0, cb0 ) -> List.foldl (\kk acc -> acc + getF a (ra0 + kk) * getF b (cb0 + kk * n)) 0 ks) cells))))

        ( I a, I b ) ->
            if C.isWide out.dtype then
                allExact out.dtype (List.map (\( ra0, cb0 ) -> U64.dot (List.map (\kk -> ( getI a (ra0 + kk), getI b (cb0 + kk * n) )) ks)) cells)
                    |> Result.map (Array.fromList >> I >> done)

            else
                Ok (done (I (Array.fromList (List.map (\( ra0, cb0 ) -> List.foldl (\kk acc -> C.wrapInt out.dtype (acc + U64.mulLow32 (getI a (ra0 + kk)) (getI b (cb0 + kk * n)))) 0 ks) cells))))

        _ ->
            Ok (done ta.data)


{-| Returns the operands joined along `axis`, in order, each read as floats with `C.floatsOf` when
the meta's dtype is a float dtype and as integers with `C.intsOf` otherwise.
-}
concat : Int -> List T -> Meta -> T
concat axis pieces out =
    let
        outer =
            C.size (List.take axis out.shape)

        inner =
            C.size (List.drop (axis + 1) out.shape)

        blocks : (T -> Array a) -> List a
        blocks get =
            List.concatMap
                (\o ->
                    List.concatMap
                        (\t ->
                            let
                                w =
                                    dimAt axis t.shape * inner
                            in
                            Array.toList (Array.slice (o * w) ((o + 1) * w) (get t))
                        )
                        pieces
                )
                (range outer)
    in
    { dt = out.dtype
    , shape = out.shape
    , data =
        if P.isFloat out.dtype then
            F (Array.fromList (blocks C.floatsOf))

        else
            I (Array.fromList (blocks C.intsOf))
    }


{-| Returns the slices of `x` along `axis` at the indices in `idx`, in the indices' row-major
order, or a message naming the first index outside 0 .. n − 1, where n is the size of that axis.
Indices held as floats are rounded.
-}
gather : Int -> T -> T -> Meta -> Out
gather axis x idx out =
    let
        ( outer, n, inner ) =
            dims x.shape axis

        is =
            Array.toList (C.intsOf idx)

        bad =
            List.filter (\i -> i < 0 || i >= n) is
    in
    case bad of
        b :: _ ->
            Err ("index " ++ String.fromInt b ++ " is outside 0 .. " ++ String.fromInt (n - 1))

        [] ->
            let
                sources =
                    List.concatMap (\o -> List.concatMap (\i -> List.map (\j -> (o * n + i) * inner + j) (range inner)) is) (range outer)
            in
            Ok (C.pick out.dtype out.shape sources ( 0, 0 ) x.data)


{-| Returns `x` with its slice along `axis` at each index `idx[k]` replaced by slice k of `upd`
along that axis, or, with `add`, increased by it, or a message. `upd` is read as one slice along
`axis` per entry of `idx`.

With a repeated index the last replacement wins, and every addition counts. An integer addition is
wrapped to the meta's dtype; for `si64` and `ui64` one whose result has no exact `Int`, which
happens only under JavaScript, is refused. An index outside 0 .. n − 1, where n is the size of the axis, is
refused, naming the first in `idx`, and so are `x` and `upd` holding different kinds of data.

-}
scatter : Int -> Bool -> T -> T -> List Int -> Meta -> Out
scatter axis add x upd idx out =
    let
        ( outer, n, inner ) =
            dims x.shape axis

        c =
            List.length idx

        bad =
            List.filter (\i -> i < 0 || i >= n) idx

        writes =
            List.concatMap
                (\o ->
                    List.concatMap
                        (\( k, i ) -> List.map (\j -> ( (o * n + i) * inner + j, (o * c + k) * inner + j )) (range inner))
                        (List.indexedMap Tuple.pair idx)
                )
                (range outer)

        run : (a -> a -> a) -> Array a -> Array a -> Array a
        run combine xa ua =
            List.foldl
                (\( dst, src ) acc ->
                    case ( Array.get dst acc, Array.get src ua ) of
                        ( Just old, Just new ) ->
                            Array.set dst
                                (if add then
                                    combine old new

                                 else
                                    new
                                )
                                acc

                        _ ->
                            acc
                )
                xa
                writes
    in
    case bad of
        b :: _ ->
            Err ("index " ++ String.fromInt b ++ " is outside 0 .. " ++ String.fromInt (n - 1))

        [] ->
            case ( x.data, upd.data ) of
                ( F xa, F ua ) ->
                    Ok { dt = out.dtype, shape = out.shape, data = F (run (+) xa ua) }

                ( I xa, I ua ) ->
                    if C.isWide out.dtype then
                        run (\a b -> Maybe.map2 Tuple.pair a b |> Maybe.andThen (\( a0, b0 ) -> U64.add a0 b0)) (Array.map Just xa) (Array.map Just ua)
                            |> Array.toList
                            |> allExact out.dtype
                            |> Result.map (\l -> { dt = out.dtype, shape = out.shape, data = I (Array.fromList l) })

                    else
                        Ok { dt = out.dtype, shape = out.shape, data = I (run (\a b -> C.wrapInt out.dtype (a + b)) xa ua) }

                _ ->
                    Err "dtypes differ"


{-| Returns the 2-D convolution of `x` with the filter `f`, or with `transposed` the transposed
convolution, with the meta's shape, or a message when either is not rank 4, `params.a` has fewer
than six entries, or either stride is below 1.

`x` is NHWC: batch, height, width, channels. `params.a` holds the two strides sh and sw, then the
paddings top, bottom, left and right, of which only top (pt) and left (pl) are read, since the
meta's shape fixes the rest; then the dilations dh and dw, which are used when exactly two entries
follow the paddings and are 1 otherwise.

Forward, the filter is (kernel height kh, kernel width kw, input channels, result channels), and
result element [b, p, q, o] is the sum over i, j and c of
`x`[b, p·sh + i·dh − pt, q·sw + j·dw − pl, c] · `f`[i, j, c, o], with a position outside `x`
reading 0. Transposed, the filter is (kh, kw, result channels, input channels), and each
`x`[b, p, q, c] · `f`[i, j, o, c] is added to the result at
[b, p·sh + i·dh − pt, q·sw + j·dw − pl, o]: the adjoint of the forward convolution with the same
params. Both read their operands as floats and give float data.

-}
conv : Bool -> T -> T -> Params -> Meta -> Out
conv transposed x f params out =
    case ( x.shape, f.shape, params.a ) of
        ( _, _, sh :: sw :: _ ) ->
            if sh < 1 || sw < 1 then
                Err ("strides must be at least 1, not " ++ String.fromInt sh ++ " and " ++ String.fromInt sw)

            else
                convChecked transposed x f params out

        _ ->
            Err "bad shapes or parameters"


{-| Returns `conv`'s result, for strides of at least 1.
-}
convChecked : Bool -> T -> T -> Params -> Meta -> Out
convChecked transposed x f params out =
    case ( x.shape, f.shape, params.a ) of
        ( [ nb, h, w, cx ], [ kh, kw, f2, f3 ], sh :: sw :: pt :: _ :: pl :: _ :: dil ) ->
            let
                ( dh, dw ) =
                    case dil of
                        [ a, b ] ->
                            ( a, b )

                        _ ->
                            ( 1, 1 )

                ( oh, ow, co ) =
                    ( dimAt 1 out.shape, dimAt 2 out.shape, dimAt 3 out.shape )

                xs =
                    C.floatsOf x

                fs =
                    C.floatsOf f

                xAt b y xx c =
                    if y < 0 || y >= h || xx < 0 || xx >= w then
                        0

                    else
                        getF xs (((b * h + y) * w + xx) * cx + c)

                fAt i j a b =
                    getF fs (((i * kw + j) * f2 + a) * f3 + b)

                sumOver l g =
                    List.foldl (\v acc -> acc + g v) 0 l

                forward b y xx o =
                    sumOver (range kh)
                        (\i ->
                            sumOver (range kw)
                                (\j -> sumOver (range cx) (\c -> xAt b (y * sh + i * dh - pt) (xx * sw + j * dw - pl) c * fAt i j c o))
                        )

                backward b oy ox o =
                    sumOver (range kh)
                        (\i ->
                            let
                                ty =
                                    oy + pt - i * dh
                            in
                            if modBy sh ty /= 0 then
                                0

                            else
                                sumOver (range kw)
                                    (\j ->
                                        let
                                            tx =
                                                ox + pl - j * dw
                                        in
                                        if modBy sw tx /= 0 then
                                            0

                                        else
                                            sumOver (range cx) (\c -> xAt b (ty // sh) (tx // sw) c * fAt i j o c)
                                    )
                        )

                cell =
                    if transposed then
                        backward

                    else
                        forward

                values =
                    List.concatMap (\b -> List.concatMap (\y -> List.concatMap (\xx -> List.map (\o -> cell b y xx o) (range co)) (range ow)) (range oh)) (range nb)
            in
            Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList values) }

        _ ->
            Err "bad shapes or parameters"


{-| Returns the maximum, with `isMax`, or else the mean, of each k × k window of the NHWC input `x`,
with stride k and `params.a = [k]`, or a message when `x` is not rank 4 or `params.a` is not one
entry.

The number of windows comes from `x`'s own height and width, each divided by k with `//`, not from
the meta. The input is read as floats. The maximum ignores NaN and is NaN only for a window that is
all NaN; the mean includes it.

-}
pool : Bool -> T -> Params -> Meta -> Out
pool isMax x params out =
    case ( x.shape, params.a ) of
        ( [ nb, h, w, c ], [ k ] ) ->
            let
                xs =
                    C.floatsOf x

                window b y xx ch =
                    List.concatMap (\i -> List.map (\j -> getF xs (((b * h + y * k + i) * w + xx * k + j) * c + ch)) (range k)) (range k)

                combine l =
                    if isMax then
                        ignoringNaN Basics.max l

                    else
                        List.sum l / toFloat (k * k)

                values =
                    List.concatMap (\b -> List.concatMap (\y -> List.concatMap (\xx -> List.map (\ch -> combine (window b y xx ch)) (range c)) (range (w // k))) (range (h // k))) (range nb)
            in
            Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList values) }

        _ ->
            Err "bad shapes or parameters"


{-| Returns the k largest elements of each lane of `x`, in descending order, or the k smallest, in
ascending order, or with `indices` their positions along the lane as `si64`, or a message when
`params.a` is not `[axis, k, largest]`.

Equal elements keep the order of their positions, lowest first. NaN ranks above every number, so it
comes first among the largest and last among the smallest. `ui64` elements are ordered as unsigned.

-}
topK : Bool -> T -> Params -> Meta -> Out
topK indices x params out =
    case params.a of
        [ axis, k, largest ] ->
            let
                ls =
                    C.lanes x.shape axis

                rank : List ( Int, v ) -> (v -> v -> Order) -> List ( Int, v )
                rank lane cmp =
                    List.sortWith
                        (\( i, a ) ( j, b ) ->
                            case
                                if largest == 1 then
                                    cmp b a

                                else
                                    cmp a b
                            of
                                EQ ->
                                    compare i j

                                o ->
                                    o
                        )
                        lane
                        |> List.take k

                cmpF a b =
                    case ( isNaN a, isNaN b ) of
                        ( True, True ) ->
                            EQ

                        ( True, False ) ->
                            GT

                        ( False, True ) ->
                            LT

                        _ ->
                            compare a b

                place : List (List a) -> List a
                place =
                    C.withLanes x.shape axis k
            in
            case x.data of
                F a ->
                    let
                        ranked =
                            List.map (\lane -> rank (List.indexedMap (\i fl -> ( i, getF a fl )) lane) cmpF) ls
                    in
                    if indices then
                        Ok { dt = SI64, shape = out.shape, data = I (Array.fromList (place (List.map (List.map Tuple.first) ranked))) }

                    else
                        Ok { dt = out.dtype, shape = out.shape, data = F (Array.fromList (place (List.map (List.map Tuple.second) ranked))) }

                I a ->
                    let
                        ranked =
                            List.map (\lane -> rank (List.indexedMap (\i fl -> ( i, getI a fl )) lane) (order x.dt)) ls
                    in
                    if indices then
                        Ok { dt = SI64, shape = out.shape, data = I (Array.fromList (place (List.map (List.map Tuple.first) ranked))) }

                    else
                        Ok { dt = out.dtype, shape = out.shape, data = I (Array.fromList (place (List.map (List.map Tuple.second) ranked))) }

        _ ->
            Err "bad parameters"
