module Tensor.Internal.Prim exposing
    ( DT(..)
    , Family(..)
    , Params
    , Prim(..)
    , allDTs
    , dtFromTag
    , dtName
    , dtSize
    , dtTag
    , family
    , floats
    , ints
    , isFloat
    , isInt
    , isSigned
    , name
    , noParams
    , tag
    )

{-| The code that builds tensor expressions and the code that checks, lowers and evaluates them
(`Tensor.Internal.Shape`, `Tensor.Internal.Mo`, `Tensor.Internal.Eval.Prim`) must agree on what an
expression node that applies a primitive operation can do, and this module is what they agree on:
the operations such a node can apply, the element types a tensor can have, and the numbers that
configure each operation.

A _primitive_ (`Prim`) is one operation a primitive node (`P` in `Tensor.Internal.Expr`) applies to
the expressions it reads, its _operands_. Inputs, constants, branches, loops and shared calls are
nodes of other kinds. An element-wise operation with no primitive of its own, such as taking the
sign of each element, is built from other operations. A _dtype_ (`DT`) is an element type, spelled
as MAX spells it (`dtName`).

What a primitive needs besides its operands, such as an axis, a shape or a fill value, travels in
its _params_ (`Params`): two integer lists and a float list, in one record shape for every
primitive. What each list holds depends on the primitive, and `Prim`'s docstring gives the layout
for each one. The layout is a convention between the code that builds an expression and the code
that reads it, and the compiler checks none of it.

Some of the numbers and names here cannot change without changing what depends on them. `tag` and
`dtTag` are mixed into expressions' keys (an expression's key stands in for its identity; see
`Tensor.Internal.Key`), so each primitive's `tag` must differ from every other primitive's, and
each dtype's `dtTag` from every other dtype's: two that shared a number could give two different
expressions the same key. `family` is read from `tag`'s ranges, so a `Unary` or `Binary`
primitive's tag must fall in its family's range. `dtName` is the dtype written into the MAX tensor
types this package emits and the dtype string its public API reports, so renaming a dtype changes
both. And `name` is the name messages quote, and also the key of the generated
`Tensor.Internal.Support` table of the dtypes a probe of MAX on CPU found each primitive not to
compile for, so renaming a primitive changes which dtypes are refused for it.

Most of the file is lookup tables, one branch per constructor.

-}


{-| An element type, as MAX names it.

`F16`, `BF16`, `F32` and `F64` are the floating-point types; `BF16` is bfloat16. `SI8`, `SI32` and
`SI64` are signed integers and `UI8` and `UI64` unsigned ones, of the widths their names give.
`Bool` is the element type of masks. It is a constructor of `DT`, not Elm's `Bool` type, which is
what this module's predicates return.

The floating-point constructors share their names with the phantom dtype tags of
`Tensor.Internal.Types`, which are separate types.

-}
type DT
    = F16
    | BF16
    | F32
    | F64
    | SI8
    | SI32
    | SI64
    | UI8
    | UI64
    | Bool


{-| Every dtype, in the order of their tags.
-}
allDTs : List DT
allDTs =
    [ F16, BF16, F32, F64, SI8, SI32, SI64, UI8, UI64, Bool ]


{-| Returns a dtype's name, as this package writes it into MAX tensor types and reports it as a
tensor's dtype: `si64` and `ui8`, not `i64` or `u8`.
-}
dtName : DT -> String
dtName dt =
    case dt of
        F16 ->
            "f16"

        BF16 ->
            "bf16"

        F32 ->
            "f32"

        F64 ->
            "f64"

        SI8 ->
            "si8"

        SI32 ->
            "si32"

        SI64 ->
            "si64"

        UI8 ->
            "ui8"

        UI64 ->
            "ui64"

        Bool ->
            "bool"


{-| Returns a fixed number for a dtype, from 1 for `F16` to 10 for `Bool` in `allDTs` order. It is
the form in which a dtype is mixed into the keys of inputs, placeholders and constants, and carried
in a primitive's integer params (`Cast`, `Random`).
-}
dtTag : DT -> Int
dtTag dt =
    case dt of
        F16 ->
            1

        BF16 ->
            2

        F32 ->
            3

        F64 ->
            4

        SI8 ->
            5

        SI32 ->
            6

        SI64 ->
            7

        UI8 ->
            8

        UI64 ->
            9

        Bool ->
            10


{-| Returns the dtype whose `dtTag` is the given number. A number that is no dtype's tag gives
`F32`, not an error.
-}
dtFromTag : Int -> DT
dtFromTag t =
    List.filter (\d -> dtTag d == t) allDTs |> List.head |> Maybe.withDefault F32


{-| Returns the width of one element of a dtype, in bytes. A `Bool` element takes one byte.
-}
dtSize : DT -> Int
dtSize dt =
    case dt of
        F16 ->
            2

        BF16 ->
            2

        F32 ->
            4

        F64 ->
            8

        SI8 ->
            1

        SI32 ->
            4

        SI64 ->
            8

        UI8 ->
            1

        UI64 ->
            8

        Bool ->
            1


{-| Returns whether a dtype is one of the four floating-point types.
-}
isFloat : DT -> Bool
isFloat dt =
    List.member dt [ F16, BF16, F32, F64 ]


{-| Returns whether a dtype is one of the five integer types. `Bool` is not one of them.
-}
isInt : DT -> Bool
isInt dt =
    List.member dt [ SI8, SI32, SI64, UI8, UI64 ]


{-| Returns whether a dtype holds negative values: the floating-point types and `SI8`, `SI32` and
`SI64`, but not the unsigned types or `Bool`.
-}
isSigned : DT -> Bool
isSigned dt =
    isFloat dt || List.member dt [ SI8, SI32, SI64 ]


{-| The numbers a primitive is configured by, beside its operands: an axis, a shape, a fill value.

The record has one shape for every primitive. `a` and `b` are integer lists and `f` is a float
list, and what each holds depends on the primitive, as `Prim`'s docstring lists. Nothing in the
type checks that layout. Every value in all three lists is mixed into the key of the expression
that carries them.

-}
type alias Params =
    { a : List Int, b : List Int, f : List Float }


{-| The params of a primitive that needs none: all three lists empty.
-}
noParams : Params
noParams =
    { a = [], b = [], f = [] }


{-| Builds params whose integer list `a` is the one given, with `b` and `f` empty.
-}
ints : List Int -> Params
ints a =
    { noParams | a = a }


{-| Builds params whose float list `f` is the one given, with `a` and `b` empty.
-}
floats : List Float -> Params
floats f =
    { noParams | f = f }


{-| An operation a primitive node applies to its operands.

The paragraphs below give each primitive's operands where it reads more than one tensor, and its
params where it has any; a primitive whose params are not mentioned takes none. A flag in `a` is 1
for true and 0 for false. Which operands a primitive accepts, and the shape and dtype of its result,
are decided by `Tensor.Internal.Shape`, apart from the dtypes the `Tensor.Internal.Support` table
refuses; what is given here is the layout.

`Abs` through `StopGradient` (the `Unary` family) apply element by element to one operand. Only
`Cast` has params: `a = [tag]`, the `dtTag` of the dtype to cast to. `GeluTanh` is GELU by its tanh
approximation. `StopGradient` leaves the values unchanged and passes no gradient back.

`Add` through `Xor` (the `Binary` family) apply element by element to two operands. `Max2` and
`Min2` are the larger and smaller of the two operands at each element, as against `ReduceMax` and
`ReduceMin` along an axis. There is no less-than primitive: `Gt` and `Ge` with their operands
swapped serve instead.

`Select` (the `Ternary` family) takes a mask and two tensors, in that order, and gives the first
tensor's element where the mask is true and the second's where it is false.

`ReduceSum`, `ReduceMean`, `ReduceMax`, `ReduceMin`, `ArgMax` and `ArgMin` reduce one axis:
`a = [axis, keep]`. With `keep` the reduced axis stays in place with size 1; without, it is removed.

`Softmax` and `LogSoftmax` work along one axis: `a = [axis]`.

`CumSum` is a running sum along one axis: `a = [axis, exclusive, reverse]`. With `exclusive`, each
element is the sum of those before it, itself not included. With `reverse`, the sums run from the
end of the axis.

`MatMul` is the matrix product of its two operands.

`Reshape` gives its operand the shape `a`. `b` lists the axes of the result that are pending: axes
of size 1 whose size is not yet known, as `Tensor.Internal.Shape` describes. It is empty for an
ordinary reshape.

`Transpose` permutes its operand's axes: axis `j` of the result is axis `a[j]` of the operand.

`BroadcastTo` gives its operand the shape `a`, repeating it along its axes of size 1 and along any
axes added in front.

`Slice` takes a block of its operand with step 1: `a` holds the block's start and `b` its size, one
entry per axis.

`Concat` joins its operands, one or more of them, in order along one axis: `a = [axis]`.

`Pad` adds elements before and after its operand along one axis: `a = [axis, before, after]` and
`f = [fill]`. `b` is either empty or `[fill]` again as an exact integer, which non-float dtypes use
in place of `f`.

`Gather` takes a tensor and integer indices and picks the tensor's slices at those indices along one
axis: `a = [axis]`. The result has the indices' whole shape in place of that axis.

`ScatterRows` and `ScatterRowsAdd` take a tensor, updates and indices, in that order, and give the
tensor with its row `indices[i]` replaced by, or increased by, row `i` of the updates. The indices
are an integer `n × 1` tensor, and the updates are `n` rows, each shaped like a row of the tensor.
A row is a slice along the first axis.

`ScatterAxis` and `ScatterAxisAdd` do the same along any axis: `a = [axis]`. Their indices are an
integer vector, and their updates are shaped like the tensor except that the axis has the indices'
length.

`BandPart` keeps a band around the diagonal of its operand's last two axes and sets every other
element to zero: `a = [lower, upper]` keeps the elements at most `lower` rows below the diagonal
and at most `upper` columns above it, and −1 means no bound on that side.

`Range` has no operands: `a = [start, step, n]` gives the `si64` vector of the `n` values `start`,
`start + step`, and so on.

`Random` draws values seeded by its one operand. `a` is the kind of distribution (0 uniform, 1
normal), then the result's `dtTag`, then the result's shape. `f` holds the distribution's two
parameters: low and high, or mean and standard deviation.

`XentLogits` takes logits and targets, both `n × c` with one floating-point dtype, and gives the
cross-entropy averaged over the `n` rows: the mean, over rows, of minus the sum of target times
`logSoftmax` of the logits.

`LayerNorm` takes a tensor, a gain and a bias, and normalises the tensor over its last axis:
`f = [epsilon]`, read as 1e-5 when `f` is empty.

`Conv` is a 2-D convolution of an NHWC input (batch, height, width, channels) with a filter laid out
as (kernel height, kernel width, input channels, output channels):
`a = [strideH, strideW, padTop, padBottom, padLeft, padRight]`, optionally followed by
`[dilationH, dilationW]`, which are 1 when absent.

`ConvTranspose` is the transposed convolution of a `Conv` with the same `a` and filter. Its filter
is laid out as for that `Conv`, so the filter's third axis is the result's channels and its fourth
is the input's.

`MaxPool` and `AvgPool` take the maximum or the mean of each `k × k` window of an NHWC input, with
stride `k`: `a = [k]`.

`TopKValues` and `TopKIndices` select `k` elements along one axis: `a = [axis, k, largest]`. With
`largest` they are the `k` largest in descending order, and without, the `k` smallest in ascending
order. `TopKValues` gives the elements and `TopKIndices` their positions along the axis, as `si64`.

-}
type Prim
    = Abs
    | Neg
    | Exp
    | Log
    | Log1p
    | Sqrt
    | Rsqrt
    | Sin
    | Cos
    | Acos
    | Atanh
    | Erf
    | Floor
    | Round
    | Trunc
    | Relu
    | Sigmoid
    | Tanh
    | Gelu
    | GeluTanh
    | Silu
    | IsInf
    | IsNaN
    | Not
    | Cast
    | StopGradient
    | Add
    | Sub
    | Mul
    | Div
    | Mod
    | Pow
    | Max2
    | Min2
    | Eq
    | Ne
    | Gt
    | Ge
    | And
    | Or
    | Xor
    | Select
    | ReduceSum
    | ReduceMean
    | ReduceMax
    | ReduceMin
    | ArgMax
    | ArgMin
    | Softmax
    | LogSoftmax
    | CumSum
    | MatMul
    | Reshape
    | Transpose
    | BroadcastTo
    | Slice
    | Concat
    | Pad
    | Gather
    | ScatterRows
    | ScatterRowsAdd
    | BandPart
    | Range
    | Random
    | XentLogits
    | LayerNorm
    | Conv
    | ConvTranspose
    | MaxPool
    | AvgPool
    | ScatterAxis
    | ScatterAxisAdd
    | TopKValues
    | TopKIndices


{-| The four groups of primitives, by how many operands they read and whether they work element by
element.

`Unary` is the one-operand element-wise primitives, `Abs` through `StopGradient`, `Cast` included.
`Binary` is the two-operand element-wise primitives, `Add` through `Xor`.
`Ternary` is `Select` alone. `Other` is every other primitive.

-}
type Family
    = Unary
    | Binary
    | Ternary
    | Other


{-| Returns the family a primitive belongs to. It is read from `tag`'s ranges, 1 to 26 for `Unary`
and 27 to 41 for `Binary`, so a new `Unary` or `Binary` primitive needs a tag inside its family's
range.
-}
family : Prim -> Family
family p =
    if tag p <= 26 then
        Unary

    else if tag p <= 41 then
        Binary

    else if p == Select then
        Ternary

    else
        Other


{-| Returns a fixed number for a primitive, which is mixed into the key of every expression that
applies it. The numbers must be distinct: two primitives sharing one, applied to the same operands
with the same params, would get the same key. Changing a `Unary` or `Binary` primitive's number to
one outside its family's range changes its `family`.
-}
tag : Prim -> Int
tag p =
    case p of
        Abs ->
            1

        Neg ->
            2

        Exp ->
            3

        Log ->
            4

        Log1p ->
            5

        Sqrt ->
            6

        Rsqrt ->
            7

        Sin ->
            8

        Cos ->
            9

        Acos ->
            10

        Atanh ->
            11

        Erf ->
            12

        Floor ->
            13

        Round ->
            14

        Trunc ->
            15

        Relu ->
            16

        Sigmoid ->
            17

        Tanh ->
            18

        Gelu ->
            19

        GeluTanh ->
            20

        Silu ->
            21

        IsInf ->
            22

        IsNaN ->
            23

        Not ->
            24

        Cast ->
            25

        StopGradient ->
            26

        Add ->
            27

        Sub ->
            28

        Mul ->
            29

        Div ->
            30

        Mod ->
            31

        Pow ->
            32

        Max2 ->
            33

        Min2 ->
            34

        Eq ->
            35

        Ne ->
            36

        Gt ->
            37

        Ge ->
            38

        And ->
            39

        Or ->
            40

        Xor ->
            41

        Select ->
            42

        ReduceSum ->
            43

        ReduceMean ->
            44

        ReduceMax ->
            45

        ReduceMin ->
            46

        ArgMax ->
            47

        ArgMin ->
            48

        Softmax ->
            49

        LogSoftmax ->
            50

        CumSum ->
            51

        MatMul ->
            52

        Reshape ->
            53

        Transpose ->
            54

        BroadcastTo ->
            55

        Slice ->
            56

        Concat ->
            57

        Pad ->
            58

        Gather ->
            59

        ScatterRows ->
            60

        ScatterRowsAdd ->
            61

        BandPart ->
            62

        Range ->
            63

        Random ->
            64

        XentLogits ->
            65

        LayerNorm ->
            66

        Conv ->
            67

        ConvTranspose ->
            68

        MaxPool ->
            69

        AvgPool ->
            70

        ScatterAxis ->
            71

        ScatterAxisAdd ->
            72

        TopKValues ->
            73

        TopKIndices ->
            74


{-| Returns the name messages use for a primitive: build errors and the evaluator's errors begin
with it, as in `"plus: dtypes differ: f32 and si64"`.

Most names are those of public functions, but not all: `topKValues` and `triu/tril`, for example,
are not. Nor does a name that matches a public function mean that only that function builds the
primitive: `Gather` is named `take`, and `Tensor.rowsAt` builds it too. A name is also the key under
which the generated `Tensor.Internal.Support` table lists the dtypes a probe of MAX on CPU found
that primitive not to compile for, so renaming one changes which dtypes are refused.

-}
name : Prim -> String
name p =
    case p of
        Abs ->
            "abs"

        Neg ->
            "negate"

        Exp ->
            "exp"

        Log ->
            "log"

        Log1p ->
            "log1p"

        Sqrt ->
            "sqrt"

        Rsqrt ->
            "rsqrt"

        Sin ->
            "sin"

        Cos ->
            "cos"

        Acos ->
            "acos"

        Atanh ->
            "atanh"

        Erf ->
            "erf"

        Floor ->
            "floor"

        Round ->
            "round"

        Trunc ->
            "truncate"

        Relu ->
            "relu"

        Sigmoid ->
            "sigmoid"

        Tanh ->
            "tanh"

        Gelu ->
            "gelu"

        GeluTanh ->
            "geluTanh"

        Silu ->
            "silu"

        IsInf ->
            "isInfinite"

        IsNaN ->
            "isNaN"

        Not ->
            "not"

        Cast ->
            "cast"

        StopGradient ->
            "stopGradient"

        Add ->
            "plus"

        Sub ->
            "minus"

        Mul ->
            "times"

        Div ->
            "dividedBy"

        Mod ->
            "modBy"

        Pow ->
            "pow"

        Max2 ->
            "max"

        Min2 ->
            "min"

        Eq ->
            "equals"

        Ne ->
            "notEquals"

        Gt ->
            "greaterThan"

        Ge ->
            "atLeast"

        And ->
            "and"

        Or ->
            "or"

        Xor ->
            "xor"

        Select ->
            "select"

        ReduceSum ->
            "sum"

        ReduceMean ->
            "mean"

        ReduceMax ->
            "maximum"

        ReduceMin ->
            "minimum"

        ArgMax ->
            "argMax"

        ArgMin ->
            "argMin"

        Softmax ->
            "softmax"

        LogSoftmax ->
            "logSoftmax"

        CumSum ->
            "cumsum"

        MatMul ->
            "matmul"

        Reshape ->
            "reshape"

        Transpose ->
            "permute"

        BroadcastTo ->
            "broadcastTo"

        Slice ->
            "slice"

        Concat ->
            "concat"

        Pad ->
            "pad"

        Gather ->
            "take"

        ScatterRows ->
            "scatterRows"

        ScatterRowsAdd ->
            "scatterRowsAdd"

        BandPart ->
            "triu/tril"

        Range ->
            "arange"

        Random ->
            "random"

        XentLogits ->
            "crossEntropy"

        LayerNorm ->
            "layerNorm"

        Conv ->
            "conv2d"

        ConvTranspose ->
            "conv2dTranspose"

        MaxPool ->
            "maxPool2d"

        AvgPool ->
            "avgPool2d"

        ScatterAxis ->
            "scatterAxis"

        ScatterAxisAdd ->
            "scatterAxisAdd"

        TopKValues ->
            "topKValues"

        TopKIndices ->
            "topKIndices"
