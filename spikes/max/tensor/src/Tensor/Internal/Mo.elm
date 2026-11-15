module Tensor.Internal.Mo exposing
    ( Block
    , constText
    , constant
    , emit
    , emptyBlock
    , graphOp
    , push
    , tensorType
    )

{-| A graph is handed to MAX as ops of MAX's graph dialects, `mo` and `rmo`, and this module is the
one place that knows how each primitive is written as those ops: which op or ops it becomes, with
which attributes, and which of its numbers are passed as tensor operands rather than attributes.
The forms written are those this module assumes MAX's graph compiler accepts. Op names take three
shapes, `rmo.<op>`, `rmo.mo.<op>` and plain `mo.<op>`, and every attribute, an op's inherent ones
included, is given as an ordinary attribute, as `Tensor.Internal.Ir` describes.

Ops are collected in a _block_ (`Block`): the ops of one region, in the order they are appended.
Operands and results are _value numbers_, as `Tensor.Internal.Ir` defines them: the block's
arguments first, then each op's results in order. `push` appends one op and returns the number of
its first result, and `emit` appends whatever one primitive needs, given its operands' numbers and
metas (shape, pending axes and dtype), and returns the number of its result. Which expression a
number stands for is not known here.

Most primitives become one op. Where an op reads a number from the primitive's params as a
tensor, such as a permutation, a padding, a bound or an epsilon, that tensor is made by an op
appended just before it, usually a constant. A few primitives become several ops: a reduction
that removes its axis, `XentLogits`, an axis scatter and a convolution, as `emit` describes.

The ops are written in their form for the CPU, with marks that `Tensor.Internal.Device` reads when
it places them for a device. An op that makes a tensor operand of the kind just described carries
the host mark, which keeps it on the CPU when the ops are placed for a GPU; a constant that is
data, such as `XentLogits`'s −1/n, does not. A top-k along an axis other than the last carries the
axis-not-last mark.

Axes are written as given: nothing here turns a negative axis into a non-negative one, so the axes
in params must already be non-negative.

Besides the ops of primitives, the module writes a constant's value as text (`constText`) and the
`mo.graph` op that holds a whole graph (`graphOp`). Most of the file is `emit` and the helpers for
its longer cases.

-}

import Tensor.Internal.Device as Device
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))
import Tensor.Internal.Shape exposing (Meta)
import Tensor.Internal.Values as Values exposing (Values(..))


{-| The ops appended so far to one block, and the value number the next result will get.

`ops` holds the ops newest first, the reverse of their order in the block.

-}
type alias Block =
    { ops : List Ir.Op, next : Int }


{-| Returns a block with no ops whose first `args` values are its arguments, so the first result
appended to it is numbered `args`.
-}
emptyBlock : Int -> Block
emptyBlock args =
    { ops = [], next = args }


{-| Appends an op with the given name, attributes, operands, result types and regions, and returns
the value number of its first result. Its results are numbered on from `next`; for an op with no
results the number returned is the one the next result will get.
-}
push : String -> List ( String, Ir.Attr ) -> List Int -> List Ir.Type -> List Ir.Region -> Block -> ( Block, Int )
push name attrs operands results regions b =
    ( { ops = { name = name, attrs = attrs, results = results, operands = operands, regions = regions } :: b.ops
      , next = b.next + List.length results
      }
    , b.next
    )


{-| Returns MAX's tensor type for a meta's shape and dtype, as in `!mo.tensor<[2, 3], f32>`. A
pending axis is written as the size 1 the meta holds for it, and no device is named.
-}
tensorType : Meta -> Ir.Type
tensorType m =
    Ir.OpaqueType ("!mo.tensor<[" ++ ints m.shape ++ "], " ++ P.dtName m.dtype ++ ">")


{-| Returns integers as decimal text separated by `", "`, as tensor types and shape attributes
list them.
-}
ints : List Int -> String
ints l =
    String.join ", " (List.map String.fromInt l)


{-| Returns MAX's shape attribute holding the integers `s`, as in `#mosh<ape[2, 3]> : !mosh.ape`.
Every list of integers this module gives an op as an attribute takes this form: shapes, and also
slice bounds, strides, dilations, paddings and pool windows.
-}
shapeAttr : List Int -> Ir.Attr
shapeAttr s =
    Ir.OpaqueAttr ("#mosh<ape[" ++ ints s ++ "]> : !mosh.ape")


{-| Returns `i` as an integer attribute of MLIR's `index` type, the form this module gives every
axis attribute except `rmo.top_k`'s, and `CumSum`'s two flags.
-}
index : Int -> Ir.Attr
index i =
    Ir.IntAttr i Ir.IndexType


{-| Returns `f` as an MLIR float literal for a constant of the floating-point dtype `dt`. A literal
needs a `.` before any exponent: `.0` is put before the `e` of text such as `1e-7`, and after text
with neither, such as `1`. −0 is written `-0.0`.

NaN, +∞ and −∞ are written as hexadecimal bit patterns of the dtype's width, which MLIR reads as
those bits: `0x7E00`, `0x7C00` and `0xFC00` for f16, `0x7FC0`, `0x7F80` and `0xFF80` for bf16,
`0x7FF8000000000000`, `0x7FF0000000000000` and `0xFFF0000000000000` for f64, and `0x7FC00000`,
`0x7F800000` and `0xFF800000` for f32 and any other dtype.

-}
floatLit : DT -> Float -> String
floatLit dt f =
    let
        s =
            String.fromFloat f

        ( nan, inf, negInf ) =
            case dt of
                F16 ->
                    ( "0x7E00", "0x7C00", "0xFC00" )

                BF16 ->
                    ( "0x7FC0", "0x7F80", "0xFF80" )

                F64 ->
                    ( "0x7FF8000000000000", "0x7FF0000000000000", "0xFFF0000000000000" )

                _ ->
                    ( "0x7FC00000", "0x7F800000", "0xFF800000" )
    in
    if isNaN f then
        nan

    else if isInfinite f then
        if f > 0 then
            inf

        else
            negInf

    else if f == 0 then
        if 1 / f < 0 then
            "-0.0"

        else
            "0.0"

    else if String.contains "." s then
        s

    else if String.contains "e" s then
        String.replace "e" ".0e" s

    else
        s ++ ".0"


{-| Returns one float element as constant text for dtype `dt`: for `bool`, `true` for any nonzero
value, NaN included, and `false` for 0; for a floating-point dtype, its `floatLit`; and for an
integer dtype, the value rounded and written in signed decimal, `ui64` included.
-}
elementText : DT -> Float -> String
elementText dt v =
    if dt == Bool then
        if v /= 0 then
            "true"

        else
            "false"

    else if P.isFloat dt then
        floatLit dt v

    else
        String.fromInt (round v)


{-| Returns one integer element as constant text for dtype `dt`: for `bool`, `true` for any nonzero
value and `false` for 0; for `ui64`, the unsigned decimal of its 64 bits from `Values.u64Text`;
and otherwise its decimal from `Values.decimalText`.
-}
intText : DT -> Int -> String
intText dt n =
    case dt of
        Bool ->
            if n /= 0 then
                "true"

            else
                "false"

        UI64 ->
            Values.u64Text n

        _ ->
            Values.decimalText n


{-| Returns the text of the value attribute of a constant of dtype `dt` and shape `s` holding
`values`, as in `#M.dense_array<1.0, 0.5> : tensor<2xf32>`.

The element type is the dtype's name, except that `bool` is written `i1`, with elements `true` and
`false`. Integer values are written from their `Int`s, a `ui64` element as the unsigned decimal of
its 64 bits (`Values.u64Text`), and any other as its decimal (`Values.decimalText`).
Float values are written with `floatLit`; given for an integer dtype they are rounded, and given
for `bool` any nonzero value, NaN included, is `true`.

-}
constText : DT -> List Int -> Values -> String
constText dt s values =
    let
        elem =
            if dt == Bool then
                "i1"

            else
                P.dtName dt

        dims =
            String.concat (List.map (\d -> String.fromInt d ++ "x") s)

        texts =
            case values of
                FloatValues l ->
                    List.map (elementText dt) l

                IntValues l ->
                    List.map (intText dt) l
    in
    "#M.dense_array<" ++ String.join ", " texts ++ "> : tensor<" ++ dims ++ elem ++ ">"


{-| Appends a `mo.constant` op whose result, of dtype `dt` and shape `s`, holds `values`, and
returns its value number. Nothing checks that the number of values matches the shape.
-}
constant : DT -> List Int -> Values -> Block -> ( Block, Int )
constant dt s values =
    push "mo.constant" [ ( "value", Ir.OpaqueAttr (constText dt s values) ) ] [] [ tensorType { shape = s, pending = [], dtype = dt } ] []


{-| Appends a constant as `constant` does, from floats. For an integer dtype or `bool` they are
rounded as `Values.forDtype` describes, with no check.
-}
constantF : DT -> List Int -> List Float -> Block -> ( Block, Int )
constantF dt s floats =
    constant dt s (Values.forDtype dt floats)


{-| Appends the op `name` with no attributes and one result, of `out`'s type, and returns its value
number.
-}
simple : String -> List Int -> Meta -> Block -> ( Block, Int )
simple name operands out =
    push name [] operands [ tensorType out ] []


{-| Returns the name that follows `rmo.mo.` in the op of a one-operand element-wise primitive, such
as `negative` for `Neg`. A primitive not listed gets `not`, which is `Not`'s.
-}
unaryName : Prim -> String
unaryName p =
    case p of
        Abs ->
            "abs"

        Neg ->
            "negative"

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

        Atanh ->
            "atanh"

        Erf ->
            "erf"

        Floor ->
            "floor"

        Round ->
            "round"

        Trunc ->
            "trunc"

        Relu ->
            "relu"

        Sigmoid ->
            "sigmoid"

        Tanh ->
            "tanh"

        Gelu ->
            "gelu"

        GeluTanh ->
            "gelu_tanh"

        Silu ->
            "silu"

        IsInf ->
            "is_inf"

        IsNaN ->
            "is_nan"

        _ ->
            "not"


{-| Returns the name that follows `rmo.` in the op of a two-operand element-wise primitive, such as
`greater` for `Gt`. A primitive not listed gets `xor`, which is `Xor`'s.
-}
binaryName : Prim -> String
binaryName p =
    case p of
        Add ->
            "add"

        Sub ->
            "sub"

        Mul ->
            "mul"

        Div ->
            "div"

        Mod ->
            "mod"

        Pow ->
            "pow"

        Max2 ->
            "max"

        Min2 ->
            "min"

        Eq ->
            "equal"

        Ne ->
            "not_equal"

        Gt ->
            "greater"

        Ge ->
            "greater_equal"

        And ->
            "and"

        Or ->
            "or"

        _ ->
            "xor"


{-| Returns the name that follows `rmo.mo.reduce.` in the op of a reduction, such as `add` for
`ReduceSum`. A primitive not listed gets `arg_min`, which is `ArgMin`'s.
-}
reduceName : Prim -> String
reduceName p =
    case p of
        ReduceSum ->
            "add"

        ReduceMean ->
            "mean"

        ReduceMax ->
            "max"

        ReduceMin ->
            "min"

        ArgMax ->
            "arg_max"

        _ ->
            "arg_min"


{-| Appends the ops that compute primitive `p` and returns the value number of its result.
`operands` are the operands' value numbers, `ms` their metas, and `out` the result's meta.

A one-operand element-wise primitive is the op `rmo.mo.<name>` and a two-operand one `rmo.<name>`.
Most other primitives are one op of their own. The exceptions follow.

`StopGradient` appends nothing and returns its operand's number. `Cast` is `mo.cast`, to `out`'s
dtype. `Acos` is a `mo.custom` op that calls the symbol `mo.acos`, with a `device` attribute naming
the CPU.

A reduction that removes its axis is a reduction that keeps it, then a reshape. `XentLogits` is
spelled out: the `logsoftmax` of the logits along axis 1, times the targets, summed along axis 1
and then axis 0, reshaped to rank 0, and multiplied by the constant −1/n, where n is the logits'
first size. An axis scatter first turns its index vector into an index tensor shaped like the
updates, and a convolution first rebinds its filter to a type that carries its layout.
`TopKValues` and `TopKIndices` are the two results of one op: either appends that op, and
`TopKIndices` returns the number of its second result.

Some ops read numbers as tensor operands, each made by an op with the host mark appended just
before: `Transpose`'s permutation; `Pad`'s paddings and fill value; `BandPart`'s two bounds and a
`bool` false; `Range`'s start, end (start + step · n) and step; `Random`'s shape, made by
`rmo.shape_to_tensor`, and its two distribution parameters, in f32 for the normal distribution and
otherwise in the result's dtype; `LayerNorm`'s epsilon; a bottom-k's `k`, axis and a `bool` true;
and the axis of `ScatterAxisAdd`. All but `Random`'s shape are `mo.constant` ops.

No error is reported for malformed params. When `a` is empty, `Softmax`, `LogSoftmax`, `Concat`,
`Gather` and the axis scatters read their axis as 0 and a pool its window as 1, and when `f` is
empty `LayerNorm` reads its epsilon as 1e-5. `CumSum`, `Pad`, `BandPart`, `Range`, `Random`, the
reductions and top-k, given params that do not have the layout they read, append nothing and
return −1, as do a convolution given fewer than six entries in `a` and an axis scatter or a
convolution given other than as many operands and metas as it reads; `TopKIndices` then returns 0
instead. An operand that `StopGradient`, `Transpose`, `Pad`, `BandPart`, `Random`, `XentLogits`, a
reduction or top-k reads and is not given is read as −1. An operand −1 names no value of an
isolated region, but in an open region it is value 0 of the enclosing region
(`Tensor.Internal.Ir`).

-}
emit : Prim -> List Int -> List Meta -> Params -> Meta -> Block -> ( Block, Int )
emit p operands ms params out b =
    let
        o i =
            Maybe.withDefault -1 (List.head (List.drop i operands))

        m i =
            Maybe.withDefault out (List.head (List.drop i ms))

        first =
            Maybe.withDefault 0 (List.head params.a)
    in
    case p of
        StopGradient ->
            ( b, o 0 )

        Cast ->
            simple "mo.cast" operands out b

        Acos ->
            push "mo.custom"
                [ ( "symbol", Ir.StrAttr "mo.acos" )
                , ( "parameters", Ir.DictAttr [] )
                , ( "device", Ir.OpaqueAttr "#M.device_ref<\"cpu\", 0>" )
                , ( "outputParamDecls", Ir.OpaqueAttr "#kgen<param.decls[]>" )
                ]
                operands
                [ tensorType out ]
                []
                b

        Select ->
            simple "rmo.select" operands out b

        MatMul ->
            simple "rmo.matmul" operands out b

        ReduceSum ->
            reduceOp p params out (o 0) (m 0) b

        ReduceMean ->
            reduceOp p params out (o 0) (m 0) b

        ReduceMax ->
            reduceOp p params out (o 0) (m 0) b

        ReduceMin ->
            reduceOp p params out (o 0) (m 0) b

        ArgMax ->
            reduceOp p params out (o 0) (m 0) b

        ArgMin ->
            reduceOp p params out (o 0) (m 0) b

        Softmax ->
            push "rmo.mo.reduce.softmax" [ ( "axis", index first ) ] operands [ tensorType out ] [] b

        LogSoftmax ->
            push "rmo.mo.reduce.logsoftmax" [ ( "axis", index first ) ] operands [ tensorType out ] [] b

        CumSum ->
            case params.a of
                [ axis, exclusive, reverse ] ->
                    push "rmo.mo.cumsum" [ ( "axis", index axis ), ( "exclusive", index exclusive ), ( "reverse", index reverse ) ] operands [ tensorType out ] [] b

                _ ->
                    ( b, -1 )

        Reshape ->
            push "rmo.reshape" [ ( "newShape", shapeAttr out.shape ) ] operands [ tensorType out ] [] b

        Transpose ->
            let
                ( b1, perm ) =
                    host <| constant SI64 [ List.length params.a ] (IntValues params.a) b
            in
            simple "rmo.mo.transpose" [ o 0, perm ] out b1

        BroadcastTo ->
            push "rmo.broadcast_to" [ ( "newShape", shapeAttr out.shape ) ] operands [ tensorType out ] [] b

        Slice ->
            push "rmo.slice"
                [ ( "starts", shapeAttr params.a )
                , ( "stops", shapeAttr (List.map2 (+) params.a params.b) )
                , ( "steps", shapeAttr (List.map (\_ -> 1) params.a) )
                ]
                operands
                [ tensorType out ]
                []
                b

        Concat ->
            push "rmo.concat" [ ( "axis", index first ) ] operands [ tensorType out ] [] b

        Pad ->
            case params.a of
                [ axis, before, after ] ->
                    let
                        r =
                            List.length (m 0).shape

                        pads =
                            List.concatMap
                                (\i ->
                                    if i == axis then
                                        [ before, after ]

                                    else
                                        [ 0, 0 ]
                                )
                                (List.range 0 (r - 1))

                        ( b1, padsV ) =
                            host <| constant SI64 [ 2 * r ] (IntValues pads) b

                        ( b2, valueV ) =
                            host <| constant out.dtype [] (padValue out.dtype params) b1
                    in
                    simple "rmo.mo.pad.constant" [ o 0, padsV, valueV ] out b2

                _ ->
                    ( b, -1 )

        Gather ->
            push "rmo.mo.gather" [ ( "axis", index first ) ] operands [ tensorType out ] [] b

        ScatterRows ->
            simple "rmo.mo.scatter_nd" operands out b

        ScatterRowsAdd ->
            simple "rmo.mo.scatter_nd.add" operands out b

        ScatterAxis ->
            scatterAxisOp False first operands ms out b

        ScatterAxisAdd ->
            scatterAxisOp True first operands ms out b

        TopKValues ->
            topKOp params (o 0) (m 0) out b

        TopKIndices ->
            topKOp params (o 0) (m 0) out b |> Tuple.mapSecond ((+) 1)

        BandPart ->
            case params.a of
                [ lower, upper ] ->
                    let
                        ( b1, l ) =
                            host <| constant SI64 [] (IntValues [ lower ]) b

                        ( b2, u ) =
                            host <| constant SI64 [] (IntValues [ upper ]) b1

                        ( b3, e ) =
                            host <| constant Bool [] (IntValues [ 0 ]) b2
                    in
                    simple "rmo.mo.linalg.band_part" [ o 0, l, u, e ] out b3

                _ ->
                    ( b, -1 )

        Range ->
            case params.a of
                [ start, step, n ] ->
                    let
                        ( b1, s0 ) =
                            host <| constant SI64 [] (IntValues [ start ]) b

                        ( b2, s1 ) =
                            host <| constant SI64 [] (IntValues [ start + step * n ]) b1

                        ( b3, s2 ) =
                            host <| constant SI64 [] (IntValues [ step ]) b2
                    in
                    simple "rmo.mo.range" [ s0, s1, s2 ] out b3

                _ ->
                    ( b, -1 )

        Random ->
            case ( params.a, params.f ) of
                ( kind :: _ :: s, [ lo, hi ] ) ->
                    let
                        ( b1, shapeV ) =
                            host <| push "rmo.shape_to_tensor" [ ( "shape", shapeAttr s ) ] [] [ tensorType { shape = [ List.length s ], pending = [], dtype = SI64 } ] [] b

                        paramDt =
                            if kind == 1 then
                                F32

                            else
                                out.dtype

                        ( b2, a ) =
                            host <| constantF paramDt [] [ lo ] b1

                        ( b3, c ) =
                            host <| constantF paramDt [] [ hi ] b2
                    in
                    simple
                        (if kind == 1 then
                            "rmo.mo.random.normal"

                         else
                            "rmo.mo.random.uniform"
                        )
                        [ shapeV, a, c, o 0 ]
                        out
                        b3

                _ ->
                    ( b, -1 )

        XentLogits ->
            let
                lm =
                    m 0

                n =
                    Maybe.withDefault 1 (List.head lm.shape)

                rowShape =
                    { lm | shape = List.take 1 lm.shape ++ [ 1 ] }

                ( b1, lsm ) =
                    push "rmo.mo.reduce.logsoftmax" [ ( "axis", index 1 ) ] [ o 0 ] [ tensorType lm ] [] b

                ( b2, prod ) =
                    simple "rmo.mul" [ o 1, lsm ] lm b1

                ( b3, rowsV ) =
                    push "rmo.mo.reduce.add" [ ( "axis", index 1 ) ] [ prod ] [ tensorType rowShape ] [] b2

                ( b4, total ) =
                    push "rmo.mo.reduce.add" [ ( "axis", index 0 ) ] [ rowsV ] [ tensorType { lm | shape = [ 1, 1 ] } ] [] b3

                ( b5, flat ) =
                    push "rmo.reshape" [ ( "newShape", shapeAttr [] ) ] [ total ] [ tensorType out ] [] b4

                ( b6, k ) =
                    constantF out.dtype [] [ -1 / toFloat n ] b5
            in
            simple "rmo.mul" [ flat, k ] out b6

        LayerNorm ->
            let
                ( b1, eps ) =
                    host <| constantF out.dtype [] [ Maybe.withDefault 1.0e-5 (List.head params.f) ] b
            in
            simple "mo.reduce.layer_norm" (operands ++ [ eps ]) out b1

        Conv ->
            convOp False params operands ms out b

        ConvTranspose ->
            convOp True params operands ms out b

        MaxPool ->
            poolOp "rmo.max_pool" params operands out b

        AvgPool ->
            poolOp "rmo.avg_pool" params operands out b

        _ ->
            case P.family p of
                P.Unary ->
                    simple ("rmo.mo." ++ unaryName p) operands out b

                P.Binary ->
                    simple ("rmo." ++ binaryName p) operands out b

                _ ->
                    ( b, -1 )


{-| Appends the scatter of updates `u` into `x` along `axis`, replacing elements or, with `add`,
adding to them, and returns its value number. `operands` are `x`, `u` and the index vector `i`, and
`ms` their metas.

The index operand written is a tensor shaped like the updates: the index vector, cast to `si64`
when it is not already, reshaped to its first size along `axis` and 1 on every other axis, and
broadcast to the updates' shape. The axis is an attribute of `rmo.mo.scatter` and an operand of
`rmo.mo.scatter.add`, a rank-0 `si64` constant with the host mark. Given other than three
operands and three metas, it appends nothing and returns −1.

-}
scatterAxisOp : Bool -> Int -> List Int -> List Meta -> Meta -> Block -> ( Block, Int )
scatterAxisOp add axis operands ms out b =
    case ( operands, ms ) of
        ( [ x, u, i ], [ _, um, im ] ) ->
            let
                c =
                    Maybe.withDefault 1 (List.head im.shape)

                alongAxis =
                    List.indexedMap
                        (\k _ ->
                            if k == axis then
                                c

                            else
                                1
                        )
                        um.shape

                ( b1, i64 ) =
                    if im.dtype == SI64 then
                        ( b, i )

                    else
                        simple "mo.cast" [ i ] { im | dtype = SI64 } b

                ( b2, reshaped ) =
                    push "rmo.reshape" [ ( "newShape", shapeAttr alongAxis ) ] [ i64 ] [ tensorType { shape = alongAxis, pending = [], dtype = SI64 } ] [] b1

                ( b3, spread ) =
                    push "rmo.broadcast_to" [ ( "newShape", shapeAttr um.shape ) ] [ reshaped ] [ tensorType { um | dtype = SI64 } ] [] b2
            in
            if add then
                let
                    ( b4, ax ) =
                        host <| constant SI64 [] (IntValues [ axis ]) b3
                in
                simple "rmo.mo.scatter.add" [ x, u, spread, ax ] out b4

            else
                push "rmo.mo.scatter" [ ( "axis", index axis ) ] [ x, u, spread ] [ tensorType out ] [] b3

        _ ->
            ( b, -1 )


{-| Gives the op appended last the host mark, which keeps its results on the CPU when the ops are
placed for a GPU (`Tensor.Internal.Device`), and passes the value number through.
-}
host : ( Block, Int ) -> ( Block, Int )
host =
    mark Device.hostMark


{-| Adds the unit attribute `name` to the op appended last and passes the value number through.
A block with no ops is returned unchanged.
-}
mark : String -> ( Block, Int ) -> ( Block, Int )
mark name ( b, v ) =
    case b.ops of
        op :: rest ->
            ( { b | ops = { op | attrs = op.attrs ++ [ ( name, Ir.UnitAttr ) ] } :: rest }, v )

        [] ->
            ( b, v )


{-| Appends the ops of a top-k of `x`, whose meta is `xm`. One op gives both results: the values, in
`x`'s dtype, and their `si64` indices, both of `out`'s shape. Returns the values' number; the
indices' is the next.

With `a = [axis, k, largest]` and `largest` 1, the op is `rmo.top_k`, with `axis` and `k` as `si64`
attributes. Otherwise it is `rmo.mo.bottom_k`, which reads `k`, `axis` and a `bool` true as rank-0
constants with the host mark. Either op gets the axis-not-last mark when `axis` is not the last
axis of `out`. Given params of another length, it appends nothing and returns −1.

-}
topKOp : Params -> Int -> Meta -> Meta -> Block -> ( Block, Int )
topKOp params x xm out b =
    case params.a of
        [ axis, k, largest ] ->
            let
                results =
                    [ tensorType { out | dtype = xm.dtype }, tensorType { out | dtype = SI64 } ]
            in
            (if axis == List.length out.shape - 1 then
                identity

             else
                mark Device.axisNotLastMark
            )
            <|
                if largest == 1 then
                    push "rmo.top_k" [ ( "axis", Ir.IntAttr axis (Ir.SignedIntegerType 64) ), ( "k", Ir.IntAttr k (Ir.SignedIntegerType 64) ) ] [ x ] results [] b

                else
                    let
                        ( b1, kc ) =
                            host <| constant SI64 [] (IntValues [ k ]) b

                        ( b2, ac ) =
                            host <| constant SI64 [] (IntValues [ axis ]) b1

                        ( b3, sc ) =
                            host <| constant Bool [] (IntValues [ 1 ]) b2
                    in
                    push "rmo.mo.bottom_k" [] [ x, kc, ac, sc ] results [] b3

        _ ->
            ( b, -1 )


{-| Appends the reduction `p` of `x`, whose meta is `xm`, along one axis, and returns the value
number of its result, given `a = [axis, keep]`.

The reduction op written keeps the axis, with size 1. When `keep` is not 1, a reshape to `out`'s
shape follows and removes it. Given params of another length, it appends nothing and returns −1.

-}
reduceOp : Prim -> Params -> Meta -> Int -> Meta -> Block -> ( Block, Int )
reduceOp p params out x xm b =
    case params.a of
        [ axis, keep ] ->
            let
                keptMeta =
                    { out | shape = List.take axis xm.shape ++ (1 :: List.drop (axis + 1) xm.shape) }

                ( b1, r ) =
                    push ("rmo.mo.reduce." ++ reduceName p) [ ( "axis", index axis ) ] [ x ] [ tensorType keptMeta ] [] b
            in
            if keep == 1 then
                ( b1, r )

            else
                push "rmo.reshape" [ ( "newShape", shapeAttr out.shape ) ] [ r ] [ tensorType out ] [] b1

        _ ->
            ( b, -1 )


{-| Appends a convolution, or with `transposed` a transposed convolution, of an input by a filter,
the two `operands`, and returns the value number of its result.

The filter's layout travels in its type: the filter is first rebound (`rmo.rebind_tensor_shape`)
to its own shape and dtype with `layout = #mo.layout<RSCF>` added. Strides, paddings and dilations
are attributes, the dilations 1 unless exactly two entries follow the six of `a`. A convolution
also has one group and the input layout `NHWC`, and a transposed one an output padding of 0.
Given fewer than six entries in `a`, or other than two operands and two metas, it appends nothing
and returns −1.

-}
convOp : Bool -> Params -> List Int -> List Meta -> Meta -> Block -> ( Block, Int )
convOp transposed params operands ms out b =
    let
        ( dh, dw ) =
            case List.drop 6 params.a of
                [ a, c ] ->
                    ( a, c )

                _ ->
                    ( 1, 1 )
    in
    case ( List.take 6 params.a, operands, ms ) of
        ( [ sh, sw, pt, pb, pl, pr ], [ x, f ], [ _, fm ] ) ->
            let
                fType =
                    Ir.OpaqueType ("!mo.tensor<[" ++ ints fm.shape ++ "], " ++ P.dtName fm.dtype ++ ", {layout = #mo.layout<RSCF>}>")

                ( b1, fr ) =
                    push "rmo.rebind_tensor_shape" [ ( "message", Ir.StrAttr "" ) ] [ f ] [ fType ] [] b

                common =
                    [ ( "strides", shapeAttr [ sh, sw ] )
                    , ( "dilations", shapeAttr [ dh, dw ] )
                    , ( "paddings", shapeAttr [ pt, pb, pl, pr ] )
                    ]
            in
            if transposed then
                push "rmo.conv_transpose" (common ++ [ ( "output_paddings", shapeAttr [ 0, 0 ] ) ]) [ x, fr ] [ tensorType out ] [] b1

            else
                push "rmo.conv" (common ++ [ ( "num_groups", Ir.IntAttr 1 (Ir.SignedIntegerType 64) ), ( "input_layout", Ir.StrAttr "NHWC" ) ]) [ x, fr ] [ tensorType out ] [] b1

        _ ->
            ( b, -1 )


{-| Appends the pool op `name` over `k × k` windows with stride `k`, given `a = [k]` (1 when `a`
is empty), with no padding, a dilation of 1 and `ceil_mode` false, and returns its value number.
For `rmo.avg_pool` it also sets `count_boundary` to true.
-}
poolOp : String -> Params -> List Int -> Meta -> Block -> ( Block, Int )
poolOp name params operands out b =
    let
        k =
            Maybe.withDefault 1 (List.head params.a)

        extra =
            if name == "rmo.avg_pool" then
                [ ( "count_boundary", Ir.OpaqueAttr "true" ) ]

            else
                []
    in
    push name
        ([ ( "filter_shape", shapeAttr [ k, k ] )
         , ( "strides", shapeAttr [ k, k ] )
         , ( "dilations", shapeAttr [ 1, 1 ] )
         , ( "paddings", shapeAttr [ 0, 0, 0, 0 ] )
         , ( "ceil_mode", Ir.OpaqueAttr "false" )
         ]
            ++ extra
        )
        operands
        [ tensorType out ]
        []
        b


{-| Builds the `mo.graph` op named `name` that holds `region`. Its attributes are its function
type, from `inTypes` to `outTypes`; the same type as a `kgen` generator signature; empty `kgen`
parameter lists; the argument and result names, the first components of `inputs` and `outputs`,
whose metas are not read; and then `extra`, such as `isSubgraph` for a subgraph.
-}
graphOp : String -> List ( String, Ir.Attr ) -> List ( String, Meta ) -> List ( String, Meta ) -> List Ir.Type -> List Ir.Type -> Ir.Region -> Ir.Op
graphOp name extra inputs outputs inTypes outTypes region =
    let
        fnType =
            Ir.FunctionType inTypes outTypes

        names l =
            Ir.ArrayAttr (List.map (Tuple.first >> Ir.StrAttr) l)
    in
    { name = "mo.graph"
    , attrs =
        [ ( "sym_name", Ir.StrAttr name )
        , ( "functionType", Ir.TypeAttr fnType )
        , ( "signature", Ir.TypeAttr (Ir.OpaqueType ("!kgen.generator<" ++ Ir.typeText fnType ++ ">")) )
        , ( "inputParameters", Ir.OpaqueAttr "#kgen<param.decls[]>" )
        , ( "resultParameters", Ir.OpaqueAttr "#kgen<param.decls[]>" )
        , ( "argument_names", names inputs )
        , ( "result_names", names outputs )
        ]
            ++ extra
    , results = []
    , operands = []
    , regions = [ region ]
    }


{-| Returns `Pad`'s fill value for dtype `dt`: the first entry of `f` for a floating-point dtype,
and for any other dtype the first entry of `b` when `b` is not empty, else the first entry of `f`
rounded, with no range check. A missing `f` entry is 0.
-}
padValue : DT -> Params -> Values
padValue dt params =
    let
        f =
            Maybe.withDefault 0 (List.head params.f)
    in
    if P.isFloat dt then
        FloatValues [ f ]

    else
        case params.b of
            v :: _ ->
                IntValues [ v ]

            [] ->
                IntValues [ round f ]
