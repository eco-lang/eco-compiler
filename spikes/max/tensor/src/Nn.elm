module Nn exposing (crossEntropy, crossEntropyIndices, mseLoss, dropout, attention, causalAttention, maxPool2d, avgPool2d)

{-| Losses, dropout, attention and pooling, as functions.
-}

import Tensor exposing (Dim, Floating, Integral, Mask, R0, R1, R2, R3, R4, Tensor)
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
                    O.select (full2 m) scores1 (O.fullLike -1.0e9 scores1)

                Nothing ->
                    scores1
    in
    O.matmul (O.softmax 2 scores) v


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
