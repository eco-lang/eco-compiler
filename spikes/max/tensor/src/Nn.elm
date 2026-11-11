module Nn exposing
    ( crossEntropy, crossEntropyIndices, mseLoss, dropout, attention, causalAttention, maxPool2d, avgPool2d
    , upsampleNearest2d, timestepEmbedding, causalMaskAt, repeatHeads
    )

{-| Losses, dropout, attention and pooling, as functions.
-}

import Tensor exposing (Dim, Floating, I64, Integral, Mask, R0, R1, R2, R3, R4, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


{-| `logits |> crossEntropy targets`: the mean softmax cross-entropy over the batch, targets one-hot.
-}
crossEntropy : Tensor Floating d (R2 n c) -> Tensor Floating d (R2 n c) -> Tensor Floating d R0
crossEntropy targets logits =
    I.Tensor (O.xent (I.tensor logits) (I.tensor targets))


{-| The same with class indices.
-}
crossEntropyIndices : Tensor Integral i (R1 n) -> Tensor Floating d (R2 n c) -> Tensor Floating d R0
crossEntropyIndices labels logits =
    let
        l =
            I.tensor logits

        classes =
            List.drop 1 (E.shape l) |> List.head |> Maybe.withDefault 1
    in
    I.Tensor (O.xent l (O.oneHot (E.dtype l) classes (I.tensor labels)))


{-| `predictions |> mseLoss targets`: the mean squared error.
-}
mseLoss : Tensor Floating d s -> Tensor Floating d s -> Tensor Floating d R0
mseLoss targets predictions =
    I.Tensor (O.meanAll (O.square (O.sub (I.tensor predictions) (I.tensor targets))))


{-| Inverted dropout: elements zeroed with probability `rate`, the rest scaled by 1 / (1 - rate);
the identity when `training` is false.
-}
dropout : { rate : Float, training : Bool } -> Seed -> Tensor Floating d s -> Tensor Floating d s
dropout cfg s x =
    if not cfg.training || cfg.rate <= 0 then
        x

    else
        let
            (I.Mask keep) =
                Random.bernoulliLike (1 - cfg.rate) x s

            xe =
                I.tensor x
        in
        I.Tensor (O.select keep (O.mul xe (O.scalarLike (1 / (1 - cfg.rate)) xe)) (O.zerosLike xe))


{-| `queries |> attention options keys values`, per head: queries (h, s, j), keys (h, t, j), values
(h, t, e). `mask` hides key positions (False: not attended); `bias` is added to the scores.
-}
attention : { mask : Maybe (Mask (R2 s t)), bias : Maybe (Tensor Floating d (R2 s t)) } -> Tensor Floating d (R3 h t j) -> Tensor Floating d (R3 h t e) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e)
attention opts k v q =
    I.Tensor (attend (Maybe.map (\(I.Mask m) -> m) opts.mask) (Maybe.map I.tensor opts.bias) (I.tensor k) (I.tensor v) (I.tensor q))


{-| Each position attends to itself and earlier ones: queries and keys share the length `s`.
-}
causalAttention : Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s e)
causalAttention k v q =
    let
        s =
            List.drop 1 (E.shape (I.tensor q)) |> List.head |> Maybe.withDefault 1

        ones =
            O.broadcastTo [ s, s ] (E.scalar P.F32 1)

        lower =
            O.gt (O.bandPart -1 0 ones) (E.scalar P.F32 0)
    in
    I.Tensor (attend (Just lower) Nothing (I.tensor k) (I.tensor v) (I.tensor q))


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
                    -- −1e9, or the dtype's lowest where that is higher (f16: −65504)
                    O.select (full2 m) scores1 (O.fullLike (max -1.0e9 (O.lowest (E.dtype scores1))) scores1)

                Nothing ->
                    scores1
    in
    O.matmul (O.inF32 (O.softmax 2) scores) v


{-| Window = stride = `k`. Build time checks h = k * h2 and w = k * w2.
-}
maxPool2d : Int -> Dim h2 -> Dim w2 -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 c)
maxPool2d k h2 w2 x =
    I.Tensor (checkSpatial h2 w2 (O.maxPool k (I.tensor x)))


avgPool2d : Int -> Dim h2 -> Dim w2 -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 c)
avgPool2d k h2 w2 x =
    I.Tensor (checkSpatial h2 w2 (O.avgPool k (I.tensor x)))


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


{-| Nearest-neighbour upsampling by `f` in both spatial axes (each pixel becomes an f × f block).
Build time checks h2 = f · h and w2 = f · w.
-}
upsampleNearest2d : Int -> Dim h2 -> Dim w2 -> Tensor Floating d (R4 n h w c) -> Tensor Floating d (R4 n h2 w2 c)
upsampleNearest2d f (I.Dim h2) (I.Dim w2) x =
    I.Tensor (upsample f h2 w2 (I.tensor x))


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
                -- rank 4 throughout: copies along w, then whole rows along h
                x
                    |> O.reshape [ n * h, w, 1, c ]
                    |> O.broadcastTo [ n * h, w, f, c ]
                    |> O.reshape [ n, h, 1, w * f * c ]
                    |> O.broadcastTo [ n, h, f, w * f * c ]
                    |> O.reshape [ n, h2, w2, c ]

        _ ->
            E.failWith "upsampleNearest2d: needs an NHWC tensor" x


{-| Sinusoidal embeddings of (diffusion) timesteps, as diffusers' `get_timestep_embedding`: for
i < e/2, frequencies exp(−ln(maxPeriod) · i / (e/2 − shift)); the result is (sin, cos) of t times
them, or (cos, sin) with `cosFirst` (diffusers' `flip_sin_to_cos`). Build time checks e is even.
-}
timestepEmbedding : { maxPeriod : Float, cosFirst : Bool, shift : Float } -> Dim e -> Tensor Floating d (R1 n) -> Tensor Floating d (R2 n e)
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


{-| Which keys each query may see when `s` new queries start at position `p` of a cache of `t`
positions: query i (at p + i) sees keys 0 .. p + i.
-}
causalMaskAt : Tensor Integral I64 R0 -> Dim s -> Dim t -> Mask (R2 s t)
causalMaskAt p (I.Dim s) (I.Dim t) =
    let
        queries =
            O.add (O.range 0 1 s) (O.broadcastAxis 0 (O.cast P.SI64 (I.tensor p)))

        keys =
            O.range 0 1 t
    in
    I.Mask (O.le (O.broadcastAxis 0 keys) (O.broadcastAxis 1 queries))


{-| `g` key/value heads repeated for `h` query heads: head i reads key/value head i // (h / g), as
llama2.c and Hugging Face's `repeat_kv` do. Build time checks g divides h.
-}
repeatHeads : Dim h -> Tensor k d (R3 g t j) -> Tensor k d (R3 h t j)
repeatHeads (I.Dim h) x =
    I.Tensor (repeatKv h (I.tensor x))


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
