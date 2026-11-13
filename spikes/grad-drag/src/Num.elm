module Num exposing (Ops, floats, tensors)

{-| Arithmetic as a record, so that a model can be written once and run on plain `Float`s (to draw it,
and as the tests' reference) and on tensors (to differentiate it). The lens, the cube and the
epidemic are written this way.

Over tensors every operation is element-wise, and `const` fills the template's shape: a scalar
template gives scalar arithmetic, a vector template does many cases at once (the lens's rays).

@docs Ops, floats, tensors

-}

import Tensor as T exposing (F64, Tensor)


type alias Ops a =
    { add : a -> a -> a
    , sub : a -> a -> a
    , mul : a -> a -> a
    , div : a -> a -> a
    , sqrt : a -> a
    , cos : a -> a
    , sin : a -> a
    , exp : a -> a
    , const : Float -> a
    }


floats : Ops Float
floats =
    { add = (+)
    , sub = (-)
    , mul = (*)
    , div = (/)
    , sqrt = sqrt
    , cos = cos
    , sin = sin
    , exp = \x -> Basics.e ^ x
    , const = identity
    }


{-| Element-wise tensor arithmetic, constants shaped like `template`. (In the tensor package's pipeline
order `a |> T.minus b` is a − b, so `T.minus a b` is b − a.)
-}
tensors : Tensor Float F64 s -> Ops (Tensor Float F64 s)
tensors template =
    { add = T.plus
    , sub = \a b -> a |> T.minus b
    , mul = T.times
    , div = \a b -> a |> T.dividedBy b
    , sqrt = T.sqrt
    , cos = T.cos
    , sin = T.sin
    , exp = T.exp
    , const = \c -> T.fullLike c template
    }
