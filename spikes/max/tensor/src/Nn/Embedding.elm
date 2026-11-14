module Nn.Embedding exposing
    ( Embedding, params
    , apply, unembed
    )

{-| A model whose inputs are tokens, integer ids drawn from a vocabulary, needs a vector for each
token to compute with. This module describes the table as a parameter record and gives two functions
over it.

The vocabulary has `v` entries, and a token is named by its _id_, an integer from 0 to v − 1. The
_table_ is a `v` × `m` matrix whose row i is the vector of `m` features for the token with id i.
`apply` looks rows up by id, turning a sequence of ids into a sequence of vectors. `unembed` goes
the other way: it scores a vector against every row, giving one score for each entry of the
vocabulary.

Using the input table for that output scoring, rather than a separate output matrix, is called
_tying_ the two. A model that uses both functions on one `Embedding` has a single table that
serves both.


# Parameters

@docs Embedding, params


# Applying

@docs apply, unembed

-}

import Param
import Tensor as T exposing (DType, Dim, R1, R2, Tensor)


{-| A token-embedding table: one vector of `m` features for each of the `v` entries of a
vocabulary, in dtype `d`. Row i of `table` is the vector of the token with id i.
-}
type alias Embedding d v m =
    { table : Tensor Float d (R2 v m) }


{-| Describes an `Embedding` whose `v` × `m` table has dtype `dt`. The table is one trainable
field, whose first values are drawn from a normal distribution with mean 0 and standard deviation
0.02.
-}
params : DType Float d -> Dim v -> Dim m -> Param.Spec (Embedding d v m)
params dt v m =
    Param.record Embedding
        |> Param.normal 0.02 .table dt (T.r2 v m)


{-| Returns the table's row for each id in `tokens`, in order: row i of the result is the vector of
the token whose id is the i-th element of `tokens`.

As `Tensor.rowsAt` states, an id outside 0 … v − 1 is not a build error; `Tensor.Eval` refuses it
when it runs.

-}
apply : Embedding d v m -> Tensor Int i (R1 s) -> Tensor Float d (R2 s m)
apply p tokens =
    p.table |> T.rowsAt tokens


{-| Returns, for each of the `s` rows of `x`, one score per vocabulary entry: x · tableᵀ, whose
element (i, j) is the dot product of row i of `x` with the vector of the token with id j. This is
the output projection tied to the table that `apply` reads.
-}
unembed : Embedding d v m -> Tensor Float d (R2 s m) -> Tensor Float d (R2 s v)
unembed p x =
    x |> T.matmul (T.transpose p.table)
