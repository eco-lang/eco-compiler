module Optim exposing (Optimizer, Rate(..), Hyper, sgd, sgdWith, adamW, adamWWith, custom, clipGlobalNorm)

{-| How parameters move along their gradients. An optimizer is a value: `Train.step` gives it each
trainable parameter, its gradient and its state slots (tensors of the parameter's shape, zero at
first), and adds the state to the graph's resident buffers.

Updates are computed in f32 and cast back to each parameter's dtype.

-}

import Tensor exposing (Elems, F32, Floating, R0, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I


type alias Optimizer =
    I.Optimizer


{-| A rate fixed in the graph, or passed by the host with every step (so a schedule does not
recompile the graph): `Train.step` then adds a fed input `rate : f32 []`.
-}
type Rate
    = Fixed Float
    | PerStep


internalRate : Rate -> I.Rate
internalRate r =
    case r of
        Fixed f ->
            I.Fixed f

        PerStep ->
            I.PerStep


{-| What an update sees besides one parameter: the rate and the step number (from 1).
-}
type alias Hyper =
    { rate : Tensor Floating F32 R0, step : Tensor Floating F32 R0 }


times : Expr -> Expr -> Expr
times s x =
    O.mul x (O.broadcastTo (E.shape x) s)


k : Float -> Expr -> Expr
k v x =
    O.scalarLike v x


sgd : Float -> Optimizer
sgd rate =
    sgdWith { rate = Fixed rate, momentum = 0, weightDecay = 0 }


{-| With momentum μ and weight decay λ: g' = g + λw; v = μv + g'; w = w - η v.
-}
sgdWith : { rate : Rate, momentum : Float, weightDecay : Float } -> Optimizer
sgdWith cfg =
    I.Optimizer
        { rate = internalRate cfg.rate
        , slots =
            if cfg.momentum /= 0 then
                1

            else
                0
        , clip = Nothing
        , update =
            \h w g state ->
                let
                    g1 =
                        if cfg.weightDecay /= 0 then
                            O.add g (O.mul (k cfg.weightDecay w) w)

                        else
                            g
                in
                case state of
                    [ v ] ->
                        let
                            v1 =
                                O.add (O.mul (k cfg.momentum v) v) g1
                        in
                        ( O.sub w (times h.rate v1), [ v1 ] )

                    _ ->
                        ( O.sub w (times h.rate g1), [] )
        }


adamW : Float -> Optimizer
adamW rate =
    adamWWith { rate = Fixed rate, beta1 = 0.9, beta2 = 0.999, epsilon = 1.0e-8, weightDecay = 0, biasCorrection = True }


{-| AdamW (Loshchilov and Hutter): m = β₁m + (1-β₁)g; v = β₂v + (1-β₂)g²; with bias correction
m̂ = m / (1-β₁ᵗ), v̂ = v / (1-β₂ᵗ); w = w - η (m̂ / (√v̂ + ε) + λw).
-}
adamWWith : { rate : Rate, beta1 : Float, beta2 : Float, epsilon : Float, weightDecay : Float, biasCorrection : Bool } -> Optimizer
adamWWith cfg =
    I.Optimizer
        { rate = internalRate cfg.rate
        , slots = 2
        , clip = Nothing
        , update =
            \h w g state ->
                case state of
                    [ m, v ] ->
                        let
                            m1 =
                                O.add (O.mul (k cfg.beta1 m) m) (O.mul (k (1 - cfg.beta1) g) g)

                            v1 =
                                O.add (O.mul (k cfg.beta2 v) v) (O.mul (k (1 - cfg.beta2) g) (O.square g))

                            -- 1 - βᵗ = 1 - exp (t log β), a scalar
                            correction beta =
                                O.sub (k 1 h.step) (O.unary Exp (O.mul h.step (k (logBase e beta) h.step)))

                            ( mHat, vHat ) =
                                if cfg.biasCorrection then
                                    ( O.div m1 (O.broadcastTo (E.shape m1) (correction cfg.beta1))
                                    , O.div v1 (O.broadcastTo (E.shape v1) (correction cfg.beta2))
                                    )

                                else
                                    ( m1, v1 )

                            direction =
                                O.div mHat (O.add (O.unary Sqrt vHat) (k cfg.epsilon vHat))

                            decayed =
                                if cfg.weightDecay /= 0 then
                                    O.add direction (O.mul (k cfg.weightDecay w) w)

                                else
                                    direction
                        in
                        ( O.sub w (times h.rate decayed), [ m1, v1 ] )

                    _ ->
                        ( w, state )
        }


{-| An optimizer written element-wise: `slots` state tensors per parameter (zeros at first). The
update sees each parameter as `Tensor Floating F32 Elems`, on which only rank-free operations
apply, so one function serves every parameter.
-}
custom :
    { rate : Rate
    , slots : Int
    , update : Hyper -> { param : Tensor Floating F32 Elems, grad : Tensor Floating F32 Elems, state : List (Tensor Floating F32 Elems) } -> { param : Tensor Floating F32 Elems, state : List (Tensor Floating F32 Elems) }
    }
    -> Optimizer
custom cfg =
    I.Optimizer
        { rate = internalRate cfg.rate
        , slots = cfg.slots
        , clip = Nothing
        , update =
            \h w g state ->
                let
                    r =
                        cfg.update { rate = I.Tensor h.rate, step = I.Tensor h.step }
                            { param = I.Tensor w, grad = I.Tensor g, state = List.map I.Tensor state }
                in
                ( I.tensor r.param, List.map I.tensor r.state )
        }


{-| Scale every gradient by min(1, maxNorm / ‖all gradients‖) before the update.
-}
clipGlobalNorm : Float -> Optimizer -> Optimizer
clipGlobalNorm maxNorm (I.Optimizer o) =
    I.Optimizer { o | clip = Just maxNorm }
