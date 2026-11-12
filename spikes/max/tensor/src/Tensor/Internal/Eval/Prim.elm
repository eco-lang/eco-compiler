module Tensor.Internal.Eval.Prim exposing (apply)

{-| Every primitive's semantics, as `plans/tensor-eval-in-elm.md` §3.6 gives them. `apply` gets the
operands' values, the parameters and the result's meta (its shape and dtype, already checked when
the expression was made), and returns the result or an error naming the primitive.
-}

import Array exposing (Array)
import Tensor.Internal.Eval.Core as C exposing (Data(..), T, getF, getI)
import Tensor.Internal.Eval.Math as M
import Tensor.Internal.Eval.Random as R
import Tensor.Internal.Eval.U64 as U64
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))
import Tensor.Internal.Shape exposing (Meta)


type alias Out =
    Result String T


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


mapF : (Float -> Float) -> T -> Meta -> Out
mapF f x out =
    case x.data of
        F a ->
            Ok { dt = out.dtype, shape = out.shape, data = F (Array.map f a) }

        I _ ->
            Err ("needs a floating-point tensor, not " ++ P.dtName x.dt)


boolsF : (Float -> Bool) -> T -> Meta -> Out
boolsF f x out =
    case x.data of
        F a ->
            Ok { dt = Bool, shape = out.shape, data = I (Array.map (f >> fromBool) a) }

        I _ ->
            Err ("needs a floating-point tensor, not " ++ P.dtName x.dt)


fromBool : Bool -> Int
fromBool b =
    if b then
        1

    else
        0


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


{-| float→float unchanged (no rounding yet); int→float by value (u64 unsigned); float→int refuses
NaN, ±∞ and values outside the target, else truncates; int→int wraps; anything→Bool is x ≠ 0.
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


{-| [lo, hi) of an integer dtype, as floats.
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


{-| Two operands broadcast to the result's shape.
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

                -- as MAX on CPU: NaN ignored (fmax, fmin); on equal values (0 and -0) the first
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

                -- Elm's comparisons are not IEEE's under JavaScript: NaN > 0 is True there
                Gt ->
                    bools (\x y -> not (isNaN x || isNaN y) && x > y)

                Ge ->
                    bools (\x y -> not (isNaN x || isNaN y) && x >= y)

                Eq ->
                    bools (\x y -> not (isNaN x || isNaN y) && x == y)

                -- ordered, as MAX: NaN is not unequal to anything
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

                cmp =
                    order ta.dt
            in
            case p of
                Add ->
                    ints (+)

                Sub ->
                    ints (-)

                Mul ->
                    ints (*)

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


other : Prim -> List T -> Params -> Meta -> Out
other p args params out =
    case ( p, args ) of
        ( ReduceSum, [ x ] ) ->
            reduce x params out (List.foldl (+) 0) (List.foldl (+) 0)

        ( ReduceMean, [ x ] ) ->
            reduce x params out (\l -> List.sum l / toFloat (List.length l)) (\l -> List.sum l // Basics.max 1 (List.length l))

        ( ReduceMax, [ x ] ) ->
            reduce x params out (ignoringNaN Basics.max) (extreme x.dt GT)

        ( ReduceMin, [ x ] ) ->
            reduce x params out (ignoringNaN Basics.min) (extreme x.dt LT)

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
            Ok (matmul a b out)

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


range : Int -> List Int
range n =
    List.range 0 (n - 1)


first : List Int -> Int
first l =
    Maybe.withDefault 0 (List.head l)


dimAt : Int -> List Int -> Int
dimAt i l =
    Maybe.withDefault 1 (List.head (List.drop i l))


{-| (outer, size, inner) around an axis.
-}
dims : List Int -> Int -> ( Int, Int, Int )
dims shape axis =
    ( C.size (List.take axis shape), dimAt axis shape, C.size (List.drop (axis + 1) shape) )


{-| A max or min that skips NaN, as MAX's reductions do on CPU (NaN only when every element is).
-}
ignoringNaN : (Float -> Float -> Float) -> List Float -> Float
ignoringNaN f l =
    case List.filter (\v -> not (isNaN v)) l of
        h :: rest ->
            List.foldl f h rest

        [] ->
            0 / 0


{-| The largest (GT) or smallest (LT) of a lane of integers (u64 unsigned).
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


order : DT -> Int -> Int -> Order
order dt a b =
    if dt == UI64 then
        U64.compareU a b

    else
        compare a b


reduce : T -> Params -> Meta -> (List Float -> Float) -> (List Int -> Int) -> Out
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
            Ok { dt = out.dtype, shape = out.shape, data = I (Array.fromList (List.map (\lane -> C.wrapInt out.dtype (fi (List.map (getI a) lane))) ls)) }


{-| The index of the largest (GT) or smallest (LT) element of each lane: the lowest on ties; NaN
skipped, as MAX does on CPU (0 if every element is NaN).
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


{-| A function of each float lane along an axis, results laid out with the same shape.
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
                    Ok { dt = out.dtype, shape = out.shape, data = I (Array.fromList (C.withLanes x.shape axis n (List.map (\lane -> scan (\s v -> C.wrapInt out.dtype (s + v)) 0 (List.map (getI a) lane)) ls))) }

        _ ->
            Err "bad parameters"


{-| NumPy `matmul`: rank-1 operands promoted (and their axis dropped), batch prefixes broadcast.
-}
matmul : T -> T -> Meta -> T
matmul ta tb out =
    let
        -- rank-1 operands promoted; the result's meta has their axes dropped already
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
    in
    { dt = out.dtype
    , shape = out.shape
    , data =
        case ( ta.data, tb.data ) of
            ( F a, F b ) ->
                F (Array.fromList (List.map (\( ra0, cb0 ) -> List.foldl (\kk acc -> acc + getF a (ra0 + kk) * getF b (cb0 + kk * n)) 0 ks) cells))

            ( I a, I b ) ->
                I (Array.fromList (List.map (\( ra0, cb0 ) -> C.wrapInt out.dtype (List.foldl (\kk acc -> acc + getI a (ra0 + kk) * getI b (cb0 + kk * n)) 0 ks)) cells))

            _ ->
                ta.data
    }


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


{-| x with slices along `axis` at the indices replaced by (or, adding, increased by) the slices of
`upd` in order: for rows, axis 0 and `upd` has a row per index. Duplicates: the last replacement
wins; additions all count.
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
                    Ok { dt = out.dtype, shape = out.shape, data = I (run (\a b -> C.wrapInt out.dtype (a + b)) xa ua) }

                _ ->
                    Err "dtypes differ"


{-| NHWC input, (kh, kw, c, o) filter; strides, paddings and dilations from `a`. The transposed conv
is the adjoint: filter (kh, kw, out, in).
-}
conv : Bool -> T -> T -> Params -> Meta -> Out
conv transposed x f params out =
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

                -- out[b, y·sh + i·dh − pt, x·sw + j·dw − pl, o] += x[b, y, x, c] · f[i, j, o, c]
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


{-| The k largest (descending) or smallest (ascending) of each lane, ties lowest index first, NaN
above every number; the values or their indices.
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
