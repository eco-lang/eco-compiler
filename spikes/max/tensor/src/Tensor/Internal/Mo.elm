module Tensor.Internal.Mo exposing
    ( Block, emptyBlock, push, emit, constant, tensorType, constText, floatLit, shapeAttr, graphOp
    )

{-| How each primitive is spelled in MAX's IR, as MAX 26.7.0's own graph API spells it
(`spikes/max/mo-inventory.md`): `rmo.<op>`, `rmo.mo.<op>` and plain `mo.<op>`, generic form, with
inherent attributes given as ordinary attributes (MAX moves them into properties).

Every axis is written non-negative: MAX's softmax fails to compile on a negative one.

-}

import Tensor.Internal.MlirBc as Bc
import Tensor.Internal.Prim as P exposing (DT(..), Params, Prim(..))
import Tensor.Internal.Shape exposing (Meta)


{-| Ops emitted so far into one block (reversed), and the value number the next result gets.
-}
type alias Block =
    { ops : List Bc.Op, next : Int }


emptyBlock : Int -> Block
emptyBlock args =
    { ops = [], next = args }


{-| Append one op; returns the value number of its first result.
-}
push : String -> List ( String, Bc.Attr ) -> List Int -> List Bc.Type -> List Bc.Region -> Block -> ( Block, Int )
push name attrs operands results regions b =
    ( { ops = { name = name, attrs = attrs, results = results, operands = operands, regions = regions } :: b.ops
      , next = b.next + List.length results
      }
    , b.next
    )


tensorType : Meta -> Bc.Type
tensorType m =
    Bc.OpaqueType ("!mo.tensor<[" ++ ints m.shape ++ "], " ++ P.dtName m.dtype ++ ">")


ints : List Int -> String
ints l =
    String.join ", " (List.map String.fromInt l)


shapeAttr : List Int -> Bc.Attr
shapeAttr s =
    Bc.OpaqueAttr ("#mosh<ape[" ++ ints s ++ "]> : !mosh.ape")


index : Int -> Bc.Attr
index i =
    Bc.IntAttr i Bc.IndexType


{-| An MLIR float literal: it needs a `.` before any exponent.
-}
floatLit : Float -> String
floatLit f =
    let
        s =
            String.fromFloat f
    in
    if s == "NaN" then
        "0x7FC00000"

    else if s == "Infinity" then
        "0x7F800000"

    else if s == "-Infinity" then
        "0xFF800000"

    else if String.contains "." s then
        s

    else if String.contains "e" s then
        String.replace "e" ".0e" s

    else
        s ++ ".0"


elementText : DT -> Float -> String
elementText dt v =
    if dt == Bool then
        if v /= 0 then
            "true"

        else
            "false"

    else if P.isFloat dt then
        floatLit v

    else
        String.fromInt (round v)


{-| `#M.dense_array<...> : tensor<2x3xf32>` (bool as i1).
-}
constText : DT -> List Int -> List Float -> String
constText dt s values =
    let
        elem =
            if dt == Bool then
                "i1"

            else
                P.dtName dt

        dims =
            String.concat (List.map (\d -> String.fromInt d ++ "x") s)
    in
    "#M.dense_array<" ++ String.join ", " (List.map (elementText dt) values) ++ "> : tensor<" ++ dims ++ elem ++ ">"


constant : DT -> List Int -> List Float -> Block -> ( Block, Int )
constant dt s values =
    push "mo.constant" [ ( "value", Bc.OpaqueAttr (constText dt s values) ) ] [] [ tensorType { shape = s, pending = [], dtype = dt } ] []


simple : String -> List Int -> Meta -> Block -> ( Block, Int )
simple name operands out =
    push name [] operands [ tensorType out ] []


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


{-| The op(s) for one primitive; returns the value number of the result. `operands` are the
operands' value numbers, `ms` their metas, `out` the result's meta.
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
                [ ( "symbol", Bc.StrAttr "mo.acos" )
                , ( "parameters", Bc.DictAttr [] )
                , ( "device", Bc.OpaqueAttr "#M.device_ref<\"cpu\", 0>" )
                , ( "outputParamDecls", Bc.OpaqueAttr "#kgen<param.decls[]>" )
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
                    constant SI64 [ List.length params.a ] (List.map toFloat params.a) b
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
                                        [ toFloat before, toFloat after ]

                                    else
                                        [ 0, 0 ]
                                )
                                (List.range 0 (r - 1))

                        ( b1, padsV ) =
                            constant SI64 [ 2 * r ] pads b

                        ( b2, valueV ) =
                            constant out.dtype [] [ Maybe.withDefault 0 (List.head params.f) ] b1
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

        BandPart ->
            case params.a of
                [ lower, upper ] ->
                    let
                        ( b1, l ) =
                            constant SI64 [] [ toFloat lower ] b

                        ( b2, u ) =
                            constant SI64 [] [ toFloat upper ] b1

                        ( b3, e ) =
                            constant Bool [] [ 0 ] b2
                    in
                    simple "rmo.mo.linalg.band_part" [ o 0, l, u, e ] out b3

                _ ->
                    ( b, -1 )

        Range ->
            case params.a of
                [ start, step, n ] ->
                    let
                        ( b1, s0 ) =
                            constant SI64 [] [ toFloat start ] b

                        ( b2, s1 ) =
                            constant SI64 [] [ toFloat (start + step * n) ] b1

                        ( b3, s2 ) =
                            constant SI64 [] [ toFloat step ] b2
                    in
                    simple "rmo.mo.range" [ s0, s1, s2 ] out b3

                _ ->
                    ( b, -1 )

        Random ->
            case ( params.a, params.f ) of
                ( kind :: _ :: s, [ lo, hi ] ) ->
                    let
                        ( b1, shapeV ) =
                            push "rmo.shape_to_tensor" [ ( "shape", shapeAttr s ) ] [] [ tensorType { shape = [ List.length s ], pending = [], dtype = SI64 } ] [] b

                        paramDt =
                            if kind == 1 then
                                F32

                            else
                                out.dtype

                        ( b2, a ) =
                            constant paramDt [] [ lo ] b1

                        ( b3, c ) =
                            constant paramDt [] [ hi ] b2
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
            -- -(sum (target * logsoftmax logits)) / n
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
                    constant out.dtype [] [ -1 / toFloat n ] b5
            in
            simple "rmo.mul" [ flat, k ] out b6

        LayerNorm ->
            let
                ( b1, eps ) =
                    constant out.dtype [] [ Maybe.withDefault 1.0e-5 (List.head params.f) ] b
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


{-| MAX's reductions keep the axis; dropping it is a reshape.
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


{-| The filter's layout travels in its type, set by a rebind (as MAX's own API does).
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
                    Bc.OpaqueType ("!mo.tensor<[" ++ ints fm.shape ++ "], " ++ P.dtName fm.dtype ++ ", {layout = #mo.layout<RSCF>}>")

                ( b1, fr ) =
                    push "rmo.rebind_tensor_shape" [ ( "message", Bc.StrAttr "" ) ] [ f ] [ fType ] [] b

                common =
                    [ ( "strides", shapeAttr [ sh, sw ] )
                    , ( "dilations", shapeAttr [ dh, dw ] )
                    , ( "paddings", shapeAttr [ pt, pb, pl, pr ] )
                    ]
            in
            if transposed then
                push "rmo.conv_transpose" (common ++ [ ( "output_paddings", shapeAttr [ 0, 0 ] ) ]) [ x, fr ] [ tensorType out ] [] b1

            else
                push "rmo.conv" (common ++ [ ( "num_groups", Bc.IntAttr 1 (Bc.SignedIntegerType 64) ), ( "input_layout", Bc.StrAttr "NHWC" ) ]) [ x, fr ] [ tensorType out ] [] b1

        _ ->
            ( b, -1 )


poolOp : String -> Params -> List Int -> Meta -> Block -> ( Block, Int )
poolOp name params operands out b =
    let
        k =
            Maybe.withDefault 1 (List.head params.a)

        extra =
            if name == "rmo.avg_pool" then
                [ ( "count_boundary", Bc.OpaqueAttr "true" ) ]

            else
                []
    in
    push name
        ([ ( "filter_shape", shapeAttr [ k, k ] )
         , ( "strides", shapeAttr [ k, k ] )
         , ( "dilations", shapeAttr [ 1, 1 ] )
         , ( "paddings", shapeAttr [ 0, 0, 0, 0 ] )
         , ( "ceil_mode", Bc.OpaqueAttr "false" )
         ]
            ++ extra
        )
        operands
        [ tensorType out ]
        []
        b


{-| A whole `mo.graph`, as `Graph.toModule` wrote it: function type, a `kgen` signature, empty
parameter lists, names; `extra` adds attributes (`isSubgraph` for a subgraph).
-}
graphOp : String -> List ( String, Bc.Attr ) -> List ( String, Meta ) -> List ( String, Meta ) -> List Bc.Type -> List Bc.Type -> Bc.Region -> Bc.Op
graphOp name extra inputs outputs inTypes outTypes region =
    let
        fnType =
            Bc.FunctionType inTypes outTypes

        names l =
            Bc.ArrayAttr (List.map (Tuple.first >> Bc.StrAttr) l)
    in
    { name = "mo.graph"
    , attrs =
        [ ( "sym_name", Bc.StrAttr name )
        , ( "functionType", Bc.TypeAttr fnType )
        , ( "signature", Bc.TypeAttr (Bc.OpaqueType ("!kgen.generator<" ++ Bc.typeText fnType ++ ">")) )
        , ( "inputParameters", Bc.OpaqueAttr "#kgen<param.decls[]>" )
        , ( "resultParameters", Bc.OpaqueAttr "#kgen<param.decls[]>" )
        , ( "argument_names", names inputs )
        , ( "result_names", names outputs )
        ]
            ++ extra
    , results = []
    , operands = []
    , regions = [ region ]
    }
