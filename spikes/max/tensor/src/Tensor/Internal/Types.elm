module Tensor.Internal.Types exposing (..)

{-| Elm hides a type's constructors only from other modules, and the modules of this package need to
open one another's values: `Signature` takes a `DType` and a `Shape` apart, `Graph` a signature,
`Train` an optimizer. The types they share are therefore defined here, with their constructors
exposed, and the package does not expose this module. Code inside the package imports it to make
and open values. Code outside the package can only name the types, through aliases the public
modules declare (`Tensor.Tensor`, `Signature.Sig`, `Graph.Graph`, `Optim.Optimizer` and others),
and an alias does not carry its type's constructors.

This is not a list of every public type. `Role`, `Slot`, `Spec`, `Init`, `FieldKind`, `Field`,
`Rate` and `Hyper` are used only inside the package; `Graph` and `Optim` declare public look-alikes
of four of them (`Graph.Role`, `Graph.Spec`, `Optim.Rate`, `Optim.Hyper`) and convert at the
boundary. Some opaque public types are defined in their own modules instead, such as
`Tensor.Eval.Prepared` and the types of `Nn.Stack`.

The tensor types at the top of the file are wrappers with _phantom_ type parameters: parameters
that appear in a type but in none of its values. A `Tensor kind dtype shape` holds only an
expression (`Tensor.Internal.Expr`). Its _kind_ is the Elm type of its elements (`Float` or `Int`),
its _dtype tag_ names its element type (`F32`, `I64` ..), and a _rank type_ (`R2 Batch Hidden`) as
its shape gives the number of its axes and a tag for each. The compiler checks that the package's
typed functions are applied to values whose parameters agree, but nothing relates the parameters to
the expression inside, which carries its own dtype and shape, computed when it is made. Any code
that imports this module can wrap any expression under any parameters, so a value's type is only as
right as the code in the package that made it.

The types used only as type arguments (the rank types `R0` .. `R5`, the axis tag `One`, the shape
parameter `Elems`, and the dtype tags `F16` .. `U64`) each have one constructor holding `Never`, so
none of them has a value. The dtype tags spell the integer dtypes `I8`, `I32`, `I64`, `U8` and
`U64`, where `Tensor.Internal.Prim.DT` says `SI8` .. `UI64` and the dtype names say `si8` .. `ui64`.

The rest of the file holds the descriptions the public modules build around tensors: signatures,
built graphs, parameter descriptions, seeds, shared functions, batch descriptions and optimizers.

-}

import Tensor.Internal.Expr exposing (Expr)
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Prim exposing (DT)
import Tensor.Internal.Values exposing (Values)



-- TENSORS


{-| A typed tensor: an expression with three phantom parameters, its kind (`Float` or `Int`), its
dtype tag and its shape. As the module docstring says, nothing checks the expression against them.
-}
type Tensor kind dtype shape
    = Tensor Expr


{-| A tensor of booleans (dtype `bool`), with a phantom shape parameter and no kind or dtype
parameter.
-}
type Mask shape
    = Mask Expr


{-| The size of one axis, with a phantom tag naming the axis (`Dim Hidden`, where the user declares
`type Hidden = Hidden`).

The size may be any `Int`: nothing here requires it to be positive, and two `Dim`s with one tag may
hold different sizes.

-}
type Dim tag
    = Dim Int


{-| The sizes of a tensor's axes, outermost first, with a phantom rank type `s` (`R2 Batch Hidden`).
`Tensor.scalar` and `Tensor.r1` .. `Tensor.r5` make a list whose length is the rank.
-}
type Shape s
    = Shape (List Int)


{-| An element type, with two parameters: its kind (`Float` or `Int`) and a phantom dtype tag. It
holds the dtype and the conversion of a list of elements of its kind to `Values`.

The package makes `DType`s only as `Tensor`'s dtype values (`float32`, `int64` ..), where each
floating-point dtype converts with `FloatValues` and each integer dtype with `IntValues`. There is
no `DType` for `bool`.

-}
type DType kind dtype
    = DType DT (List kind -> Values)


{-| Returns the dtype a `DType` stands for.
-}
dtOf : DType k d -> DT
dtOf (DType d _) =
    d


{-| Returns the conversion a `DType` holds.
-}
valuesOf : DType k d -> List k -> Values
valuesOf (DType _ conv) =
    conv


{-| An axis, given by its position counting from 0 at the outermost, with phantom parameters for the
shape with the axis (`s`), the shape without it (`r`) and the axis's tag (`c`).

One value serves both an operation that removes the axis from `s`, giving `r`, and one that inserts
it into `r`, giving `s`. The package makes `Axis` values only in the generated `Tensor.Axis`, one
for each rank and position.

-}
type Axis s r c
    = Axis Int


{-| An axis that an operation keeps but may resize, given by its position counting from 0 at the
outermost, with phantom parameters for the shape before (`s`) and after (`t`) and the axis's tag
before (`a`) and after (`c`). The package makes `Retag` values only in the generated `Tensor.Axis`.
-}
type Retag s t a c
    = Retag Int


{-| A statement that shape `t` is shape `s` with a leading axis tagged `n` prepended. Its one
constructor carries nothing; only its type says anything. The package makes `Lift` values only in
the generated `Tensor.Axis`.
-}
type Lift n s t
    = Lift


{-| A reordering of the axes of shape `s` into shape `t`, held as swaps of two axis positions,
applied in list order. `Tensor.Axis` makes single swaps, and `Tensor.Axis.andThen` joins them.
-}
type Perm s t
    = Perm (List ( Int, Int ))


{-| The rank type of a scalar: no axes.
-}
type R0
    = R0 Never


{-| The rank type of a shape with one axis, tagged `a`.
-}
type R1 a
    = R1 Never


{-| The rank type of a shape with two axes, tagged `a` and `b`, outermost first.
-}
type R2 a b
    = R2 Never


{-| The rank type of a shape with three axes, tagged outermost first.
-}
type R3 a b c
    = R3 Never


{-| The rank type of a shape with four axes, tagged outermost first.
-}
type R4 a b c d
    = R4 Never


{-| The rank type of a shape with five axes, tagged outermost first.
-}
type R5 a b c d e
    = R5 Never


{-| The axis tag of `Tensor.one` and `Tensor.insertOne`.
-}
type One
    = One Never


{-| A shape parameter standing for whatever shape a tensor has, so that one function can be applied
to tensors of different shapes (`Optim.custom`, `Param.mapElems`). It is not a rank type, so only
functions that accept a tensor of any shape accept one typed with it.
-}
type Elems
    = Elems Never


{-| The dtype tag of `f16`, IEEE half precision.
-}
type F16
    = F16 Never


{-| The dtype tag of `bf16`, bfloat16.
-}
type BF16
    = BF16 Never


{-| The dtype tag of `f32`, IEEE single precision.
-}
type F32
    = F32 Never


{-| The dtype tag of `f64`, IEEE double precision.
-}
type F64
    = F64 Never


{-| The dtype tag of `si8`, signed 8-bit integers.
-}
type I8
    = I8 Never


{-| The dtype tag of `si32`, signed 32-bit integers.
-}
type I32
    = I32 Never


{-| The dtype tag of `si64`, signed 64-bit integers.
-}
type I64
    = I64 Never


{-| The dtype tag of `ui8`, unsigned 8-bit integers.
-}
type U8
    = U8 Never


{-| The dtype tag of `ui64`, unsigned 64-bit integers.
-}
type U64
    = U64 Never


{-| Returns the expression a tensor wraps.
-}
tensor : Tensor k d s -> Expr
tensor (Tensor e) =
    e


{-| Returns the expression a mask wraps.
-}
mask : Mask s -> Expr
mask (Mask e) =
    e



-- SIGNATURES


{-| How a graph's input or output is passed, as the graph's specs record it for whatever runs it.

A `Fed` input is given with every run. `Resident` carries a _resident name_, the name of a buffer
that whatever runs the graph keeps between runs: an input with that role reads the buffer, and an
output with the same resident name replaces it after the run. The lowered ops do not record roles.
`Graph.Role` is the public look-alike.

-}
type Role
    = Fed
    | Resident String


{-| One tensor of a signature: its label, its declared dtype and shape, and its role.

The label is not yet a name: `Graph.build` makes input and output names from the labels. `dtype`
and `shape` are `Nothing` when the signature does not declare them, as in `Signature.anyTensor`.
`Graph.build` refuses such a slot as an input, and refuses an output whose dtype or shape differs
from what its slot declares, unless that output has a build error.

-}
type alias Slot =
    { label : String, dtype : Maybe DT, shape : Maybe (List Int), role : Role }


{-| A signature: a two-way description of a structured value of tensors, put together as an
`elm/json` decoder pipeline is. `f` is the type `build` makes and `r` the type `flatten` reads; once
the description is complete they are the same type (`Signature.Sig a` is `SigBuilder a a`).

`slots` describes the tensors in order. `build` makes a value from tensors taken from the front of a
list and returns the ones it did not use, and `flatten` lists a value's tensors in the same order.
That `flatten` gives back the tensors `build` was given is a contract no type here can state.
`Graph.build` checks it for its own two signatures; nothing checks it elsewhere.

-}
type SigBuilder r f
    = SigBuilder
        { slots : List Slot
        , build : List Expr -> ( f, List Expr )
        , flatten : r -> List Expr
        }



-- GRAPHS


{-| One input or output of a built graph: its name, its dtype name (`"f32"`, `"si64"` ..), its shape
and its role. `Graph.Spec` is the public look-alike, with the public `Graph.Role`.
-}
type alias Spec =
    { name : String, dtype : String, shape : List Int, role : Role }


{-| A graph that `Graph.build` accepted, which is the only place one is made.

It holds its name, the specs of its inputs and outputs in order, and the graph twice over: `ops`,
the expressions lowered to MLIR ops (`Tensor.Internal.Ir`), for writing the graph for MAX; and
`exprs`, the input expressions (`Input` nodes) and the output expressions, each in the order of
the specs. Running the graph in Elm reads the output expressions.

-}
type Graph
    = Graph
        { name : String
        , inputs : List Spec
        , outputs : List Spec
        , ops : List Ir.Op
        , exprs : { inputs : List Expr, outputs : List Expr }
        }



-- PARAMETERS


{-| How the first values of a trainable or frozen parameter field are drawn.

`HeUniform`, `HeNormal`, `XavierUniform` and `XavierNormal` scale their distribution by the field's
fan-in, or its fan-in and fan-out, as `Tensor.Internal.ParamInit.fans` computes them. `Normal`
carries its standard deviation; its mean is 0. `Zeros` and `Ones` fill the field with that value.

-}
type Init
    = HeUniform
    | HeNormal
    | XavierUniform
    | XavierNormal
    | Normal Float
    | Zeros
    | Ones


{-| What training does with a parameter field, and how the package's initialisers fill it.

`Trainable` fields are the ones a training step updates; it does not update `Frozen` or `Data`
fields. A trainable or frozen field carries the `Init` by which the initialisers
(`Param.initial`, `Param.initGraph`, `Train.initial` and the like) draw its first values; they give
a data field zeros. The kind also gives the label a field's resident name is made from: `param`,
`frozen` or `data`.

-}
type FieldKind
    = Trainable Init
    | Frozen Init
    | Data


{-| One tensor field of a parameter description: its dtype, shape and kind, and the group
`Param.named` put it in.

`name` is `Nothing` for a field that no `named` has reached, and `named` sets it only there, so the
innermost `named` around a field wins. Fields with the same `name` are numbered together, and their
resident names begin with that name and a dot (`Tensor.Internal.ParamInit.residentNames` makes the
names).

-}
type alias Field =
    { dtype : DT, shape : List Int, kind : FieldKind, name : Maybe String }


{-| A parameter description, put together as a signature is (`SigBuilder`): `f` is the type `build`
makes and `r` the type `flatten` reads.

`fields` describes the record's tensor fields, in the order `build` takes tensors and `flatten`
lists them; a field that holds no tensor (`Param.config`) has no entry. `checks` are tests of a
whole record, each giving a message when the record does not match the description, such as a config
field holding another value or a list of the wrong length. They run only when `Param.sig` flattens
a record.

-}
type ParamBuilder r f
    = ParamBuilder
        { fields : List Field
        , build : List Expr -> ( f, List Expr )
        , flatten : r -> List Expr
        , checks : List (r -> Maybe String)
        }



-- RANDOMNESS, TRANSFORMS


{-| A random seed: an expression whose dtype and shape the type does not record. `Tensor.Random`
makes seeds as `ui64 [1]` expressions, and the shape rule of a random draw refuses a seed of any
other dtype or shape.
-}
type Seed
    = Seed Expr


{-| A _shared function_ from `a` to `b`: one whose applications are `Call` nodes of a traced body.
Only `Tensor.Internal.Shared.shared` makes one.
-}
type Shared a b
    = Shared { name : String, apply : a -> b }


{-| A description of how a per-example value `a` corresponds to a batched value `b`, whose tensors
may carry a leading batch axis, for vectorising a function over that axis.

`leaves` lists tensors of a batched value, each with a flag that is `True` when it carries the
batch axis; a part described by `Transform.keep` lists none. `perExample` makes a per-example value
from a batched one and tensors standing for its flagged leaves, taken from the front of a list; the
parts that are not batched it takes from the batched value as they are. `flatten` lists the tensors
of a per-example value that are to be batched, and `build` makes a batched value from a per-example
one and those tensors, batched, taken from the front of a list. `perExample` and `build` return the
tensors they did not use.

-}
type Batch a b
    = Batch
        { leaves : b -> List ( Expr, Bool )
        , perExample : b -> List Expr -> ( a, List Expr )
        , flatten : a -> List Expr
        , build : a -> List Expr -> ( b, List Expr )
        }



-- OPTIMIZERS


{-| Where an optimizer's learning rate comes from.

`Fixed` carries a rate that is written into the training graph as a constant. `PerStep` makes the
rate a fed input, given with every run. `Optim.Rate` is the public look-alike.

-}
type Rate
    = Fixed Float
    | PerStep


{-| What an optimizer's update reads besides one parameter's own tensors: the learning rate and the
step. `Train` gives each as an f32 scalar expression. When the optimizer has state slots, `step` is
the training graph's resident `step` input plus one; otherwise it is 1. `Optim.Hyper` is the typed
public look-alike.
-}
type alias Hyper =
    { rate : Expr, step : Expr }


{-| An optimizer, as a training graph applies it to each trainable parameter.

`rate` says where the learning rate comes from. `slots` is the number of state tensors the
optimizer keeps for each trainable parameter. `clip`, when present, bounds the global norm of the
trainable parameters' gradients taken together: a larger norm scales every gradient down by one
factor, to that bound. `update` takes the rate and step, a parameter, its gradient and its state
tensors, and gives the new parameter and the new state tensors. `Train` gives it the parameter,
gradient and state in f32, and casts the new parameter back to the field's dtype. That it gives back
as many state tensors as it was given is not checked here; `Train.step` checks it.

-}
type Optimizer
    = Optimizer
        { rate : Rate
        , slots : Int
        , clip : Maybe Float
        , update : Hyper -> Expr -> Expr -> List Expr -> ( Expr, List Expr )
        }
