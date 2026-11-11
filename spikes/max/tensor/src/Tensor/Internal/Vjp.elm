module Tensor.Internal.Vjp exposing (rule)

{-| The vector-Jacobian product of every primitive, written with the same builders as the forward
operations (`Tensor.Internal.Ops`), so gradients can be differentiated again.

`rule p args params out g` gives one cotangent per operand (`Nothing`: no gradient flows there). For
element-wise primitives a cotangent has the result's shape; `Grad` sums it down to the operand's.

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (Params, Prim(..))


rule : Prim -> List Expr -> Params -> Expr -> Expr -> List (Maybe Expr)
rule p args params out g =
    case ( p, args ) of
        ( Abs, [ x ] ) ->
            [ Just (O.mul g (O.sign x)) ]

        ( Neg, [ _ ] ) ->
            [ Just (O.neg g) ]

        ( Exp, [ _ ] ) ->
            [ Just (O.mul g out) ]

        ( Log, [ x ] ) ->
            [ Just (O.div g x) ]

        ( Log1p, [ x ] ) ->
            [ Just (O.div g (O.add (O.scalarLike 1 x) x)) ]

        ( Sqrt, [ _ ] ) ->
            [ Just (O.div (O.mul g (O.scalarLike 0.5 out)) out) ]

        ( Rsqrt, [ _ ] ) ->
            [ Just (O.mul g (O.mul (O.scalarLike -0.5 out) (O.mul out (O.square out)))) ]

        ( Sin, [ x ] ) ->
            [ Just (O.mul g (O.unary Cos x)) ]

        ( Cos, [ x ] ) ->
            [ Just (O.neg (O.mul g (O.unary Sin x))) ]

        ( Acos, [ x ] ) ->
            [ Just (O.neg (O.div g (O.unary Sqrt (O.sub (O.scalarLike 1 x) (O.square x))))) ]

        ( Atanh, [ x ] ) ->
            [ Just (O.div g (O.sub (O.scalarLike 1 x) (O.square x))) ]

        ( Erf, [ x ] ) ->
            [ Just (O.mul g (O.mul (O.scalarLike (2 / Basics.sqrt pi) x) (O.unary Exp (O.neg (O.square x))))) ]

        ( Relu, [ x ] ) ->
            [ Just (O.select (O.gt x (O.scalarLike 0 x)) g (O.zerosLike g)) ]

        ( Sigmoid, [ _ ] ) ->
            [ Just (O.mul g (O.mul out (O.sub (O.scalarLike 1 out) out))) ]

        ( Tanh, [ _ ] ) ->
            [ Just (O.mul g (O.sub (O.scalarLike 1 out) (O.square out))) ]

        ( Gelu, [ x ] ) ->
            let
                -- Φ(x) + x φ(x)
                cdf =
                    O.mul (O.scalarLike 0.5 x) (O.add (O.scalarLike 1 x) (O.unary Erf (O.mul x (O.scalarLike (1 / Basics.sqrt 2) x))))

                pdf =
                    O.mul (O.scalarLike (1 / Basics.sqrt (2 * pi)) x) (O.unary Exp (O.mul (O.scalarLike -0.5 x) (O.square x)))
            in
            [ Just (O.mul g (O.add cdf (O.mul x pdf))) ]

        ( GeluTanh, [ x ] ) ->
            let
                c =
                    Basics.sqrt (2 / pi)

                inner =
                    O.mul (O.scalarLike c x) (O.add x (O.mul (O.scalarLike 0.044715 x) (O.mul x (O.square x))))

                t =
                    O.unary Tanh inner

                dInner =
                    O.mul (O.scalarLike c x) (O.add (O.scalarLike 1 x) (O.mul (O.scalarLike (3 * 0.044715) x) (O.square x)))

                d =
                    O.add (O.mul (O.scalarLike 0.5 x) (O.add (O.scalarLike 1 x) t))
                        (O.mul (O.mul (O.scalarLike 0.5 x) x) (O.mul (O.sub (O.scalarLike 1 x) (O.square t)) dInner))
            in
            [ Just (O.mul g d) ]

        ( Silu, [ x ] ) ->
            let
                s =
                    O.unary Sigmoid x
            in
            [ Just (O.mul g (O.add s (O.mul x (O.mul s (O.sub (O.scalarLike 1 s) s))))) ]

        ( Cast, [ x ] ) ->
            if P.isFloat (E.dtype x) && P.isFloat (E.dtype out) then
                [ Just (O.cast (E.dtype x) g) ]

            else
                [ Nothing ]

        ( Add, [ _, _ ] ) ->
            [ Just g, Just g ]

        ( Sub, [ _, _ ] ) ->
            [ Just g, Just (O.neg g) ]

        ( Mul, [ x, y ] ) ->
            [ Just (O.mul g y), Just (O.mul g x) ]

        ( Div, [ x, y ] ) ->
            [ Just (O.div g y), Just (O.neg (O.div (O.mul g x) (O.square y))) ]

        ( Pow, [ x, y ] ) ->
            [ Just (O.mul g (O.mul y (O.binary Pow x (O.sub y (O.scalarLike 1 y)))))
            , Just (O.mul g (O.mul out (O.unary Log x)))
            ]

        ( Max2, [ x, y ] ) ->
            let
                m =
                    O.ge x y
            in
            [ Just (O.select m g (O.zerosLike g)), Just (O.select m (O.zerosLike g) g) ]

        ( Min2, [ x, y ] ) ->
            let
                m =
                    O.le x y
            in
            [ Just (O.select m g (O.zerosLike g)), Just (O.select m (O.zerosLike g) g) ]

        ( Mod, [ _, _ ] ) ->
            [ Nothing, Nothing ]

        ( Select, [ c, _, _ ] ) ->
            [ Nothing, Just (O.select c g (O.zerosLike g)), Just (O.select c (O.zerosLike g) g) ]

        ( ReduceSum, [ x ] ) ->
            [ Just (spread params x g) ]

        ( ReduceMean, [ x ] ) ->
            let
                n =
                    List.head params.a |> Maybe.andThen (\axis -> List.head (List.drop axis (E.shape x))) |> Maybe.withDefault 1
            in
            [ Just (O.div (spread params x g) (O.scalarLike (toFloat n) g)) ]

        ( ReduceMax, [ x ] ) ->
            [ Just (extremum params x out g) ]

        ( ReduceMin, [ x ] ) ->
            [ Just (extremum params x out g) ]

        ( Softmax, [ _ ] ) ->
            let
                axis =
                    first params

                s =
                    O.broadcastTo (E.shape out) (O.reduceKeep ReduceSum axis (O.mul g out))
            in
            [ Just (O.mul out (O.sub g s)) ]

        ( LogSoftmax, [ _ ] ) ->
            let
                axis =
                    first params
            in
            [ Just (O.sub g (O.mul (O.unary Exp out) (O.broadcastTo (E.shape out) (O.reduceKeep ReduceSum axis g)))) ]

        ( CumSum, [ _ ] ) ->
            case params.a of
                [ axis, exclusive, reverse ] ->
                    [ Just (O.cumsum axis (exclusive == 1) (reverse /= 1) g) ]

                _ ->
                    [ Nothing ]

        ( MatMul, [ x, w ] ) ->
            matmul x w g

        ( Reshape, [ x ] ) ->
            [ Just (O.reshape (E.shape x) g) ]

        ( Transpose, [ _ ] ) ->
            let
                inverse =
                    List.indexedMap Tuple.pair params.a |> List.sortBy Tuple.second |> List.map Tuple.first
            in
            [ Just (O.transpose inverse g) ]

        ( BroadcastTo, [ x ] ) ->
            [ Just (O.unbroadcast (E.shape x) g) ]

        ( Slice, [ x ] ) ->
            let
                padded =
                    List.foldl
                        (\( axis, ( st, sz ), d ) acc -> O.pad axis st (d - st - sz) 0 acc)
                        g
                        (List.map3 (\i a b -> ( i, a, b )) (List.range 0 (E.rank x - 1)) (List.map2 Tuple.pair params.a params.b) (E.shape x))
            in
            [ Just padded ]

        ( Concat, xs ) ->
            let
                axis =
                    first params

                sizes =
                    List.map (\x -> List.head (List.drop axis (E.shape x)) |> Maybe.withDefault 0) xs

                starts =
                    List.foldl (\sz ( acc, total ) -> ( total :: acc, total + sz )) ( [], 0 ) sizes |> Tuple.first |> List.reverse

                piece x st =
                    O.slice (List.indexedMap (\i _ -> if i == axis then st else 0) (E.shape x)) (E.shape x) g
            in
            List.map2 (\x st -> Just (piece x st)) xs starts

        ( Pad, [ x ] ) ->
            case params.a of
                [ axis, before, _ ] ->
                    [ Just (O.slice (List.indexedMap (\i _ -> if i == axis then before else 0) (E.shape x)) (E.shape x) g) ]

                _ ->
                    [ Nothing ]

        ( Gather, [ x, idx ] ) ->
            let
                axis =
                    first params

                r =
                    E.rank x

                toFront =
                    axis :: List.filter ((/=) axis) (List.range 0 (r - 1))

                back =
                    List.indexedMap Tuple.pair toFront |> List.sortBy Tuple.second |> List.map Tuple.first

                gFront =
                    if E.rank idx == 1 then
                        O.transpose toFront g

                    else
                        g
            in
            if E.rank idx == 1 then
                [ Just (O.transpose back (O.scatterRowsAdd (O.transpose toFront (O.zerosLike x)) gFront idx)), Nothing ]

            else
                [ Nothing, Nothing ]

        ( ScatterRows, [ _, upd, idx ] ) ->
            [ Just (O.scatterRows g (O.zerosLike upd) idx), Just (O.gather 0 g (O.flatten idx)), Nothing ]

        ( ScatterRowsAdd, [ _, _, idx ] ) ->
            [ Just g, Just (O.gather 0 g (O.flatten idx)), Nothing ]

        ( ScatterAxis, [ _, upd, idx ] ) ->
            [ Just (O.scatterAxis (first params) g (O.zerosLike upd) idx), Just (O.gather (first params) g idx), Nothing ]

        ( ScatterAxisAdd, [ _, _, idx ] ) ->
            [ Just g, Just (O.gather (first params) g idx), Nothing ]

        ( TopKValues, [ x ] ) ->
            [ Just (E.failWith "topK: cannot be differentiated (topK, bottomK and sort have no gradient)" (O.zerosLike x)) ]

        ( TopKIndices, [ _ ] ) ->
            [ Nothing ]

        ( BandPart, [ _ ] ) ->
            case params.a of
                [ lower, upper ] ->
                    [ Just (O.bandPart lower upper g) ]

                _ ->
                    [ Nothing ]

        ( XentLogits, [ logits, target ] ) ->
            let
                n =
                    List.head (E.shape logits) |> Maybe.withDefault 1

                scaleBy =
                    O.div g (O.scalarLike (toFloat n) g)
            in
            [ Just (O.mul (O.sub (O.softmax 1 logits) target) scaleBy)
            , Just (O.mul (O.neg (O.logSoftmax 1 logits)) scaleBy)
            ]

        ( LayerNorm, [ x, gain, _ ] ) ->
            layerNorm params x gain g

        ( Conv, [ x, f ] ) ->
            if List.length params.a > 6 && List.drop 6 params.a /= [ 1, 1 ] then
                [ Nothing, Nothing ]

            else
                let
                    geometry =
                        List.take 6 params.a

                    back =
                        O.convTranspose (unusedPaddingDropped geometry (E.shape x) (E.shape f)) g f
                in
                [ Just (padTo (E.shape x) back), Just (filterGrad geometry (E.shape f) x g) ]

        ( ConvTranspose, [ x, f ] ) ->
            let
                geometry =
                    List.take 6 params.a
            in
            [ Just (O.conv geometry g f), Just (filterGrad geometry (E.shape f) g x) ]

        ( MaxPool, [ x ] ) ->
            let
                k =
                    first params

                ( x6, up ) =
                    windows k x

                hit =
                    O.cast (E.dtype x) (O.eq x6 (up out))

                count =
                    O.broadcastTo (E.shape x6) (O.reduceKeep ReduceSum 4 (O.reduceKeep ReduceSum 2 hit))
            in
            [ Just (O.reshape (E.shape x) (O.div (O.mul (up g) hit) count)) ]

        ( AvgPool, [ x ] ) ->
            let
                k =
                    first params

                ( _, up ) =
                    windows k x
            in
            [ Just (O.reshape (E.shape x) (O.mul (up g) (O.scalarLike (1 / toFloat (k * k)) g))) ]

        ( StopGradient, _ ) ->
            List.map (\_ -> Nothing) args

        _ ->
            List.map (\_ -> Nothing) args


first : Params -> Int
first params =
    Maybe.withDefault 0 (List.head params.a)


{-| The cotangent of a reduction spread back over the reduced axis.
-}
spread : Params -> Expr -> Expr -> Expr
spread params x g =
    case params.a of
        [ axis, keep ] ->
            let
                kept =
                    if keep == 1 then
                        g

                    else
                        O.insertAxis axis g
            in
            O.broadcastTo (E.shape x) kept

        _ ->
            g


{-| Max and min: the cotangent goes to the elements equal to the result, split evenly between ties.
-}
extremum : Params -> Expr -> Expr -> Expr -> Expr
extremum params x out g =
    case params.a of
        [ axis, keep ] ->
            let
                outKept =
                    if keep == 1 then
                        out

                    else
                        O.insertAxis axis out

                hit =
                    O.cast (E.dtype x) (O.eq x (O.broadcastTo (E.shape x) outKept))

                count =
                    O.broadcastTo (E.shape x) (O.reduceKeep ReduceSum axis hit)
            in
            O.div (O.mul (spread params x g) hit) count

        _ ->
            g


{-| x @ w for every case `Shape.matmul` allows; batch axes the operand lacks or has as 1 are summed
out by `Grad`'s un-broadcasting.
-}
matmul : Expr -> Expr -> Expr -> List (Maybe Expr)
matmul x w g =
    let
        rx =
            E.rank x

        rw =
            E.rank w
    in
    if rx == 1 && rw == 1 then
        [ Just (O.mul g w), Just (O.mul g x) ]

    else if rx == 1 then
        -- x [k], w [.., k, n], g [.., n]
        let
            gCol =
                O.insertAxis (E.rank g) g

            xRow =
                O.reshape [ 1, List.product (E.shape x) ] x
        in
        [ Just (O.reshape (E.shape x) (O.unbroadcast [ List.product (E.shape x), 1 ] (O.matmul w gCol)))
        , Just (O.matmul (O.swapLast xRow) (O.insertAxis (E.rank g - 1) g))
        ]

    else if rw == 1 then
        -- x [.., m, k], w [k], g [.., m]
        let
            gCol =
                O.insertAxis (E.rank g) g

            wRow =
                O.reshape [ 1, List.product (E.shape w) ] w
        in
        [ Just (O.matmul gCol wRow)
        , Just (O.reshape (E.shape w) (O.unbroadcast [ List.product (E.shape w), 1 ] (O.matmul (O.swapLast x) gCol)))
        ]

    else
        [ Just (O.matmul g (O.swapLast w)), Just (O.matmul (O.swapLast x) g) ]


{-| Layer norm over the last axis: x̂ = (x - μ)/σ, y = x̂ γ + β.
-}
layerNorm : Params -> Expr -> Expr -> Expr -> List (Maybe Expr)
layerNorm params x gain g =
    let
        eps =
            Maybe.withDefault 1.0e-5 (List.head params.f)

        last =
            E.rank x - 1

        s =
            E.shape x

        n =
            List.head (List.drop last s) |> Maybe.withDefault 1

        back e =
            O.broadcastTo s e

        mu =
            back (O.reduceKeep ReduceMean last x)

        centred =
            O.sub x mu

        var =
            O.reduceKeep ReduceMean last (O.square centred)

        invStd =
            back (O.unary Rsqrt (O.add var (O.scalarLike eps var)))

        xhat =
            O.mul centred invStd

        gainB =
            O.broadcastTo s gain

        dxhat =
            O.mul g gainB

        meanD =
            back (O.reduceKeep ReduceMean last dxhat)

        meanDX =
            back (O.reduceKeep ReduceMean last (O.mul dxhat xhat))

        dx =
            O.mul invStd (O.sub (O.sub dxhat meanD) (O.mul xhat meanDX))

        leading t =
            O.reshape [ List.product s // n, n ] t
    in
    [ Just dx
    , Just (O.reduce ReduceSum 0 (leading (O.mul g xhat)))
    , Just (O.reduce ReduceSum 0 (leading g))
    ]


{-| Zeros appended (bottom, right) up to `target`'s spatial size: rows no output reached.
-}
padTo : List Int -> Expr -> Expr
padTo target e =
    case ( target, E.shape e ) of
        ( [ _, h, w, _ ], [ _, h2, w2, _ ] ) ->
            e |> O.pad 1 0 (h - h2) 0 |> O.pad 2 0 (w - w2) 0

        _ ->
            e


{-| The gradient of a convolution's filter (kh, kw, c, o): the correlation of the input with the
output's cotangent, written as one more convolution with the batch and channel axes swapped and the
stride as dilation.
-}
filterGrad : List Int -> List Int -> Expr -> Expr -> Expr
filterGrad geometry fshape x g =
    case ( geometry, fshape ) of
        ( [ sh, sw, pt, pb, pl, pr ], [ kh, kw, c, o ] ) ->
            let
                xT =
                    O.transpose [ 3, 1, 2, 0 ] x

                gT =
                    O.transpose [ 1, 2, 0, 3 ] g

                r =
                    O.conv [ 1, 1, pt, pb, pl, pr, sh, sw ] xT gT
            in
            O.transpose [ 1, 2, 0, 3 ] (O.slice [ 0, 0, 0, 0 ] [ c, kh, kw, o ] r)

        _ ->
            g


{-| An NHWC tensor as (n, h/k, k, w/k, k, c), and a function spreading a pooled (n, h/k, w/k, c)
tensor over the windows.
-}
windows : Int -> Expr -> ( Expr, Expr -> Expr )
windows k x =
    case E.shape x of
        [ n, h, w, c ] ->
            let
                s6 =
                    [ n, h // k, k, w // k, k, c ]
            in
            ( O.reshape s6 x, \p -> O.broadcastTo s6 (O.reshape [ n, h // k, 1, w // k, 1, c ] p) )

        _ ->
            ( x, identity )


{-| A strided convolution never reads the last (h + pads - k) mod stride padded rows; its transpose
must not produce them. Padding that is too short for that leaves rows `padTo` fills with zeros.
-}
unusedPaddingDropped : List Int -> List Int -> List Int -> List Int
unusedPaddingDropped geometry xs fs =
    case ( geometry, xs, fs ) of
        ( [ sh, sw, pt, pb, pl, pr ], [ _, h, w, _ ], [ kh, kw, _, _ ] ) ->
            let
                remH =
                    modBy sh (h + pt + pb - kh)

                remW =
                    modBy sw (w + pl + pr - kw)
            in
            [ sh, sw, pt, Basics.max 0 (pb - remH), pl, Basics.max 0 (pr - remW) ]

        _ ->
            geometry
