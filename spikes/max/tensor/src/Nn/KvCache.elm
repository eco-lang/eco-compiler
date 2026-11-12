module Nn.KvCache exposing (Cache, sig, write)

{-| A key/value cache for generating with attention: `g` key/value heads, room for `t` positions,
heads of `j` features. It is the state of an `Infer` graph, so it stays in the host's resident
buffers between steps.


# The cache

@docs Cache, sig, write

-}

import Signature as Sig exposing (Sig)
import Tensor as T exposing (DType, Dim, I64, R0, R1, R3, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| The `keys` and the `values`, each (g, t, j).
-}
type alias Cache d g t j =
    { keys : Tensor Float d (R3 g t j), values : Tensor Float d (R3 g t j) }


{-| The cache as graph state: tensors labelled `keys` and `values`.
-}
sig : DType Float d -> Dim g -> Dim t -> Dim j -> Sig (Cache d g t j)
sig dt g t j =
    Sig.record Cache
        |> Sig.field .keys (Sig.label "keys" (Sig.tensor dt (T.r3 g t j)))
        |> Sig.field .values (Sig.label "values" (Sig.tensor dt (T.r3 g t j)))


{-| `write position keys values cache`: the cache with these `s` steps' keys and values at positions
position .. position + s − 1. Positions past the cache's end are the caller's to prevent.
-}
write : Tensor Int I64 R0 -> Tensor Float d (R3 g s j) -> Tensor Float d (R3 g s j) -> Cache d g t j -> Cache d g t j
write position k v c =
    let
        steps =
            List.drop 1 (E.shape (I.tensor k)) |> List.head |> Maybe.withDefault 0

        indices : Tensor Int I64 (R1 s)
        indices =
            I.Tensor (O.add (O.range 0 1 steps) (O.broadcastAxis 0 (I.tensor position)))
    in
    { keys = c.keys |> T.put Axis.retag1of3 indices k
    , values = c.values |> T.put Axis.retag1of3 indices v
    }
