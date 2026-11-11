module Tensor.Internal.Prim exposing
    ( DT(..), dtName, dtTag, dtFromTag, dtSize, isFloat, isInt, isSigned, allDTs
    , Prim(..), Params, noParams, ints, floats, Family(..), family, tag, name
    )

{-| The primitives every tensor expression is built from, with their dtypes and parameters.

A primitive is one MAX operation (or a fixed few). Public functions with no primitive of their own
are compositions of these (see `Tensor.Internal.Ops`).

-}


{-| Element types, as MAX spells them.
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


allDTs : List DT
allDTs =
    [ F16, BF16, F32, F64, SI8, SI32, SI64, UI8, UI64, Bool ]


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


dtFromTag : Int -> DT
dtFromTag t =
    List.filter (\d -> dtTag d == t) allDTs |> List.head |> Maybe.withDefault F32


{-| Bytes per element.
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


isFloat : DT -> Bool
isFloat dt =
    List.member dt [ F16, BF16, F32, F64 ]


isInt : DT -> Bool
isInt dt =
    List.member dt [ SI8, SI32, SI64, UI8, UI64 ]


isSigned : DT -> Bool
isSigned dt =
    isFloat dt || List.member dt [ SI8, SI32, SI64 ]


{-| Integers and floats an operation reads beside its operands: axes, shapes, constants. `a` and `b`
are integer lists whose meaning depends on the primitive (documented at each constructor).
-}
type alias Params =
    { a : List Int, b : List Int, f : List Float }


noParams : Params
noParams =
    { a = [], b = [], f = [] }


ints : List Int -> Params
ints a =
    { noParams | a = a }


floats : List Float -> Params
floats f =
    { noParams | f = f }


type Prim
    = -- element-wise, one operand
      Abs
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
      -- a: [target dtype tag]
    | Cast
      -- the identity for values; no gradient
    | StopGradient
      -- element-wise, two operands
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
      -- mask, then the two values
    | Select
      -- a: [axis, keep (0/1)]
    | ReduceSum
    | ReduceMean
    | ReduceMax
    | ReduceMin
    | ArgMax
    | ArgMin
      -- a: [axis]
    | Softmax
    | LogSoftmax
      -- a: [axis, exclusive, reverse]
    | CumSum
    | MatMul
      -- a: the new shape; b: its pending (broadcast) axes
    | Reshape
      -- a: the permutation
    | Transpose
      -- a: the target shape (materialised)
    | BroadcastTo
      -- a: starts; b: sizes
    | Slice
      -- a: [axis]; operands: the pieces
    | Concat
      -- a: [axis, before, after]; f: [value]
    | Pad
      -- a: [axis]; operands: x, indices
    | Gather
      -- operands: x, updates, indices (n × 1); x with the rows at indices replaced / added to
    | ScatterRows
    | ScatterRowsAdd
      -- a: [lower, upper] (-1: unbounded)
    | BandPart
      -- a: [start, step]; the length is the result's shape; dtype si64
    | Range
      -- a: [0 uniform | 1 normal, dtype tag] ++ shape; f: [low/mean, high/std]; operand: the seed
    | Random
      -- operands: logits (n × c), one-hot targets; the mean cross-entropy, with its own vjp
    | XentLogits
      -- operands: x, gain, bias; f: [epsilon]; normalises over the last axis
    | LayerNorm
      -- a: [strideH, strideW, padTop, padBottom, padLeft, padRight]; operands: x (NHWC), filter (RSCF)
    | Conv
      -- a: as Conv; operands: x, filter (RSCF, with C and F as in the forward conv)
    | ConvTranspose
      -- a: [k]: window = stride = k
    | MaxPool
    | AvgPool


type Family
    = Unary
    | Binary
    | Ternary
    | Other


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


{-| A stable number per primitive, for structural keys.
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


{-| The name a build error quotes.
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
            "put"

        ScatterRowsAdd ->
            "putAdd"

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
