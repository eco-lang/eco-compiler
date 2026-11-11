module Nn.Embedding exposing (Embedding, params, apply)

{-| A table of vectors looked up by integer index.
-}

import Param
import Tensor as T exposing (DType, Dim, Floating, Integral, R1, R2, Tensor)


type alias Embedding d v m =
    { table : Tensor Floating d (R2 v m) }


{-| Normal with standard deviation 0.02.
-}
params : DType Floating d -> Dim v -> Dim m -> Param.Spec (Embedding d v m)
params dt v m =
    Param.record Embedding
        |> Param.normal 0.02 .table dt (T.r2 v m)


apply : Embedding d v m -> Tensor Integral i (R1 s) -> Tensor Floating d (R2 s m)
apply p tokens =
    p.table |> T.rowsAt tokens
