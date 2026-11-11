module Tensor.Internal.Types exposing (..)

{-| Every public type, with its constructor. The package does not expose this module: the public
modules re-export these as type aliases, so user code can name the types but cannot build or open
them.
-}

import Tensor.Internal.Expr exposing (Expr)
import Tensor.Internal.MlirBc as Bc
import Tensor.Internal.Prim exposing (DT)



-- TENSORS


type Tensor kind dtype shape
    = Tensor Expr


type Mask shape
    = Mask Expr


type Dim tag
    = Dim Int


type Shape s
    = Shape (List Int)


type DType kind dtype
    = DType DT


{-| The axis an operation removes or inserts.
-}
type Axis s r c
    = Axis Int


{-| The axis whose tag an operation replaces.
-}
type Retag s t a c
    = Retag Int


{-| A leading batch axis prepended.
-}
type Lift n s t
    = Lift


{-| Swaps of two axes, applied in order.
-}
type Perm s t
    = Perm (List ( Int, Int ))


type R0
    = R0 Never


type R1 a
    = R1 Never


type R2 a b
    = R2 Never


type R3 a b c
    = R3 Never


type R4 a b c d
    = R4 Never


type R5 a b c d e
    = R5 Never


type One
    = One Never


type Elems
    = Elems Never


type Floating
    = Floating Never


type Integral
    = Integral Never


type F16
    = F16 Never


type BF16
    = BF16 Never


type F32
    = F32 Never


type F64
    = F64 Never


type I8
    = I8 Never


type I32
    = I32 Never


type I64
    = I64 Never


type U8
    = U8 Never


type U64
    = U64 Never


tensor : Tensor k d s -> Expr
tensor (Tensor e) =
    e


mask : Mask s -> Expr
mask (Mask e) =
    e



-- SIGNATURES


{-| Where a graph input lives: sent with every run, or a host buffer that outlives runs (an output
with the same resident name replaces it).
-}
type Role
    = Fed
    | Resident String


type alias Slot =
    { label : String, dtype : Maybe DT, shape : Maybe (List Int), role : Role }


{-| A two-way description of a structured value of tensors. `build` takes the tensors it needs from
the front of the list; `flatten` gives them back in the same order.
-}
type SigBuilder r f
    = SigBuilder
        { slots : List Slot
        , build : List Expr -> ( f, List Expr )
        , flatten : r -> List Expr
        }



-- GRAPHS


type alias Spec =
    { name : String, dtype : String, shape : List Int, role : Role }


type Graph
    = Graph { name : String, inputs : List Spec, outputs : List Spec, ops : List Bc.Op }



-- PARAMETERS


type Init
    = HeUniform
    | HeNormal
    | XavierUniform
    | XavierNormal
    | Normal Float
    | Zeros
    | Ones


type FieldKind
    = Trainable Init
    | Frozen Init
    | Data


type alias Field =
    { dtype : DT, shape : List Int, kind : FieldKind }


type ParamBuilder r f
    = ParamBuilder
        { fields : List Field
        , build : List Expr -> ( f, List Expr )
        , flatten : r -> List Expr
        , checks : List (r -> Maybe String)
        }



-- RANDOMNESS, TRANSFORMS


type Seed
    = Seed Expr


type Shared a b
    = Shared { name : String, apply : a -> b }


{-| How a per-example value `a` and a batched value `b` relate: a batched value's leaf tensors
(marked batched or not), a per-example value built on placeholders for the batched leaves, a
per-example value's leaves, and a batched value from those leaves batched.
-}
type Batch a b
    = Batch
        { leaves : b -> List ( Expr, Bool )
        , perExample : b -> List Expr -> ( a, List Expr )
        , flatten : a -> List Expr
        , build : a -> List Expr -> ( b, List Expr )
        }



-- OPTIMIZERS


type Rate
    = Fixed Float
    | PerStep


type alias Hyper =
    { rate : Expr, step : Expr }


{-| An update for one parameter: rate and step, parameter, gradient, state slots; new parameter and
state slots.
-}
type Optimizer
    = Optimizer
        { rate : Rate
        , slots : Int
        , clip : Maybe Float
        , update : Hyper -> Expr -> Expr -> List Expr -> ( Expr, List Expr )
        }
