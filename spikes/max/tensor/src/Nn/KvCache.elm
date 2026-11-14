module Nn.KvCache exposing (Cache, sig, write)

{-| Attention reads the keys and values of every position it attends to. When a sequence is
generated a few positions at a time, the keys and values of the earlier positions can be kept
instead of being computed again at each step, and a key/value cache is where they are kept. This
module is that cache: the record that holds it, its signature, and the write that replaces some
of its positions.

A cache has a fixed size. It holds `t` positions, for `g` heads of `j` features each: its keys and
its values both have shape g × t × j, with the positions on axis 1. A write replaces `s`
consecutive positions, from a given one, with the keys and values of `s` new positions, and leaves
the size as it was.

The cache does not record how many of its positions have been written. The position a write starts
at is an argument of `write`, and the cache's tensors hold all `t` positions, those not yet written
included.


# The cache

@docs Cache, sig, write

-}

import Signature as Sig exposing (Sig)
import Tensor as T exposing (DType, Dim, I64, R0, R1, R3, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E
import Tensor.Internal.Ops as O
import Tensor.Internal.Types as I


{-| A key/value cache of dtype `d`: the keys and the values held for each of `t` positions, for `g`
heads of `j` features each.
-}
type alias Cache d g t j =
    { keys : Tensor Float d (R3 g t j), values : Tensor Float d (R3 g t j) }


{-| Creates the signature of a cache of dtype `dt` and sizes `g`, `t` and `j`: two tensors, the keys
then the values, labelled `keys` and `values`.

Both slots are fed, like those of any `Signature` leaf. Keeping the cache in buffers between runs is
up to whatever builds the graph: `Infer.step` makes the slots of its state signature resident.

-}
sig : DType Float d -> Dim g -> Dim t -> Dim j -> Sig (Cache d g t j)
sig dt g t j =
    Sig.record Cache
        |> Sig.field .keys (Sig.label "keys" (Sig.tensor dt (T.r3 g t j)))
        |> Sig.field .values (Sig.label "values" (Sig.tensor dt (T.r3 g t j)))


{-| Returns the cache with the keys (the second argument) and the values (the third) of `s` new
positions written at positions p … p + s − 1 along its positions axis, where p is the value of the
first argument. The keys replace the cache's keys there and the values its values; the other
positions are unchanged.

`s` is read from the keys. Values for a different number of positions make the new values a build
error. A written position outside 0 … t − 1 is not a build error; `Tensor.Eval` refuses it when it
runs, as for `Tensor.put`.

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
