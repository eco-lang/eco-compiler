module Tensor.Internal.Vjp exposing (rule)

{-| Differentiating in reverse needs to know, for each primitive, how a gradient arriving at its
result passes back to its operands. This module is that knowledge, one rule per primitive, in
`rule`.

The _cotangent_ of an expression is the gradient, with respect to that expression, of the quantity
being differentiated: it has one element per element of the expression. A primitive's
_vector-Jacobian product_ turns the cotangent of its result into a cotangent for each operand, the
part of the operand's gradient that passes through this one node.

Every rule is written with the builders of `Tensor.Internal.Ops`, the same ones the forward
operations use, so a cotangent is an ordinary expression, which can be batched, lowered and
evaluated like any other, and, except as described below, differentiated again.

A `TopKValues` cotangent, and the cotangents of a `Conv` with a dilation other than 1, are zeros
carrying a build error recorded on the cotangent expression. A `Gather` whose indices are not a
vector gives no gradient, silently.

A strided convolution's filter cotangent cannot be differentiated again: with a stride above 1,
the filter cotangent of a `Conv` or of a `ConvTranspose` is itself a dilated `Conv`, so
differentiating it again gives cotangents carrying a build error.

What a rule returns for an operand does not always have the operand's shape. An element-wise
primitive's operand that the operation broadcast, being rank 0 or having a pending axis (an
axis held as size 1 whose real size is not known yet, as `Tensor.Internal.Shape` defines it),
gets back an expression of the result's shape. When both operands of a `MatMul` have rank 2 or
more, what each gets has the result's batch axes, which an operand with fewer batch axes, or a
batch axis of size 1 against a larger one, does not have. Such an expression becomes the
operand's cotangent only once summed down to the operand's shape, as
`Tensor.Internal.Ops.unbroadcast` does. A rule also builds a cotangent for every operand that
can have one, whether or not anything will read it.

Most of the file is the one `case` in `rule`. The helpers after it hold the longer rules:
reductions, matrix products, layer normalisation, convolutions and pooling.

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (Params, Prim(..))


{-| Returns the cotangents of the operands `args` of a node applying `p` with `params`, given the
node's result `out` and its cotangent `g`: one entry per operand, in operand order, and `Nothing`
where no gradient flows. Several rules read `out` instead of recomputing it, among them `Exp`,
`Sqrt`, `Sigmoid`, `Tanh`, `Softmax`, `ReduceMax` and `MaxPool`.

No gradient flows to the operands of the comparisons, the logical operations, `Floor`, `Round`,
`Trunc`, `IsInf`, `IsNaN`, `Mod`, `ArgMax`, `ArgMin`, `TopKIndices`, `Random` and `StopGradient`;
through a `Cast` unless both dtypes are floating; to a `Select`'s mask; to the indices of a gather
or scatter; to either operand of a `Gather` whose indices are not a vector. A `CumSum`, `Pad` or
`BandPart` whose params do not have the layout
`Tensor.Internal.Prim` gives, and a node of any primitive but `Concat` with a number of operands
other than the one its rule matches, give `Nothing` for every operand.

At a tie, `Max2` and `Min2` give the whole cotangent to the first operand, while `ReduceMax`,
`ReduceMin` and `MaxPool` divide it evenly between the tied elements. `Relu` and `Abs` give 0 at 0.

A `Gather` with vector indices adds the cotangent's slices back at their indices, so a slice
gathered twice gets both.

A replacing scatter (`ScatterRows`, `ScatterAxis`) gives the replaced rows or slices of the tensor
a cotangent of 0, and each update the cotangent at the index it names. With a repeated index,
every update naming it gets that cotangent, although only one of them is in the result.

A `TopKValues` cotangent is zeros carrying a build error whose message begins "topK: cannot be
differentiated", so the error is on the cotangent, not on the `topK`. Likewise, a `Conv` whose
params hold more than its six strides and paddings, other than exactly a dilation of `[1, 1]`,
gives both operands zeros carrying a build error whose message begins "conv: a dilated
convolution cannot be differentiated".

The `XentLogits` cotangent of the logits is (softmax(logits) · s − target) · g / n, where s is the
sum of each row of the target and n the number of rows. This is the derivative for targets of any
row sums: a row of zeros, such as `Nn.crossEntropyIndices` makes for a label out of range, gets a
cotangent of 0. The target's cotangent is −logSoftmax(logits) · g / n.

-}
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
                    O.slice
                        (List.indexedMap
                            (\i _ ->
                                if i == axis then
                                    st

                                else
                                    0
                            )
                            (E.shape x)
                        )
                        (E.shape x)
                        g
            in
            List.map2 (\x st -> Just (piece x st)) xs starts

        ( Pad, [ x ] ) ->
            case params.a of
                [ axis, before, _ ] ->
                    [ Just
                        (O.slice
                            (List.indexedMap
                                (\i _ ->
                                    if i == axis then
                                        before

                                    else
                                        0
                                )
                                (E.shape x)
                            )
                            (E.shape x)
                            g
                        )
                    ]

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

                rowSums =
                    O.broadcastTo (E.shape target) (O.reduceKeep ReduceSum 1 target)
            in
            [ Just (O.mul (O.sub (O.mul (O.softmax 1 logits) rowSums) target) scaleBy)
            , Just (O.mul (O.neg (O.logSoftmax 1 logits)) scaleBy)
            ]

        ( LayerNorm, [ x, gain, _ ] ) ->
            layerNorm params x gain g

        ( Conv, [ x, f ] ) ->
            if List.length params.a > 6 && List.drop 6 params.a /= [ 1, 1 ] then
                [ Just (E.failWith dilatedConvMessage (O.zerosLike x)), Just (E.failWith dilatedConvMessage (O.zerosLike f)) ]

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


{-| The build error on the cotangents of a dilated `Conv`, which has no rule. A strided
convolution's filter cotangent is such a `Conv`, so this is what differentiating it again gives.
-}
dilatedConvMessage : String
dilatedConvMessage =
    "conv: a dilated convolution cannot be differentiated (nor, therefore, the filter gradient of a strided convolution)"


{-| Returns the first integer of `params.a`, or 0 when it is empty. Several rules read an axis this
way, and the pool rules their window size.
-}
first : Params -> Int
first params =
    Maybe.withDefault 0 (List.head params.a)


{-| Returns the cotangent `g` of a reduction of `x` repeated along the reduced axis, back to `x`'s
shape. `params` is the reduction's `[axis, keep]`; params of any other layout give `g` unchanged.
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


{-| Returns the cotangent of `x` for its maximum or minimum `out` along an axis, given `out`'s
cotangent `g`. Each lane's cotangent goes to the elements of the lane equal to `out`, divided evenly
between them when there are several. `params` is read as for `spread`, and params of any other
layout give `g` unchanged.
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


{-| Returns the cotangents of `x` and `w` for their matrix product, given its cotangent `g`, in four
cases by rank: two vectors (a dot product), a vector `x`, a vector `w`, and two operands of rank 2
or more. A vector's cotangent is summed over the batch axes here. In the last case each cotangent
has `g`'s batch axes, which an operand with fewer batch axes, or a batch axis of size 1 against a
larger one, does not have.
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


{-| Returns the cotangents of `x`, the gain and the bias of a layer normalisation of `x` over its
last axis, given the result's cotangent `g`. The normalisation is x̂ = (x − μ) / √(σ² + ε) and
y = x̂ · gain + bias, with ε the first entry of `params.f`, or 1e-5 when it is empty. The gain's and
the bias's cotangents are summed over every axis but the last.
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


{-| Returns the NHWC tensor `e` with zeros appended below and to the right until its height and
width are those of the NHWC shape `target`. Shapes of any other rank give `e` unchanged.

A strided convolution may never read the last rows or columns of its input, which therefore have a
cotangent of 0. The transposed convolution that gives the input's cotangent stops short of them,
and this fills them in.

-}
padTo : List Int -> Expr -> Expr
padTo target e =
    case ( target, E.shape e ) of
        ( [ _, h, w, _ ], [ _, h2, w2, _ ] ) ->
            e |> O.pad 1 0 (h - h2) 0 |> O.pad 2 0 (w - w2) 0

        _ ->
            e


{-| Returns the cotangent of the filter, of shape `fshape` (kernel height, kernel width, input
channels, output channels), of a convolution of `x` with the strides and paddings `geometry`, given
the cotangent `g` of its result. An `fshape` or `geometry` of any other length gives `g` unchanged.

The cotangent is the correlation of `x` with `g`, computed as one more `Conv`: `x` with its batch
and channel axes swapped is the input, `g` is the filter, and the strides become dilations. Its
result is cut to the filter's size. With a stride above 1 that `Conv` is dilated, and `rule` gives a
dilated `Conv` cotangents carrying a build error.

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


{-| Returns the NHWC tensor `x` regrouped into its `k × k` windows, with shape
(n, h/k, k, w/k, k, c), and a function that repeats a pooled (n, h/k, w/k, c) tensor over every
element of its window in that shape. The pool rules of `Tensor.Internal.Shape` require `k` to
divide the height and the width. An `x` of any other rank gives `x` and `identity`.
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


{-| Returns `geometry`, the strides and paddings of a convolution of an input of shape `xs` with a
filter of shape `fs`, with its bottom and right padding cut by the rows and columns the
convolution never reads, (height + paddings − kernel height) mod stride and likewise for the width,
but not below 0. The transposed convolution with that geometry gives no rows or columns for them.
Where the padding is shorter than the cut, the unread rows include rows of the input itself, which
`padTo` gives a cotangent of 0. Shapes or a `geometry` of any other length, and a stride of 0 or
less (which `Tensor.Internal.Shape.conv` refuses), give `geometry` unchanged.
-}
unusedPaddingDropped : List Int -> List Int -> List Int -> List Int
unusedPaddingDropped geometry xs fs =
    case ( geometry, xs, fs ) of
        ( [ sh, sw, pt, pb, pl, pr ], [ _, h, w, _ ], [ kh, kw, _, _ ] ) ->
            if sh <= 0 || sw <= 0 then
                geometry

            else
                let
                    remH =
                        modBy sh (h + pt + pb - kh)

                    remW =
                        modBy sw (w + pl + pr - kw)
                in
                [ sh, sw, pt, Basics.max 0 (pb - remH), pl, Basics.max 0 (pr - remW) ]

        _ ->
            geometry
