module Nn exposing
    ( crossEntropy, crossEntropyIndices, mseLoss
    , dropout
    , attention, causalAttention
    , maxPool2d, avgPool2d, upsampleNearest2d
    , timestepEmbedding
    , causalMaskAt, repeatHeads
    )

{-| The parts of a neural network that hold no parameters of their own: losses, dropout, attention,
pooling and upsampling, timestep embeddings, and two helpers that build an attention mask and
repeat attention heads. Each returns a tensor or a mask whose element values, like those of the
operations of `Tensor`, are computed only when it is run.

Like those of `Tensor`, the functions here that transform a tensor take it last, so that
`logits |> crossEntropy targets` and `queries |> attention options keys values` read left to right.
`causalMaskAt` takes its position tensor first.

The types fix ranks and axis tags but not sizes, so some sizes are checked when a result is made,
and a mismatch is a build error, as `Tensor` describes: a pooling window that does not divide the
image, a declared result size that differs from the computed one, an odd embedding width, a head
count asked of `repeatHeads` that is not a multiple of its input's, a number of keys in
`causalAttention` other than the number of queries. In the attention functions these axes of size 1
are repeated to match a larger size, not refused: a head count of 1 in the queries, keys or values,
and an axis of a mask or bias. Element values are not checked: a class label outside its range,
or a `causalMaskAt` position beyond the last key, is used as given.

Images are NHWC: rank-4 tensors of (batch, height, width, channels). Attention works on rank-3
tensors of (heads, positions, features) and treats each head separately. In the attention
functions' types `h` is the number of heads, `s` the number of query positions, `t` the number of
key positions, `j` the features of a query or key and `e` the features of a value. A mask says
which keys a query may read: True where it may, False where it may not.


# Losses

@docs crossEntropy, crossEntropyIndices, mseLoss


# Dropout

@docs dropout


# Attention

@docs attention, causalAttention


# Pooling and upsampling

Sizes are not in the types, so each of these takes the result's height and width as `Dim`s and
checks them against the sizes it computes.

@docs maxPool2d, avgPool2d, upsampleNearest2d


# Embeddings

@docs timestepEmbedding


# Masks and heads

A key/value cache holds the keys and values of the positions already processed, so that queries at
new positions can attend to them without computing them again. In grouped-query attention there are
fewer key/value heads, `g`, than query heads, `h`, and each key/value head serves a group of query
heads.

@docs causalMaskAt, repeatHeads

-}

import Tensor exposing (Dim, I64, Mask, R0, R1, R2, R3, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


{-| Returns the softmax cross-entropy of `logits` against `targets`, averaged over the `n` rows: the
mean over rows of −Σ targets · log (softmax logits), the softmax taken along each row.

`targets` need not be one-hot; any rows of weights are accepted. The gradient with respect to
`logits` is (softmax logits · s − targets) / n, where s is the sum of each row of `targets`: the
derivative of the loss for any targets.

-}
crossEntropy : Tensor Float d (R2 n c) -> Tensor Float d (R2 n c) -> Tensor Float d R0
crossEntropy targets logits =
    I.Tensor (O.xent (I.tensor logits) (I.tensor targets))


{-| Returns `crossEntropy` of `logits` against the one-hot rows of `labels`: row i is 1 at the class
`labels[i]` and 0 elsewhere.

A label outside 0 … c − 1 gives a row of zeros, with no error when the tensor is made or run. That
row adds 0 to the sum but still counts in the n rows the sum is averaged over, and its logits get a
gradient of 0.

-}
crossEntropyIndices : Tensor Int i (R1 n) -> Tensor Float d (R2 n c) -> Tensor Float d R0
crossEntropyIndices labels logits =
    let
        l =
            I.tensor logits

        classes =
            List.drop 1 (E.shape l) |> List.head |> Maybe.withDefault 1
    in
    I.Tensor (O.xent l (O.oneHot (E.dtype l) classes (I.tensor labels)))


{-| Returns the mean, over every element, of the squared difference between `predictions` and
`targets`.
-}
mseLoss : Tensor Float d s -> Tensor Float d s -> Tensor Float d R0
mseLoss targets predictions =
    I.Tensor (O.meanAll (O.square (O.sub (I.tensor predictions) (I.tensor targets))))


{-| Returns `x` with some elements dropped: for a `rate` between 0 and 1, each element is set to 0
with probability `rate`, and the others are multiplied by 1 / (1 − `rate`), which keeps each
element's expected value. When `training` is False, or `rate` is 0 or less, `x` is returned
unchanged. A `rate` of 1 or more gives zeros of `x`'s shape, whose gradient with respect to `x` is

1.  When `training` is True, a NaN `rate` is a build error.

Which elements are dropped is a draw on `seed`, as `Tensor.Random` describes, so two calls with one
seed, one rate and tensors of one shape drop the same elements; `Tensor.Random.salt` gives each
call its own seed. A broadcast axis of `x` becomes a real axis of size 1 in the result, as with
`Tensor.zerosLike`, unless `x` is returned unchanged.

-}
dropout : { rate : Float, training : Bool } -> Seed -> Tensor Float d s -> Tensor Float d s
dropout cfg s x =
    if not cfg.training || cfg.rate <= 0 then
        x

    else if isNaN cfg.rate then
        I.Tensor (E.failWith "dropout: the rate is NaN" (I.tensor x))

    else if cfg.rate >= 1 then
        I.Tensor (O.zerosLike (I.tensor x))

    else
        let
            (I.Mask keep) =
                Random.bernoulliLike (1 - cfg.rate) x s

            xe =
                I.tensor x
        in
        I.Tensor (O.select keep (O.mul xe (O.scalarLike (1 / (1 - cfg.rate)) xe)) (O.zerosLike xe))


{-| Returns scaled dot-product attention, each head separately: for each query, a weighted sum of
the values, the weights coming from the query's scores against the keys.

In each head the scores are the dot products of the `s` queries with the `t` keys, divided by √j,
plus `bias` when it is given, and a softmax over each query's `t` scores makes them weights. `mask`
and `bias` are shared by every head, and either is also repeated along an axis where it has size 1;
one with a broadcast axis is a build error.

Where `mask` is False the score is replaced by −10⁹, or by −65504, the lowest finite value, for
`f16`, not by −∞: a query whose keys are all masked gives every key the same weight. For `f16` and
`bf16` the softmax is computed in `f32` and its result cast back.

-}
attention : { mask : Maybe (Mask (R2 s t)), bias : Maybe (Tensor Float d (R2 s t)) } -> Tensor Float d (R3 h t j) -> Tensor Float d (R3 h t e) -> Tensor Float d (R3 h s j) -> Tensor Float d (R3 h s e)
attention opts k v q =
    I.Tensor (attend (Maybe.map (\(I.Mask m) -> m) opts.mask) (Maybe.map I.tensor opts.bias) (I.tensor k) (I.tensor v) (I.tensor q))


{-| Returns `attention` with no bias and a causal mask: query i attends to keys 0 … i. The mask is
`s` × `s`, `s` being the number of queries, so a number of keys other than `s` is a build error,
even for a single query. To attend from new positions to a longer key/value cache, use `attention`
with a mask from `causalMaskAt`.
-}
causalAttention : Tensor Float d (R3 h s j) -> Tensor Float d (R3 h s e) -> Tensor Float d (R3 h s j) -> Tensor Float d (R3 h s e)
causalAttention k v q =
    let
        s =
            List.drop 1 (E.shape (I.tensor q)) |> List.head |> Maybe.withDefault 1

        ones =
            O.broadcastTo [ s, s ] (E.scalar P.F32 1)

        t =
            List.drop 1 (E.shape (I.tensor k)) |> List.head |> Maybe.withDefault 1

        lower =
            O.gt (O.bandPart -1 0 ones) (E.scalar P.F32 0)

        result =
            attend (Just lower) Nothing (I.tensor k) (I.tensor v) (I.tensor q)
    in
    if t /= s then
        I.Tensor (E.failWith ("causalAttention: " ++ String.fromInt t ++ " keys, but " ++ String.fromInt s ++ " queries (the causal mask is square)") result)

    else
        I.Tensor result


{-| Returns the attention of the queries `q` over the keys `k` and values `v`, all three with heads
first, with the optional `s` × `t` `mask` and `bias` applied as `attention` describes.
-}
attend : Maybe Expr -> Maybe Expr -> Expr -> Expr -> Expr -> Expr
attend mask bias k v q =
    let
        j =
            List.drop 2 (E.shape q) |> List.head |> Maybe.withDefault 1

        scores0 =
            O.mul (O.matmul q (O.swapLast k)) (O.scalarLike (1 / sqrt (toFloat j)) q)

        full2 e =
            O.broadcastTo (E.shape scores0) (O.insertAxis 0 e)

        scores1 =
            case bias of
                Just b ->
                    O.add scores0 (full2 b)

                Nothing ->
                    scores0

        scores =
            case mask of
                Just m ->
                    -- f16 cannot hold −1e9, so it gets its lowest finite value instead.
                    O.select (full2 m) scores1 (O.fullLike (max -1.0e9 (O.lowest (E.dtype scores1))) scores1)

                Nothing ->
                    scores1
    in
    O.matmul (O.inF32 (O.softmax 2) scores) v


{-| Returns the maximum of each `k` × `k` window of the image `x`, the windows not overlapping: the
stride is `k`. `h2` and `w2` are the result's height and width, h / k and w / k. A `k` of 0 or
less, or one that does not divide both `h` and `w`, is a build error, and so is an `h2` or `w2`
other than the computed size.
-}
maxPool2d : Int -> Dim h2 -> Dim w2 -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h2 w2 c)
maxPool2d k h2 w2 x =
    I.Tensor (checkSpatial h2 w2 (O.maxPool k (I.tensor x)))


{-| Returns the mean of each `k` × `k` window of the image `x`, with the windows and the checks of
`maxPool2d`.
-}
avgPool2d : Int -> Dim h2 -> Dim w2 -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h2 w2 c)
avgPool2d k h2 w2 x =
    I.Tensor (checkSpatial h2 w2 (O.avgPool k (I.tensor x)))


{-| Returns the pooled image `e`, failed with a build error when its height and width are not the
sizes `h2` and `w2` hold. A poisoned `e`, or one that is not rank 4, is returned as it is.
-}
checkSpatial : Dim h2 -> Dim w2 -> Expr -> Expr
checkSpatial (I.Dim h2) (I.Dim w2) e =
    case E.shape e of
        [ _, h, w, _ ] ->
            if E.poisoned e || (h == h2 && w == w2) then
                e

            else
                E.failWith ("the result is " ++ String.fromInt h ++ " × " ++ String.fromInt w ++ ", but its dimensions say " ++ String.fromInt h2 ++ " × " ++ String.fromInt w2) e

        _ ->
            e


{-| Returns the image `x` enlarged `f` times in height and width by repeating pixels: each pixel
becomes an `f` × `f` block of copies of itself. `h2` and `w2` are the result's height and width. An
`f` below 1, or an `h2` or `w2` other than `f` times the input's, is a build error.
-}
upsampleNearest2d : Int -> Dim h2 -> Dim w2 -> Tensor Float d (R4 n h w c) -> Tensor Float d (R4 n h2 w2 c)
upsampleNearest2d f (I.Dim h2) (I.Dim w2) x =
    I.Tensor (upsample f h2 w2 (I.tensor x))


{-| Returns the `n` × `h` × `w` × `c` image `x` with each pixel repeated into an `f` × `f` block,
of size `h2` × `w2`, or `x` failed with a build error when `f` is below 1, `h2` or `w2` is not `f`
times the input's size, or `x` is not rank 4.
-}
upsample : Int -> Int -> Int -> Expr -> Expr
upsample f h2 w2 x =
    case E.shape x of
        [ n, h, w, c ] ->
            if f < 1 || h2 /= f * h || w2 /= f * w then
                E.failWith
                    ("upsampleNearest2d: "
                        ++ String.fromInt h
                        ++ " × "
                        ++ String.fromInt w
                        ++ " by "
                        ++ String.fromInt f
                        ++ " is not "
                        ++ String.fromInt h2
                        ++ " × "
                        ++ String.fromInt w2
                    )
                    x

            else
                -- Repeats each pixel along w, then each widened row along h.
                x
                    |> O.reshape [ n * h, w, 1, c ]
                    |> O.broadcastTo [ n * h, w, f, c ]
                    |> O.reshape [ n, h, 1, w * f * c ]
                    |> O.broadcastTo [ n, h, f, w * f * c ]
                    |> O.reshape [ n, h2, w2, c ]

        _ ->
            E.failWith "upsampleNearest2d: needs an NHWC tensor" x


{-| Returns sinusoidal embeddings of the timesteps `t`, one row of `e` features per timestep: the
sines of the timestep times each of e / 2 frequencies, followed by their cosines, or the cosines
first when `cosFirst` is True.

Frequency k, for k = 0 … e/2 − 1, is exp(−ln(`maxPeriod`) · k / (e/2 − `shift`)). An odd `e` is a
build error. The frequencies become constants of `t`'s dtype, and the products, sines and cosines
are computed in that dtype.

-}
timestepEmbedding : { maxPeriod : Float, cosFirst : Bool, shift : Float } -> Dim e -> Tensor Float d (R1 n) -> Tensor Float d (R2 n e)
timestepEmbedding cfg (I.Dim e) t =
    let
        te =
            I.tensor t
    in
    if modBy 2 e /= 0 then
        I.Tensor (E.failWith ("timestepEmbedding: " ++ String.fromInt e ++ " features cannot hold sine and cosine halves (it must be even)") te)

    else
        let
            half =
                e // 2

            frequencies =
                E.const (E.dtype te) [ half ] (List.map (\i -> Basics.e ^ (-(logBase Basics.e cfg.maxPeriod) * toFloat i / (toFloat half - cfg.shift))) (List.range 0 (half - 1)))

            angles =
                O.mul (O.broadcastAxis 1 te) (O.broadcastAxis 0 frequencies)

            sines =
                O.unary P.Sin angles

            cosines =
                O.unary P.Cos angles
        in
        I.Tensor
            (O.concat 1
                (if cfg.cosFirst then
                    [ cosines, sines ]

                 else
                    [ sines, cosines ]
                )
            )


{-| Returns the causal mask for `s` new queries over a key/value cache of `t` positions, the first
new query being at position `p`: query i, at position `p` + i, may attend to keys 0 … `p` + i.

`p` is a tensor, so it can be a graph input, and nothing checks it against `t`.

-}
causalMaskAt : Tensor Int I64 R0 -> Dim s -> Dim t -> Mask (R2 s t)
causalMaskAt p (I.Dim s) (I.Dim t) =
    let
        queries =
            O.add (O.range 0 1 s) (O.broadcastAxis 0 (O.cast P.SI64 (I.tensor p)))

        keys =
            O.range 0 1 t
    in
    I.Mask (O.le (O.broadcastAxis 0 keys) (O.broadcastAxis 1 queries))


{-| Returns the `g` key/value heads of `x` repeated to make `h` heads, one for each query head:
head i of the result is head i // (h / g) of `x`, so each key/value head serves h / g consecutive
query heads. An `h` that is not a multiple of `g`, or an `x` with no heads, is a build error.
-}
repeatHeads : Dim h -> Tensor k d (R3 g t j) -> Tensor k d (R3 h t j)
repeatHeads (I.Dim h) x =
    I.Tensor (repeatKv h (I.tensor x))


{-| Returns the `g` × `t` × `j` tensor `x` with each head repeated h / g times in place, or `x`
failed with a build error when `g` does not divide `h` or `x` is not rank 3.
-}
repeatKv : Int -> Expr -> Expr
repeatKv h x =
    case E.shape x of
        [ g, t, j ] ->
            if g <= 0 || modBy g h /= 0 then
                E.failWith ("repeatHeads: " ++ String.fromInt h ++ " heads are not a multiple of " ++ String.fromInt g ++ " key/value heads") x

            else if h == g then
                x

            else
                x
                    |> O.reshape [ g, 1, t, j ]
                    |> O.broadcastTo [ g, h // g, t, j ]
                    |> O.reshape [ h, t, j ]

        _ ->
            E.failWith "repeatHeads: needs heads × positions × features" x
