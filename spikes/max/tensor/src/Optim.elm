module Optim exposing
    ( Optimizer, Rate(..), Hyper
    , sgd, sgdWith, adamW, adamWWith
    , custom
    , clipGlobalNorm
    )

{-| Training moves each trainable parameter against the gradient of the loss, and an optimizer is
the rule that decides how each one moves. This module makes optimizers, namely stochastic gradient
descent (SGD), AdamW and an optimizer with an update written by hand, and can add a bound on the
size of the gradients to an optimizer.

An optimizer is a value, not a graph. `Train.step` applies it when it builds a training graph, to
each trainable parameter separately: the optimizer's _update_ is given one parameter, its gradient
and that parameter's own state, and gives back the parameter's new value and its new state. The one
rule that reads the gradients of all the trainable parameters together is clipping
(`clipGlobalNorm`), which is applied to the gradients before any update.

Three quantities recur. The _learning rate_ is the factor by which the built-in optimizers scale
each move; it is either fixed when the optimizer is made or given with every run of the training
graph (`Rate`). A parameter's _state_ is the tensors an optimizer carries for it from one step to
the next, such as a running average of its gradient. Each of them is a _state slot_: a tensor of the
parameter's shape that is kept between runs in a resident buffer (see `Train`), and that
`Train.initial` and `Train.initialFrom` start at zero. For an optimizer that keeps state, the _step_
(`Hyper`) is one more than the training graph's step counter, which those two functions also start
at zero.

`Train.step` gives an update the parameter, its gradient and its state in f32, whatever the
parameter's dtype, and casts the new parameter back to that dtype.

In the update formulas below, w is a parameter, g its gradient, η the learning rate and t the step.
Every operation in them is element-wise.


# Types

@docs Optimizer, Rate, Hyper


# SGD and AdamW

@docs sgd, sgdWith, adamW, adamWWith


# Your own

`custom` makes an optimizer from an update written with the operations of `Tensor`.

@docs custom


# Clipping

@docs clipGlobalNorm

-}

import Tensor exposing (Elems, F32, R0, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..), Prim(..))
import Tensor.Internal.Types as I


{-| A rule for updating the trainable parameters of a model in training, together with where its
learning rate comes from, how many state slots it keeps for each trainable parameter, and whether it
clips the gradients.

The functions of this module are the only way to make one, and `Train.step` is what applies it.

-}
type alias Optimizer =
    I.Optimizer


{-| Where an optimizer's learning rate comes from.

`Fixed` carries the rate, which is written into the training graph as a constant, so a different
rate needs a new graph.

`PerStep` makes the rate an input of the training graph, fed with every run, so that it can change
from one run to the next, as a schedule needs. `Train.step` describes that input, `rate`.

-}
type Rate
    = Fixed Float
    | PerStep


{-| Returns the internal rate that `r` stands for.
-}
internalRate : Rate -> I.Rate
internalRate r =
    case r of
        Fixed f ->
            I.Fixed f

        PerStep ->
            I.PerStep


{-| What a `custom` update is given besides one parameter's tensors: the learning rate and the step,
each an f32 scalar.

`rate` is the fixed rate or the run's `rate` input, as `Rate` says. When the optimizer has state
slots, `step` is one more than the training graph's step counter, which `Train.initial` and
`Train.initialFrom` start at zero. An optimizer with none has no counter, and its `step` is 1 on
every step. `Train.step` describes the counter.

-}
type alias Hyper =
    { rate : Tensor Float F32 R0, step : Tensor Float F32 R0 }


{-| Returns `x` multiplied element-wise by the scalar `s`, broadcast to `x`'s shape.
-}
times : Expr -> Expr -> Expr
times s x =
    O.mul x (O.broadcastTo (E.shape x) s)


{-| Returns a rank-0 constant of `x`'s dtype holding `v`.
-}
k : Float -> Expr -> Expr
k v x =
    O.scalarLike v x


{-| Returns stochastic gradient descent at the fixed rate η = `rate`, with no momentum and no weight
decay: w ← w − η g. It keeps no state.
-}
sgd : Float -> Optimizer
sgd rate =
    sgdWith { rate = Fixed rate, momentum = 0, weightDecay = 0 }


{-| Returns stochastic gradient descent with momentum μ = `momentum` and weight decay
λ = `weightDecay`:

    g' = g + λw
    v ← μv + g'
    w ← w − η v

v, the velocity, is the one state slot. A `momentum` of 0 keeps no state, and the parameter moves by
w ← w − η g'. The weight decay is added to the gradient, so with momentum it is accumulated in v as
well.

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


{-| Returns the optimizer `adamWWith` gives at the fixed rate `rate`, with β₁ = 0.9, β₂ = 0.999,
ε = 10⁻⁸, bias correction, and no weight decay, which makes it Adam.
-}
adamW : Float -> Optimizer
adamW rate =
    adamWWith { rate = Fixed rate, beta1 = 0.9, beta2 = 0.999, epsilon = 1.0e-8, weightDecay = 0, biasCorrection = True }


{-| Returns AdamW. Its two state slots, m and v, are running averages of the gradient and of its
square:

    m ← β₁m + (1 − β₁)g
    v ← β₂v + (1 − β₂)g²
    w ← w − η (m̂ / (√v̂ + ε) + λw)

where β₁ = `beta1`, β₂ = `beta2`, ε = `epsilon` and λ = `weightDecay`. With `biasCorrection`,
m̂ = m / (1 − β₁ᵗ) and v̂ = v / (1 − β₂ᵗ); without it, m̂ = m and v̂ = v. The weight decay is not
added to the gradient, so it does not pass through m and v, but it is still scaled by η.

The graph computes βᵗ as exp(t ln β), so with bias correction a negative β gives NaN.

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

                            -- 1 − βᵗ, a scalar
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


{-| Returns an optimizer at the rate `rate` that keeps `slots` state slots for each trainable
parameter and moves it by `update`. `Train.step` refuses one whose `slots` is less than 0.

The parameter's tensors are typed with `Tensor.Elems`, which stands for whatever shape the parameter
has, so one function serves every parameter; only the operations that accept a tensor of any shape
accept them.

`update` must give back a parameter of the shape it was given and `slots` state tensors of that
shape. `Train.step` refuses an optimizer whose update does not, as it describes.

-}
custom :
    { rate : Rate
    , slots : Int
    , update : Hyper -> { param : Tensor Float F32 Elems, grad : Tensor Float F32 Elems, state : List (Tensor Float F32 Elems) } -> { param : Tensor Float F32 Elems, state : List (Tensor Float F32 Elems) }
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


{-| Returns the optimizer with its gradients clipped by global norm: before any update, the
gradient of every trainable parameter is multiplied by min(1, `maxNorm` / n), where n is the square
root of the sum of the squares of the elements of all those gradients together, as `Train.step`
describes. A later `clipGlobalNorm` replaces the bound an earlier one set. `Train.step` refuses a
`maxNorm` that is not greater than 0, NaN included.
-}
clipGlobalNorm : Float -> Optimizer -> Optimizer
clipGlobalNorm maxNorm (I.Optimizer o) =
    I.Optimizer { o | clip = Just maxNorm }
