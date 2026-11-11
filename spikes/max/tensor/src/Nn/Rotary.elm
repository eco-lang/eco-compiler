module Nn.Rotary exposing (Rotary, Pairing(..), apply)

{-| Rotary position embeddings (RoPE): each pair of a head's features is rotated by an angle
proportional to its position, at a frequency base^(−2k/j) for pair k of j features.

`Interleaved` pairs features (2k, 2k + 1), as llama2.c and Meta's checkpoints do; `Halves` pairs
(k, k + j/2), as Hugging Face's Llama code (`rotate_half`) does. Positions are a tensor, so a cache's
offset can be a runtime value; their sequence is the queries', so angles for another sequence do not
compile.

-}

import Tensor exposing (Floating, I64, Integral, R1, R3, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I


type Pairing
    = Interleaved
    | Halves


type alias Rotary =
    { base : Float, pairing : Pairing }


apply : Rotary -> Tensor Integral I64 (R1 s) -> Tensor Floating d (R3 h s j) -> Tensor Floating d (R3 h s j)
apply r positions x =
    I.Tensor (rotate r (I.tensor positions) (I.tensor x))


rotate : Rotary -> Expr -> Expr -> Expr
rotate r positions x =
    case E.shape x of
        [ h, s, j ] ->
            if modBy 2 j /= 0 then
                E.failWith ("Rotary: a head of " ++ String.fromInt j ++ " features has no pairs (it must be even)") x

            else
                let
                    half =
                        j // 2

                    dt =
                        E.dtype x

                    inverseFrequencies =
                        E.const F32 [ half ] (List.map (\k -> r.base ^ (-2 * toFloat k / toFloat j)) (List.range 0 (half - 1)))

                    -- [s, half], computed in f32
                    angles =
                        O.mul (O.broadcastAxis 1 (O.cast F32 positions)) (O.broadcastAxis 0 inverseFrequencies)

                    cosA =
                        O.broadcastAxis 0 (O.cast dt (O.unary P.Cos angles))

                    sinA =
                        O.broadcastAxis 0 (O.cast dt (O.unary P.Sin angles))

                    turn a b =
                        ( O.sub (O.mul a cosA) (O.mul b sinA), O.add (O.mul a sinA) (O.mul b cosA) )
                in
                case r.pairing of
                    Halves ->
                        let
                            ( p, q ) =
                                turn (O.slice [ 0, 0, 0 ] [ h, s, half ] x) (O.slice [ 0, 0, half ] [ h, s, half ] x)
                        in
                        O.concat 2 [ p, q ]

                    Interleaved ->
                        let
                            pairs =
                                O.reshape [ h, s, half, 2 ] x

                            member i =
                                O.reshape [ h, s, half ] (O.slice [ 0, 0, 0, i ] [ h, s, half, 1 ] pairs)

                            ( p, q ) =
                                turn (member 0) (member 1)
                        in
                        O.reshape [ h, s, j ] (O.concat 3 [ O.insertAxis 3 p, O.insertAxis 3 q ])

        _ ->
            E.failWith "Rotary: needs heads × positions × features" x
