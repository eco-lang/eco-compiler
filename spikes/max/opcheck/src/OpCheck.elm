port module OpCheck exposing (main)

{-| The op-check harness, Elm side: one graph per family of operations, each output flattened to
f32, with a manifest saying what NumPy must compute for it (`ref.py`).

A gradient check differentiates `sumAll (y * stopGradient (cos y))` for y = f x: its gradient is
(cos y0) · J, which NumPy reproduces by central differences on its own f with w = cos y0 fixed.

-}

import Finetune.Qlora as Qlora
import Bytes
import Bytes.Decode as Decode
import Graph exposing (Graph)
import Json.Encode as E
import Nn
import Nn.Conv2d as Conv2d exposing (Conv2d)
import Nn.Attention as Attention
import Nn.Embedding as Embedding
import Nn.FeedForward as FeedForward
import Nn.GroupNorm as GroupNorm
import Nn.KvCache as KvCache
import Nn.LayerNorm as LayerNorm
import Nn.RmsNorm as RmsNorm
import Nn.Rotary as Rotary
import Nn.Sampling as Sampling
import Nn.Linear as Linear
import Platform
import Param
import Signature as Sig exposing (Sig)
import Tensor as T exposing (Dim, F32, Floating, I64, Integral, Mask, R0, R1, R2, R3, R4, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Random as Random
import Transform


port emit : E.Value -> Cmd msg


type A
    = A


type B
    = B


type C
    = C


type D
    = D


type K
    = K


type Flat
    = Flat


a : Dim A
a =
    T.dim A 3


b : Dim B
b =
    T.dim B 4


c : Dim C
c =
    T.dim C 5


d : Dim D
d =
    T.dim D 2


k2 : Dim K
k2 =
    T.dim K 2


type alias F s =
    Tensor Floating F32 s


type alias Out =
    F (R1 Flat)


flat : Tensor k d s -> Out
flat x =
    x |> T.toFloat |> T.flatten (T.dim Flat (List.product (T.shapeOf x)))


mflat : Mask s -> Out
mflat m =
    flat (T.indicator T.float32 m)


type alias Check i =
    { name : String, ref : String, args : List String, wrt : String, params : List Float, fn : i -> Out }


value : String -> List String -> List Float -> (i -> Tensor k d s) -> Check i
value ref args params f =
    { name = ref, ref = ref, args = args, wrt = "", params = params, fn = f >> flat }


named : String -> String -> List String -> List Float -> (i -> Tensor k d s) -> Check i
named name ref args params f =
    { name = name, ref = ref, args = args, wrt = "", params = params, fn = f >> flat }


mvalue : String -> List String -> List Float -> (i -> Mask s) -> Check i
mvalue ref args params f =
    { name = ref, ref = ref, args = args, wrt = "", params = params, fn = f >> mflat }


{-| d/dx of sumAll (f x * stopGradient (cos (f x))).
-}
gradWrt : (F s -> F t) -> F s -> F s
gradWrt f x =
    Transform.grad
        (\v ->
            let
                y =
                    f v
            in
            y |> T.times (T.stopGradient (T.cos y)) |> T.sumAll
        )
        x


gradCheck : String -> List String -> String -> List Float -> (i -> F s) -> Check i
gradCheck ref args wrt params f =
    { name = ref ++ "'" ++ wrt, ref = ref, args = args, wrt = wrt, params = params, fn = f >> flat }


namedGrad : String -> String -> List String -> String -> List Float -> (i -> F s) -> Check i
namedGrad name ref args wrt params f =
    { name = name ++ "'" ++ wrt, ref = ref, args = args, wrt = wrt, params = params, fn = f >> flat }


{-| A value and its gradient for a function of one input.
-}
both : String -> List Float -> (F s -> F t) -> (i -> F s) -> List (Check i)
both ref params f x =
    [ value ref [ "x" ] params (x >> f), gradCheck ref [ "x" ] "x" params (\i -> gradWrt f (x i)) ]


family : String -> List ( String, String ) -> Sig i -> List (Check i) -> E.Value
family graphName domains ins checks =
    let
        outs =
            Sig.list (List.length checks) (Sig.label "out" Sig.anyTensor)

        built =
            Graph.build graphName ins outs (\i -> List.map (\ch -> ch.fn i) checks)

        check ch =
            E.object
                [ ( "name", E.string ch.name )
                , ( "ref", E.string ch.ref )
                , ( "args", E.list E.string ch.args )
                , ( "wrt", E.string ch.wrt )
                , ( "params", E.list E.float ch.params )
                ]
    in
    case built of
        Ok g ->
            E.object
                [ ( "graph", E.string graphName )
                , ( "mlir", E.string (Graph.toGenericText g) )
                , ( "bytecode", E.list E.int (byteList (Graph.toBytecode g)) )
                , ( "inputs"
                  , E.list
                        (\s ->
                            E.object
                                [ ( "name", E.string s.name )
                                , ( "dtype", E.string s.dtype )
                                , ( "shape", E.list E.int s.shape )
                                , ( "domain", E.string (List.filter (\( n, _ ) -> n == s.name) domains |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault "sym2") )
                                ]
                        )
                        (Graph.inputs g)
                  )
                , ( "outputs", E.list (.name >> E.string) (Graph.outputs g) )
                , ( "checks", E.list check checks )
                , ( "gpu", onGpu g )
                ]

        Err errs ->
            E.object [ ( "graph", E.string graphName ), ( "errors", E.list E.string errs ) ]


{-| The family written for GPU 0 (round 2, A3): checked against `mlir-opt` and MAX's own placement
(`make check-gpu-ir`), not run.
-}
onGpu : Graph -> E.Value
onGpu g =
    case ( Graph.toGenericTextOn (Graph.Gpu 0) g, Graph.toBytecodeOn (Graph.Gpu 0) g ) of
        ( Ok text, Ok bytes ) ->
            E.object [ ( "mlir", E.string text ), ( "bytecode", E.list E.int (byteList bytes) ) ]

        ( Err e, _ ) ->
            E.object [ ( "errors", E.list E.string e ) ]

        ( _, Err e ) ->
            E.object [ ( "errors", E.list E.string e ) ]


byteList : Bytes.Bytes -> List Int
byteList bytes =
    let
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.map (\x -> Decode.Loop ( n - 1, x :: acc )) Decode.unsignedInt8
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes |> Maybe.withDefault []


x34 : String -> Sig (F (R2 A B))
x34 l =
    Sig.label l (Sig.f32 (T.r2 a b))



-- FAMILIES


unary : E.Value
unary =
    let
        x =
            identity
    in
    family "unary" [ ( "x", "sym2" ) ] (x34 "x") <|
        List.concat
            [ both "abs" [] T.abs x
            , both "negate" [] T.negate x
            , [ value "sign" [ "x" ] [] T.sign ]
            , both "exp" [] T.exp x
            , both "sin" [] T.sin x
            , both "cos" [] T.cos x
            , both "erf" [] T.erf x
            , [ value "floor" [ "x" ] [] T.floor, value "round" [ "x" ] [] T.round, value "truncate" [ "x" ] [] T.truncate ]
            , both "relu" [] T.relu x
            , both "sigmoid" [] T.sigmoid x
            , both "tanh" [] T.tanh x
            , both "gelu" [] T.gelu x
            , both "geluTanh" [] T.geluTanh x
            , both "silu" [] T.silu x
            , both "scale" [ 2.5 ] (T.scale 2.5) x
            , both "shift" [ 1.5 ] (T.shift 1.5) x
            , [ mvalue "isInfinite" [ "x" ] [] T.isInfinite, mvalue "isNaN" [ "x" ] [] T.isNaN ]
            , both "square" [] (\v -> v |> T.times v) x
            ]


positive : E.Value
positive =
    family "positive" [ ( "x", "pos" ) ] (x34 "x") <|
        List.concat
            [ both "log" [] T.log identity
            , both "log1p" [] T.log1p identity
            , both "sqrt" [] T.sqrt identity
            , both "rsqrt" [] T.rsqrt identity
            ]


unit : E.Value
unit =
    family "unit" [ ( "x", "unit" ) ] (x34 "x") <|
        List.concat
            [ both "acos" [] T.acos identity
            , both "atanh" [] T.atanh identity
            ]


type alias Bin =
    { x : F (R2 A B), y : F (R2 A B), p : F (R2 A B) }


binary : E.Value
binary =
    let
        ins =
            Sig.record Bin
                |> Sig.field .x (x34 "x")
                |> Sig.field .y (x34 "y")
                |> Sig.field .p (x34 "p")

        two ref f =
            [ value ref [ "x", "y" ] [] (\i -> f i.y i.x)
            , gradCheck ref [ "x", "y" ] "x" [] (\i -> gradWrt (\v -> f i.y v) i.x)
            , gradCheck ref [ "x", "y" ] "y" [] (\i -> gradWrt (\v -> f v i.x) i.y)
            ]
    in
    family "binary" [ ( "x", "sym2" ), ( "y", "sym2" ), ( "p", "pos" ) ] ins <|
        List.concat
            [ two "plus" T.plus
            , two "minus" T.minus
            , two "times" T.times
            , two "max" T.max
            , two "min" T.min
            , [ value "dividedBy" [ "x", "p" ] [] (\i -> i.x |> T.dividedBy i.p)
              , gradCheck "dividedBy" [ "x", "p" ] "x" [] (\i -> gradWrt (\v -> v |> T.dividedBy i.p) i.x)
              , gradCheck "dividedBy" [ "x", "p" ] "p" [] (\i -> gradWrt (\v -> i.x |> T.dividedBy v) i.p)
              , value "pow" [ "p", "y" ] [] (\i -> i.p |> T.pow i.y)
              , gradCheck "pow" [ "p", "y" ] "p" [] (\i -> gradWrt (\v -> v |> T.pow i.y) i.p)
              , gradCheck "pow" [ "p", "y" ] "y" [] (\i -> gradWrt (\v -> i.p |> T.pow v) i.y)
              ]
            , [ mvalue "greaterThan" [ "x", "y" ] [] (\i -> i.x |> T.greaterThan i.y)
              , mvalue "atLeast" [ "x", "y" ] [] (\i -> i.x |> T.atLeast i.y)
              , mvalue "lessThan" [ "x", "y" ] [] (\i -> i.x |> T.lessThan i.y)
              , mvalue "atMost" [ "x", "y" ] [] (\i -> i.x |> T.atMost i.y)
              , mvalue "equals" [ "x", "y" ] [] (\i -> T.round i.x |> T.equals (T.round i.y))
              , mvalue "notEquals" [ "x", "y" ] [] (\i -> T.round i.x |> T.notEquals (T.round i.y))
              , mvalue "and" [ "x", "y" ] [] (\i -> pos i.x |> T.and (pos i.y))
              , mvalue "or" [ "x", "y" ] [] (\i -> pos i.x |> T.or (pos i.y))
              , mvalue "xor" [ "x", "y" ] [] (\i -> pos i.x |> T.xor (pos i.y))
              , mvalue "not" [ "x" ] [] (\i -> T.not (pos i.x))
              , value "select" [ "x", "y" ] [] (\i -> T.select (i.x |> T.greaterThan i.y) i.x (T.scale 3 i.y))
              , gradCheck "select" [ "x", "y" ] "x" [] (\i -> gradWrt (\v -> T.select (i.x |> T.greaterThan i.y) v (T.scale 3 i.y)) i.x)
              , gradCheck "select" [ "x", "y" ] "y" [] (\i -> gradWrt (\v -> T.select (i.x |> T.greaterThan i.y) i.x (T.scale 3 v)) i.y)
              ]
            ]


pos : F s -> Mask s
pos v =
    v |> T.greaterThan (T.zerosLike v)


type alias Ints =
    { i : Tensor Integral I64 (R2 A B), m : Tensor Integral I64 (R2 A B), x : F (R2 A B) }


integers : E.Value
integers =
    let
        ins =
            Sig.record Ints
                |> Sig.field .i (Sig.label "i" (Sig.i64 (T.r2 a b)))
                |> Sig.field .m (Sig.label "m" (Sig.i64 (T.r2 a b)))
                |> Sig.field .x (x34 "x")
    in
    family "integers" [ ( "i", "int" ), ( "m", "posint" ), ( "x", "sym2" ) ] ins <|
        [ value "iplus" [ "i", "m" ] [] (\v -> v.i |> T.plus v.m)
        , value "itimes" [ "i", "m" ] [] (\v -> v.i |> T.times v.m)
        , value "inegate" [ "i" ] [] (\v -> T.negate v.i)
        , value "iabs" [ "i" ] [] (\v -> T.abs v.i)
        , value "irelu" [ "i" ] [] (\v -> T.relu v.i)
        , value "imax" [ "i", "m" ] [] (\v -> v.i |> T.max v.m)
        , value "modBy" [ "i", "m" ] [] (\v -> v.i |> T.modBy v.m)
        , value "toInt" [ "x" ] [] (\v -> T.toInt (T.scale 3 v.x))
        , value "isum1" [ "i" ] [] (\v -> T.sum Axis.axis1of2 v.i)
        , value "argMax0" [ "x" ] [ 0 ] (\v -> T.argMax Axis.axis0of2 v.x)
        , value "argMax1" [ "x" ] [ 1 ] (\v -> T.argMax Axis.axis1of2 v.x)
        , value "argMin0" [ "x" ] [ 0 ] (\v -> T.argMin Axis.axis0of2 v.x)
        , value "argMin1" [ "x" ] [ 1 ] (\v -> T.argMin Axis.axis1of2 v.x)
        , value "castU8" [ "i" ] [] (\v -> T.cast T.uint8 (T.abs v.i))
        , value "castI32" [ "i" ] [] (\v -> T.cast T.int32 v.i)
        , value "iota" [] [ 5 ] (\_ -> T.iota c)
        , value "arange" [] [ 2, 3, 5 ] (\_ -> T.arange { start = 2, step = 3 } c)
        ]


x345 : Sig (F (R3 A B C))
x345 =
    Sig.label "x" (Sig.f32 (T.r3 a b c))


reductions : E.Value
reductions =
    let
        r ref axis f =
            both ref [ axis ] f identity
    in
    family "reductions" [ ( "x", "sym2" ) ] x345 <|
        List.concat
            [ r "sum" 0 (T.sum Axis.axis0of3)
            , r "sum" 1 (T.sum Axis.axis1of3)
            , r "sum" 2 (T.sum Axis.axis2of3)
            , r "mean" 0 (T.mean Axis.axis0of3)
            , r "mean" 2 (T.mean Axis.axis2of3)
            , r "maximum" 1 (T.maximum Axis.axis1of3)
            , r "minimum" 2 (T.minimum Axis.axis2of3)
            , r "logSumExp" 1 (T.logSumExp Axis.axis1of3)
            , r "cumsum" 0 (T.cumsum Axis.axis0of3)
            , r "cumsum" 2 (T.cumsum Axis.axis2of3)
            , both "cumsumExclusive" [ 1 ] (T.cumsumWith { exclusive = True, reverse = False } Axis.axis1of3) identity
            , both "cumsumReverse" [ 1 ] (T.cumsumWith { exclusive = False, reverse = True } Axis.axis1of3) identity
            , both "cumsumExclusiveReverse" [ 2 ] (T.cumsumWith { exclusive = True, reverse = True } Axis.axis2of3) identity
            , r "softmax" 0 (T.softmax Axis.axis0of3)
            , r "softmax" 2 (T.softmax Axis.axis2of3)
            , r "logSoftmax" 1 (T.logSoftmax Axis.axis1of3)
            , both "sumAll" [] T.sumAll identity
            , both "meanAll" [] T.meanAll identity
            , both "maximumAll" [] T.maximumAll identity
            , both "minimumAll" [] T.minimumAll identity
            , [ value "minMaxMin" [ "x" ] [] (\x -> (T.minMax x).min), value "minMaxMax" [ "x" ] [] (\x -> (T.minMax x).max) ]
            ]


type alias Lin =
    { m : F (R2 A B)
    , n : F (R2 B C)
    , m3 : F (R3 D A B)
    , n3 : F (R3 D B C)
    , m4 : F (R4 D D A B)
    , n4 : F (R4 D D B C)
    , v : F (R1 B)
    , u : F (R1 A)
    , w : F (R1 B)
    }


linalg : E.Value
linalg =
    let
        ins =
            Sig.record Lin
                |> Sig.field .m (Sig.label "m" (Sig.f32 (T.r2 a b)))
                |> Sig.field .n (Sig.label "n" (Sig.f32 (T.r2 b c)))
                |> Sig.field .m3 (Sig.label "m3" (Sig.f32 (T.r3 d a b)))
                |> Sig.field .n3 (Sig.label "n3" (Sig.f32 (T.r3 d b c)))
                |> Sig.field .m4 (Sig.label "m4" (Sig.f32 (T.r4 d d a b)))
                |> Sig.field .n4 (Sig.label "n4" (Sig.f32 (T.r4 d d b c)))
                |> Sig.field .v (Sig.label "v" (Sig.f32 (T.r1 b)))
                |> Sig.field .u (Sig.label "u" (Sig.f32 (T.r1 a)))
                |> Sig.field .w (Sig.label "w" (Sig.f32 (T.r1 b)))

        mm name ref left right f =
            [ named name ref [ left, right ] [] (\i -> f i)
            ]

        g2 name ref left right fl fr =
            [ namedGrad name ref [ left, right ] left [] fl, namedGrad name ref [ left, right ] right [] fr ]
    in
    family "linalg" [] ins <|
        List.concat
            [ mm "matmul" "matmul" "m" "n" (\i -> i.m |> T.matmul i.n)
            , g2 "matmul" "matmul" "m" "n" (\i -> gradWrt (\v -> v |> T.matmul i.n) i.m) (\i -> gradWrt (\v -> i.m |> T.matmul v) i.n)
            , mm "matmul3" "matmul" "m3" "n3" (\i -> i.m3 |> T.matmul3 i.n3)
            , g2 "matmul3" "matmul" "m3" "n3" (\i -> gradWrt (\v -> v |> T.matmul3 i.n3) i.m3) (\i -> gradWrt (\v -> i.m3 |> T.matmul3 v) i.n3)
            , mm "matmul4" "matmul" "m4" "n4" (\i -> i.m4 |> T.matmul4 i.n4)
            , g2 "matmul4" "matmul" "m4" "n4" (\i -> gradWrt (\v -> v |> T.matmul4 i.n4) i.m4) (\i -> gradWrt (\v -> i.m4 |> T.matmul4 v) i.n4)
            , mm "matmul3By2" "matmul" "m3" "n" (\i -> i.m3 |> T.matmul3By2 i.n)
            , g2 "matmul3By2" "matmul" "m3" "n" (\i -> gradWrt (\v -> v |> T.matmul3By2 i.n) i.m3) (\i -> gradWrt (\v -> i.m3 |> T.matmul3By2 v) i.n)
            , mm "vecMat" "matmul" "v" "n" (\i -> i.v |> T.vecMat i.n)
            , g2 "vecMat" "matmul" "v" "n" (\i -> gradWrt (\x -> x |> T.vecMat i.n) i.v) (\i -> gradWrt (\x -> i.v |> T.vecMat x) i.n)
            , mm "matVec" "matmul" "m" "v" (\i -> i.m |> T.matVec i.v)
            , g2 "matVec" "matmul" "m" "v" (\i -> gradWrt (\x -> x |> T.matVec i.v) i.m) (\i -> gradWrt (\x -> i.m |> T.matVec x) i.v)
            , mm "dot" "matmul" "v" "w" (\i -> i.v |> T.dot i.w)
            , g2 "dot" "matmul" "v" "w" (\i -> gradWrt (\x -> x |> T.dot i.w) i.v) (\i -> gradWrt (\x -> i.v |> T.dot x) i.w)
            , mm "outer" "outer" "u" "v" (\i -> i.u |> T.outer i.v)
            , g2 "outer" "outer" "u" "v" (\i -> gradWrt (\x -> x |> T.outer i.v) i.u) (\i -> gradWrt (\x -> i.u |> T.outer x) i.v)
            ]


type alias Sh =
    { x : F (R2 A B)
    , y : F (R2 A B)
    , z : F (R3 A B C)
    , v : F (R1 B)
    , u : F (R1 A)
    , idx : Tensor Integral I64 (R1 K)
    , lab : Tensor Integral I64 (R1 A)
    , upd : F (R2 K B)
    }


type Twelve
    = Twelve


type Half
    = Half


type Six
    = Six


type Seven
    = Seven


type Twenty
    = Twenty


shapes : E.Value
shapes =
    let
        ins =
            Sig.record Sh
                |> Sig.field .x (x34 "x")
                |> Sig.field .y (x34 "y")
                |> Sig.field .z (Sig.label "z" (Sig.f32 (T.r3 a b c)))
                |> Sig.field .v (Sig.label "v" (Sig.f32 (T.r1 b)))
                |> Sig.field .u (Sig.label "u" (Sig.f32 (T.r1 a)))
                |> Sig.field .idx (Sig.label "idx" (Sig.i64 (T.r1 k2)))
                |> Sig.field .lab (Sig.label "lab" (Sig.i64 (T.r1 a)))
                |> Sig.field .upd (Sig.label "upd" (Sig.f32 (T.r2 k2 b)))

        half =
            T.dim Half 2

        one name args params f wrt g =
            [ named name name args params f, namedGrad name name args wrt params g ]
    in
    family "shapes" [ ( "idx", "idx3" ), ( "lab", "label4" ) ] ins <|
        List.concat
            [ one "reshape" [ "x" ] [ 4, 3 ] (\i -> T.reshape (T.r2 b a) i.x) "x" (\i -> gradWrt (T.reshape (T.r2 b a)) i.x)
            , one "flatten" [ "z" ] [] (\i -> T.flatten (T.dim Twenty 60) i.z) "z" (\i -> gradWrt (T.flatten (T.dim Twenty 60)) i.z)
            , one "factorLast3" [ "x" ] [ 2, 2 ] (\i -> T.factorLast3 half half i.x) "x" (\i -> gradWrt (T.factorLast3 half half) i.x)
            , one "mergeLast3" [ "z" ] [ 20 ] (\i -> T.mergeLast3 (T.dim Twenty 20) i.z) "z" (\i -> gradWrt (T.mergeLast3 (T.dim Twenty 20)) i.z)
            , one "transpose" [ "x" ] [] (\i -> T.transpose i.x) "x" (\i -> gradWrt T.transpose i.x)
            , one "permute01" [ "z" ] [] (\i -> T.permute Axis.swap01of3 i.z) "z" (\i -> gradWrt (T.permute Axis.swap01of3) i.z)
            , one "permute12" [ "z" ] [] (\i -> T.permute Axis.swap12of3 i.z) "z" (\i -> gradWrt (T.permute Axis.swap12of3) i.z)
            , one "permute02then12" [ "z" ] [] (\i -> T.permute (Axis.swap02of3 |> Axis.andThen Axis.swap12of3) i.z) "z" (\i -> gradWrt (T.permute (Axis.swap02of3 |> Axis.andThen Axis.swap12of3)) i.z)
            , one "rowsPlus" [ "x", "v" ] [] (\i -> i.x |> T.plus (T.rows i.v)) "v" (\i -> gradWrt (\w -> i.x |> T.plus (T.rows w)) i.v)
            , one "columnsTimes" [ "x", "u" ] [] (\i -> i.x |> T.times (T.columns i.u)) "u" (\i -> gradWrt (\w -> i.x |> T.times (T.columns w)) i.u)
            , one "broadcastTo" [ "v" ] [ 3 ] (\i -> T.broadcastTo a Axis.axis0of2 i.v) "v" (\i -> gradWrt (T.broadcastTo a Axis.axis0of2) i.v)
            , one "insertDrop" [ "x" ] [] (\i -> i.x |> T.insertOne Axis.axis1of3 |> T.scale 2 |> T.dropOne Axis.axis1of3) "x" (\i -> gradWrt (T.insertOne Axis.axis1of3 >> T.scale 2 >> T.dropOne Axis.axis1of3) i.x)
            , one "slice" [ "x" ] [ 1, 1, 2 ] (\i -> T.slice Axis.retag1of2 1 half i.x) "x" (\i -> gradWrt (T.slice Axis.retag1of2 1 half) i.x)
            , one "sliceUpdate" [ "x", "upd" ] [ 0, 1 ] (\i -> i.x |> T.sliceUpdate Axis.retag0of2 1 i.upd) "upd" (\i -> gradWrt (\w -> i.x |> T.sliceUpdate Axis.retag0of2 1 w) i.upd)
            , one "concat" [ "x", "y" ] [ 0 ] (\i -> T.concat Axis.retag0of2 (T.dim Six 6) [ i.x, i.y ]) "x" (\i -> gradWrt (\w -> T.concat Axis.retag0of2 (T.dim Six 6) [ w, i.y ]) i.x)
            , one "concat2" [ "x", "upd" ] [ 0 ] (\i -> T.concat2 Axis.retag0of2 Axis.retag0of2 (T.dim Seven 5) i.x i.upd) "upd" (\i -> gradWrt (\w -> T.concat2 Axis.retag0of2 Axis.retag0of2 (T.dim Seven 5) i.x w) i.upd)
            , one "chunk1" [ "x" ] [ 1, 2, 1 ] (\i -> T.chunks Axis.retag1of2 half i.x |> List.drop 1 |> List.head |> Maybe.withDefault (T.slice Axis.retag1of2 0 half i.x)) "x" (\i -> gradWrt (\w -> T.chunks Axis.retag1of2 half w |> List.drop 1 |> List.head |> Maybe.withDefault (T.slice Axis.retag1of2 0 half w)) i.x)
            , one "stack" [ "x", "y" ] [] (\i -> T.stack Axis.liftRank2 (T.dim Half 2) [ i.x, i.y ]) "x" (\i -> gradWrt (\w -> T.stack Axis.liftRank2 (T.dim Half 2) [ w, i.y ]) i.x)
            , one "unstack1" [ "z" ] [ 1 ] (\i -> T.unstack Axis.liftRank2 i.z |> List.drop 1 |> List.head |> Maybe.withDefault (T.sum Axis.axis0of3 i.z)) "z" (\i -> gradWrt (\w -> T.unstack Axis.liftRank2 w |> List.drop 1 |> List.head |> Maybe.withDefault (T.sum Axis.axis0of3 w)) i.z)
            , one "flip" [ "x" ] [ 1 ] (\i -> T.flip Axis.axis1of2 i.x) "x" (\i -> gradWrt (T.flip Axis.axis1of2) i.x)
            , one "pad" [ "x" ] [ 0, 1, 2, 0.5 ] (\i -> T.pad Axis.retag0of2 { before = 1, after = 2, value = 0.5 } (T.dim Six 6) i.x) "x" (\i -> gradWrt (T.pad Axis.retag0of2 { before = 1, after = 2, value = 0.5 } (T.dim Six 6)) i.x)
            , one "take" [ "x", "idx" ] [ 0 ] (\i -> i.x |> T.take Axis.retag0of2 i.idx) "x" (\i -> gradWrt (T.take Axis.retag0of2 i.idx) i.x)
            , one "take1" [ "x", "idx" ] [ 1 ] (\i -> i.x |> T.take Axis.retag1of2 i.idx) "x" (\i -> gradWrt (T.take Axis.retag1of2 i.idx) i.x)
            , one "pick" [ "x", "lab" ] [] (\i -> i.x |> T.pick i.lab) "x" (\i -> gradWrt (T.pick i.lab) i.x)
            , one "put" [ "x", "idx", "upd" ] [ 0 ] (\i -> i.x |> T.put Axis.retag0of2 i.idx i.upd) "upd" (\i -> gradWrt (\w -> i.x |> T.put Axis.retag0of2 i.idx w) i.upd)
            , [ namedGrad "put" "put" [ "x", "idx", "upd" ] "x" [ 0 ] (\i -> gradWrt (\w -> w |> T.put Axis.retag0of2 i.idx i.upd) i.x) ]
            , one "putAdd" [ "x", "idx", "upd" ] [ 0 ] (\i -> i.x |> T.putAdd Axis.retag0of2 i.idx i.upd) "upd" (\i -> gradWrt (\w -> i.x |> T.putAdd Axis.retag0of2 i.idx w) i.upd)
            , one "triu0" [ "x" ] [ 0 ] (\i -> T.triu 0 i.x) "x" (\i -> gradWrt (T.triu 0) i.x)
            , one "triu1" [ "x" ] [ 1 ] (\i -> T.triu 1 i.x) "x" (\i -> gradWrt (T.triu 1) i.x)
            , one "trilm1" [ "x" ] [ -1 ] (\i -> T.tril -1 i.x) "x" (\i -> gradWrt (T.tril -1) i.x)
            , one "tril0" [ "x" ] [ 0 ] (\i -> T.tril 0 i.x) "x" (\i -> gradWrt (T.tril 0) i.x)
            , [ named "lowerTriangle" "lowerTriangle" [] [] (\i -> T.indicator T.float32 (T.lowerTriangle (T.zeros T.float32 (T.r2 a a)))) ]
            , [ named "hann" "hann" [] [ 5 ] (\_ -> T.hannWindow { periodic = True } T.float32 c) ]
            , [ named "fromList" "fromList" [] [] (\_ -> T.fromList T.float32 (T.r2 d d) [ 1, 2, 3, 4 ]) ]
            , one "fillLike" [ "x" ] [] (\i -> T.fillLike (T.sumAll i.x) i.y) "x" (\i -> gradWrt (\w -> T.fillLike (T.sumAll w) i.y) i.x)
            ]


type alias NnIn =
    { logits : F (R2 A C), soft : F (R2 A C), lab : Tensor Integral I64 (R1 A), x : F (R2 A B), q : F (R3 D A B), kk : F (R3 D C B), vv : F (R3 D C B) }


nn : E.Value
nn =
    let
        ins =
            Sig.record NnIn
                |> Sig.field .logits (Sig.label "logits" (Sig.f32 (T.r2 a c)))
                |> Sig.field .soft (Sig.label "soft" (Sig.f32 (T.r2 a c)))
                |> Sig.field .lab (Sig.label "lab" (Sig.i64 (T.r1 a)))
                |> Sig.field .x (x34 "x")
                |> Sig.field .q (Sig.label "q" (Sig.f32 (T.r3 d a b)))
                |> Sig.field .kk (Sig.label "kk" (Sig.f32 (T.r3 d c b)))
                |> Sig.field .vv (Sig.label "vv" (Sig.f32 (T.r3 d c b)))

        targets i =
            T.softmax Axis.last2 i.soft

        gain i =
            T.sum Axis.axis0of2 i.x |> T.scale 0.3 |> T.shift 1

        bias i =
            T.sum Axis.axis0of2 i.x |> T.scale -0.2

        norm i v =
            LayerNorm.apply { gain = gain i, bias = bias i, epsilon = 1.0e-5 } v

        one name args params f wrt g =
            [ named name name args params f, namedGrad name name args wrt params g ]
    in
    family "nn" [ ( "lab", "label5" ) ] ins <|
        List.concat
            [ one "crossEntropy" [ "logits", "soft" ] [] (\i -> i.logits |> Nn.crossEntropy (targets i)) "logits" (\i -> gradWrt (Nn.crossEntropy (targets i)) i.logits)
            , [ namedGrad "crossEntropy" "crossEntropy" [ "logits", "soft" ] "soft" [] (\i -> gradWrt (\s -> i.logits |> Nn.crossEntropy (T.softmax Axis.last2 s)) i.soft) ]
            , one "crossEntropyIndices" [ "logits", "lab" ] [] (\i -> i.logits |> Nn.crossEntropyIndices i.lab) "logits" (\i -> gradWrt (Nn.crossEntropyIndices i.lab) i.logits)
            , one "mseLoss" [ "logits", "soft" ] [] (\i -> i.logits |> Nn.mseLoss i.soft) "logits" (\i -> gradWrt (Nn.mseLoss i.soft) i.logits)
            , one "layerNorm" [ "x" ] [] (\i -> norm i i.x) "x" (\i -> gradWrt (norm i) i.x)
            , one "attention" [ "q", "kk", "vv" ] [] (\i -> i.q |> Nn.attention { mask = Nothing, bias = Nothing } i.kk i.vv) "q" (\i -> gradWrt (Nn.attention { mask = Nothing, bias = Nothing } i.kk i.vv) i.q)
            , [ namedGrad "attention" "attention" [ "q", "kk", "vv" ] "kk" [] (\i -> gradWrt (\k -> i.q |> Nn.attention { mask = Nothing, bias = Nothing } k i.vv) i.kk)
              , namedGrad "attention" "attention" [ "q", "kk", "vv" ] "vv" [] (\i -> gradWrt (\v -> i.q |> Nn.attention { mask = Nothing, bias = Nothing } i.kk v) i.vv)
              ]
            , one "causalAttention" [ "q" ] [] (\i -> i.q |> Nn.causalAttention i.q i.q) "q" (\i -> gradWrt (\v -> v |> Nn.causalAttention v v) i.q)
            , [ named "dropoutEval" "identity" [ "x" ] [] (\i -> i.x |> Nn.dropout { rate = 0.5, training = False } (Random.seed (T.int 1))) ]
            ]


type alias Tr =
    { x : F (R1 B), v : F (R1 B), m : F (R2 A B) }


transforms : E.Value
transforms =
    let
        ins =
            Sig.record Tr
                |> Sig.field .x (Sig.label "x" (Sig.f32 (T.r1 b)))
                |> Sig.field .v (Sig.label "v" (Sig.f32 (T.r1 b)))
                |> Sig.field .m (Sig.label "m" (Sig.f32 (T.r2 a b)))

        cube y =
            y |> T.times y |> T.times y |> T.sumAll
    in
    family "transforms" [] ins <|
        [ named "confusion" "confusion" [ "x" ] [] (\i -> Transform.grad (\y -> y |> T.times i.x |> T.sumAll) i.x)
        , named "gradOfGrad" "gradOfGrad" [ "x" ] [] (\i -> Transform.grad (\y -> Transform.grad cube y |> T.sumAll) i.x)
        , named "hessianVectorSelf" "hessianVectorSelf" [ "x" ] [] (\i -> Transform.hessianVector cube i.x (Transform.grad cube i.x))
        , named "hessianVector" "hessianVector" [ "x", "v" ] [] (\i -> Transform.hessianVector cube i.x i.v)
        , named "siskind" "ones" [ "x" ] [] (\i -> Transform.grad (\y -> y |> T.times (Transform.grad (\z -> y |> T.plus z |> T.sumAll) y) |> T.sumAll) i.x)
        , named "jvpSin" "jvpSin" [ "x", "v" ] [] (\i -> Tuple.second (Transform.jvp Sig.anyTensor Sig.anyTensor T.sin i.x i.v))
        , named "vjpSin" "jvpSin" [ "x", "v" ] [] (\i -> (Tuple.second (Transform.vjp Sig.anyTensor Sig.anyTensor T.sin i.x)) i.v)
        , named "jacobianSin" "jacobianSin" [ "x" ] [] (\i -> Transform.jacobian T.sin i.x)
        , named "vmapSoftmax" "softmaxRows" [ "m" ] [] (\i -> Transform.vmap Axis.liftRank1 Axis.liftRank1 (T.softmax Axis.last1) i.m)
        , named "vmapWith" "rowsTimesX" [ "m", "x" ] [] (\i -> Transform.vmapWith (Transform.pair (Transform.tensor Axis.liftRank1) Transform.keep) (Transform.tensor Axis.liftRank1) (\( row, x ) -> row |> T.times x) ( i.m, i.x ))
        , named "gradOfRecord" "gradOfRecord" [ "x", "v" ] [] (\i -> Transform.gradOf (Sig.pair Sig.anyTensor Sig.anyTensor) (\( p, q ) -> p |> T.times q |> T.times q |> T.sumAll) ( i.x, i.v ) |> Tuple.second)
        , named "scanCumsum" "cumsumRows" [ "m" ] [] (\i -> Tuple.second (Control.scan Axis.liftRank1 Axis.liftRank1 (\acc row -> ( acc |> T.plus row, acc |> T.plus row )) (T.zerosLike i.x) i.m))
        , named "repeatDouble" "times8" [ "x" ] [] (\i -> Control.repeat 3 Sig.anyTensor (T.scale 2) i.x)
        , named "cond" "condPos" [ "x" ] [] (\i -> Control.cond (T.sumAll i.x |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor T.relu T.negate i.x)
        ]


type alias Rand =
    { seed : Random.Seed }


type Many
    = Many


random : E.Value
random =
    let
        many =
            T.dim Many 4000

        ins =
            Sig.record Rand |> Sig.field .seed Random.sig
    in
    family "random" [ ( "seed", "seed" ) ] ins <|
        [ named "uniform" "uniformStats" [] [ 0, 1 ] (\i -> Random.uniform { low = 0, high = 1 } T.float32 (T.r1 many) i.seed)
        , named "uniformAgain" "uniformStats" [] [ 0, 1 ] (\i -> Random.uniform { low = 0, high = 1 } T.float32 (T.r1 many) i.seed)
        , named "uniformSalted" "uniformStats" [] [ 0, 1 ] (\i -> Random.uniform { low = 0, high = 1 } T.float32 (T.r1 many) (Random.salt 1 i.seed))
        , named "normal" "normalStats" [] [ 2, 3 ] (\i -> Random.normal { mean = 2, std = 3 } T.float32 (T.r1 many) i.seed)
        , named "bernoulli" "bernoulliStats" [] [ 0.3 ] (\i -> T.indicator T.float32 (Random.bernoulliLike 0.3 (T.zeros T.float32 (T.r1 many)) i.seed))
        , named "dropout" "dropoutStats" [] [ 0.25 ] (\i -> T.ones T.float32 (T.r1 many) |> Nn.dropout { rate = 0.25, training = True } i.seed)
        ]


type alias Dt =
    { x : F (R2 A B) }


dtypes : E.Value
dtypes =
    family "dtypes" [] (Sig.record Dt |> Sig.field .x (x34 "x")) <|
        [ named "bf16" "bf16" [ "x" ] [] (\i -> i.x |> T.cast T.bfloat16 |> T.plus (T.cast T.bfloat16 i.x) |> T.toFloat)
        , named "f16" "f16" [ "x" ] [] (\i -> i.x |> T.cast T.float16 |> T.times (T.cast T.float16 i.x) |> T.toFloat)
        , named "f64" "f64" [ "x" ] [] (\i -> i.x |> T.cast T.float64 |> T.exp |> T.toFloat)
        , named "linear" "linear" [ "x" ] [] (\i -> Linear.apply { weight = T.transpose (T.cast T.float32 i.x) |> T.matmul i.x |> T.scale 0.1, bias = T.sum Axis.axis0of2 i.x } i.x)
        , named "rmsNormBf16" "rmsNormBf16" [ "x" ] [] (\i -> i.x |> T.cast T.bfloat16 |> RmsNorm.apply { scale = T.full T.bfloat16 1 (T.r1 b), epsilon = 1.0e-5 } |> T.toFloat)
        , named "groupNormBf16" "groupNormBf16" [ "x" ] [] (\i -> i.x |> T.cast T.bfloat16 |> T.reshape (T.r4 (T.dim One1 1) a (T.dim One1 1) b) |> GroupNorm.apply { scale = T.full T.bfloat16 1 (T.r1 b), bias = T.zeros T.bfloat16 (T.r1 b), groups = 2, epsilon = 1.0e-5 } |> T.toFloat)
        , named "qloraDequantize" "nf4" [] [] (\_ -> Qlora.dequantize { codes = T.cast T.uint8 (T.fromList T.int64 (T.r2 d d) [ 0, 7, 15, 3 ]), scales = T.fromList T.float32 (T.r1 (Qlora.blocks 2 d d)) [ 2, 0.5 ], blockSize = 2 })
        ]


type N
    = N


type H
    = H


type C3
    = C3


type C4
    = C4


type alias ConvIn =
    { x : F (T.R4 N H H C3), conv : Conv2d F32 C3 C4, back : Conv2d F32 C4 C3 }


conv : E.Value
conv =
    let
        n =
            T.dim N 2

        h =
            T.dim H 6

        ins =
            Sig.record ConvIn
                |> Sig.field .x (Sig.label "x" (Sig.f32 (T.r4 n h h (T.dim C3 3))))
                |> Sig.field .conv (Param.sig (Conv2d.params T.float32 { kernel = ( 3, 3 ) } (T.dim C3 3) (T.dim C4 4)))
                |> Sig.field .back (Sig.map identity identity (Param.sig (Conv2d.params T.float32 { kernel = ( 3, 3 ) } (T.dim C4 4) (T.dim C3 3))))

        two name params run =
            [ named name name [ "x", "param0", "param1" ] params (\i -> run i.conv i.x)
            , namedGrad name name [ "x", "param0", "param1" ] "x" params (\i -> gradWrt (run i.conv) i.x)
            , namedGrad name name [ "x", "param0", "param1" ] "param0" params (\i -> gradWrt (\f -> run { filter = f, bias = i.conv.bias } i.x) i.conv.filter)
            , namedGrad name name [ "x", "param0", "param1" ] "param1" params (\i -> gradWrt (\bv -> run { filter = i.conv.filter, bias = bv } i.x) i.conv.bias)
            ]

        nopad =
            { top = 0, bottom = 0, left = 0, right = 0 }
    in
    family "conv" [] ins <|
        List.concat
            [ two "convSame" [ 1, 1, 1, 1, 1, 1 ] Conv2d.applySame
            , two "convStride2" [ 2, 2, 0, 0, 0, 0 ] (Conv2d.apply { stride = ( 2, 2 ), padding = nopad } (T.dim H 2) (T.dim H 2))
            , two "convStride2Pad" [ 2, 2, 1, 1, 1, 1 ] (Conv2d.apply { stride = ( 2, 2 ), padding = { top = 1, bottom = 1, left = 1, right = 1 } } (T.dim H 3) (T.dim H 3))
            , [ named "convTranspose" "convTranspose" [ "x", "param2" ] [ 1, 1, 0, 0, 0, 0 ] (\i -> Conv2d.applyTransposed { stride = ( 1, 1 ), padding = nopad } (T.dim H 8) (T.dim H 8) i.back i.x)
              , namedGrad "convTranspose" "convTranspose" [ "x", "param2" ] "x" [ 1, 1, 0, 0, 0, 0 ] (\i -> gradWrt (Conv2d.applyTransposed { stride = ( 1, 1 ), padding = nopad } (T.dim H 8) (T.dim H 8) i.back) i.x)
              , namedGrad "convTranspose" "convTranspose" [ "x", "param2" ] "param2" [ 1, 1, 0, 0, 0, 0 ] (\i -> gradWrt (\f -> Conv2d.applyTransposed { stride = ( 1, 1 ), padding = nopad } (T.dim H 8) (T.dim H 8) { filter = f, bias = i.back.bias } i.x) i.back.filter)
              , named "maxPool" "maxPool" [ "x" ] [ 2 ] (\i -> Nn.maxPool2d 2 (T.dim H 3) (T.dim H 3) i.x)
              , namedGrad "maxPool" "maxPool" [ "x" ] "x" [ 2 ] (\i -> gradWrt (Nn.maxPool2d 2 (T.dim H 3) (T.dim H 3)) i.x)
              , named "avgPool" "avgPool" [ "x" ] [ 2 ] (\i -> Nn.avgPool2d 2 (T.dim H 3) (T.dim H 3) i.x)
              , namedGrad "avgPool" "avgPool" [ "x" ] "x" [ 2 ] (\i -> gradWrt (Nn.avgPool2d 2 (T.dim H 3) (T.dim H 3)) i.x)
              ]
            ]


type alias Ctl =
    { x : F (R1 B), y : F (R1 B) }


square : Transform.Shared (F (R1 B)) (F (R1 B))
square =
    Transform.shared "square" (Sig.f32 (T.r1 b)) Sig.anyTensor (\v -> v |> T.times v |> T.plus (T.sin v))


control : E.Value
control =
    let
        ins =
            Sig.record Ctl
                |> Sig.field .x (Sig.label "x" (Sig.f32 (T.r1 b)))
                |> Sig.field .y (Sig.label "y" (Sig.f32 (T.r1 b)))

        positiveSum v =
            T.sumAll v |> T.greaterThan (T.float 0)

        branchy v =
            Control.cond (positiveSum v) Sig.anyTensor Sig.anyTensor T.relu (T.scale -2) v

        capturing y v =
            Control.cond (positiveSum v) Sig.anyTensor Sig.anyTensor (\w -> w |> T.times y) (\w -> w |> T.plus y) v
    in
    family "control" [] ins <|
        [ named "condValue" "condRelu" [ "x" ] [] (\i -> branchy i.x)
        , namedGrad "condValue" "condRelu" [ "x" ] "x" [] (\i -> gradWrt branchy i.x)
        , named "condCapture" "condCapture" [ "x", "y" ] [] (\i -> capturing i.y i.x)
        , namedGrad "condCapture" "condCapture" [ "x", "y" ] "y" [] (\i -> gradWrt (\y -> capturing y i.x) i.y)
        , namedGrad "condCapture" "condCapture" [ "x", "y" ] "x" [] (\i -> gradWrt (capturing i.y) i.x)
        , named "whileHalve" "whileHalve" [ "x" ] [] (\i -> Control.whileLoop Sig.anyTensor (\v -> T.maximumAll (T.abs v) |> T.greaterThan (T.float 0.1)) (T.scale 0.5) i.x)
        , named "sharedValue" "sharedSquare" [ "x" ] [] (\i -> Transform.call square i.x)
        , named "sharedTwice" "sharedTwice" [ "x" ] [] (\i -> Transform.call square (Transform.call square i.x))
        , namedGrad "sharedTwice" "sharedTwice" [ "x" ] "x" [] (\i -> gradWrt (\v -> Transform.call square (Transform.call square v)) i.x)
        , named "sharedInCond" "sharedInCond" [ "x" ] [] (\i -> Control.cond (positiveSum i.x) Sig.anyTensor Sig.anyTensor (Transform.call square) T.negate i.x)
        , namedGrad "sharedInCond" "sharedInCond" [ "x" ] "x" [] (\i -> gradWrt (\v -> Control.cond (positiveSum v) Sig.anyTensor Sig.anyTensor (Transform.call square) T.negate v) i.x)
        ]


type alias VmIn =
    { m : F (R2 A B)
    , mm : F (R3 A B C)
    , nn : F (R3 A C D)
    , sq : F (R3 A B B)
    , w : F (R2 B C)
    , v : F (R1 B)
    , u : F (R1 C)
    , px : F (R2 B C)
    , idx : Tensor Integral I64 (R1 K)
    , r4 : F (R4 A D B D) }


vmapFamily : E.Value
vmapFamily =
    let
        ins =
            Sig.record VmIn
                |> Sig.field .m (Sig.label "m" (Sig.f32 (T.r2 a b)))
                |> Sig.field .mm (Sig.label "mm" (Sig.f32 (T.r3 a b c)))
                |> Sig.field .nn (Sig.label "nn" (Sig.f32 (T.r3 a c d)))
                |> Sig.field .sq (Sig.label "sq" (Sig.f32 (T.r3 a b b)))
                |> Sig.field .w (Sig.label "w" (Sig.f32 (T.r2 b c)))
                |> Sig.field .v (Sig.label "v" (Sig.f32 (T.r1 b)))
                |> Sig.field .u (Sig.label "u" (Sig.f32 (T.r1 c)))
                |> Sig.field .px (Sig.label "px" (Sig.f32 (T.r2 b c)))
                |> Sig.field .idx (Sig.label "idx" (Sig.i64 (T.r1 k2)))
                |> Sig.field .r4 (Sig.label "r4" (Sig.f32 (T.r4 a d b d)))

        v1 f x =
            Transform.vmap Axis.liftRank1 Axis.liftRank1 f x

        v2 f x =
            Transform.vmap Axis.liftRank2 Axis.liftRank2 f x

        cube y =
            y |> T.times y |> T.times y |> T.sumAll

        norm i =
            LayerNorm.apply { gain = i.u |> T.scale 0.5 |> T.shift 1, bias = i.u |> T.scale 0.1, epsilon = 1.0e-5 }
    in
    family "vmap" [ ( "idx", "idx3" ) ] ins <|
        [ named "vSin" "vSin" [ "m" ] [] (\i -> v1 T.sin i.m)
        , named "vPlusPlain" "vPlusPlain" [ "m", "v" ] [] (\i -> v1 (T.plus i.v) i.m)
        , named "vSumAll" "vSumAll" [ "mm" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank0 T.sumAll i.mm)
        , named "vSoftmax" "vSoftmax" [ "mm" ] [] (\i -> v2 (T.softmax Axis.last2) i.mm)
        , named "vCumsum" "vCumsum" [ "mm" ] [] (\i -> v2 (T.cumsum Axis.axis0of2) i.mm)
        , named "vVecMat" "vVecMat" [ "m", "w" ] [] (\i -> Transform.vmap Axis.liftRank1 Axis.liftRank1 (T.vecMat i.w) i.m)
        , named "vMatVec" "vMatVec" [ "mm", "u" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank1 (T.matVec i.u) i.mm)
        , named "vMatmulBoth" "vMatmulBoth" [ "mm", "nn" ] [] (\i -> Transform.vmap2 Axis.liftRank2 Axis.liftRank2 Axis.liftRank2 (\x y -> x |> T.matmul y) i.mm i.nn)
        , named "vMatmulPlainX" "vMatmulPlainX" [ "px", "nn" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank2 (\y -> i.px |> T.matmul y) i.nn)
        , named "vDot" "vDot" [ "m", "v" ] [] (\i -> Transform.vmap Axis.liftRank1 Axis.liftRank0 (T.dot i.v) i.m)
        , named "vReshape" "vReshape" [ "mm" ] [] (\i -> v2 (T.reshape (T.r2 c b)) i.mm)
        , named "vTranspose" "vTranspose" [ "mm" ] [] (\i -> v2 T.transpose i.mm)
        , named "vBroadcastTo" "vBroadcastTo" [ "m" ] [] (\i -> Transform.vmap Axis.liftRank1 Axis.liftRank2 (T.broadcastTo a Axis.axis0of2) i.m)
        , named "vSlice" "vSlice" [ "mm" ] [] (\i -> v2 (T.slice Axis.retag1of2 1 (T.dim D 2)) i.mm)
        , named "vConcatPlain" "vConcatPlain" [ "mm", "px" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank2 (\x -> T.concat Axis.retag0of2 (T.dim D 8) [ x, i.px ]) i.mm)
        , named "vPad" "vPad" [ "mm" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank2 (T.pad Axis.retag0of2 { before = 1, after = 2, value = 0.5 } (T.dim D 7)) i.mm)
        , named "vTake" "vTake" [ "mm", "idx" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank2 (T.take Axis.retag0of2 i.idx) i.mm)
        , named "vTril" "vTril" [ "sq" ] [] (\i -> v2 (T.tril 0) i.sq)
        , named "vLayerNorm" "vLayerNorm" [ "mm", "u" ] [] (\i -> v2 (norm i) i.mm)
        , named "vGrad" "vGrad" [ "m" ] [] (\i -> v1 (Transform.grad cube) i.m)
        , named "vCond" "vCond" [ "m" ] [] (\i -> v1 (\r -> Control.cond (T.sumAll r |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor T.relu T.negate r) i.m)
        , named "vVmap" "vSinMM" [ "mm" ] [] (\i -> Transform.vmap Axis.liftRank2 Axis.liftRank2 (v1 T.sin) i.mm)
        , named "vGradOuter" "vGradOuter" [ "mm" ] [] (\i -> Transform.grad (\x -> v2 (T.softmax Axis.last2) x |> T.times x |> T.sumAll) i.mm)
        , named "vRandom" "rowsDiffer" [ "m" ] [] (\i -> v1 (\r -> Random.uniformLike { low = 0, high = 1 } r (Random.seed (T.int 7))) i.m)
        , named "vRmsNorm" "vRmsNorm" [ "mm", "u" ] [] (\i -> v2 (RmsNorm.apply { scale = i.u, epsilon = 1.0e-5 }) i.mm)
        , named "vRotary" "vRotary" [ "r4" ] [] (\i -> Transform.vmap Axis.liftRank3 Axis.liftRank3 (Rotary.apply { base = 10000, pairing = Rotary.Halves } (T.iota b)) i.r4)
        , named "vRepeatHeads" "vRepeatHeads" [ "r4" ] [] (\i -> Transform.vmap Axis.liftRank3 Axis.liftRank3 (Nn.repeatHeads (T.dim H4 4)) i.r4)
        ]


{-| `Param.initGraph`: MAX draws a linear layer's initial parameters from a seed.
-}
initFamily : E.Value
initFamily =
    let
        wide =
            T.dim Wide 200

        check name ref params =
            E.object
                [ ( "name", E.string name )
                , ( "ref", E.string ref )
                , ( "args", E.list E.string [] )
                , ( "wrt", E.string "" )
                , ( "params", E.list E.float params )
                ]
    in
    case Param.initGraph "init" (Linear.params T.float32 wide (T.dim Flat 50)) of
        Ok g ->
            E.object
                [ ( "graph", E.string "init" )
                , ( "mlir", E.string (Graph.toGenericText g) )
                , ( "bytecode", E.list E.int (byteList (Graph.toBytecode g)) )
                , ( "inputs", E.list (\sp -> E.object [ ( "name", E.string sp.name ), ( "dtype", E.string sp.dtype ), ( "shape", E.list E.int sp.shape ), ( "domain", E.string "seed" ) ]) (Graph.inputs g) )
                , ( "outputs", E.list (.name >> E.string) (Graph.outputs g) )
                , ( "checks", E.list identity [ check "initWeights" "uniformStats" [ -(sqrt (6 / 200)), sqrt (6 / 200) ], check "initBias" "zerosStats" [] ] )
                ]

        Err errs ->
            E.object [ ( "graph", E.string "init" ), ( "errors", E.list E.string errs ) ]


type Wide
    = Wide


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.batch (List.map emit [ unary, positive, unit, binary, integers, reductions, linalg, shapes, nn, transforms, random, dtypes, conv, control, vmapFamily, initFamily, select, layers ]) )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }



-- ROUND 2 (plans/tensor-api-round2.md, A1)


type H4
    = H4


type H6
    = H6


type W8
    = W8


type T10
    = T10


type M8
    = M8


type Kv4
    = Kv4


type J2
    = J2


type Mw6
    = Mw6


type F6
    = F6


type T6
    = T6


type Four
    = Four


type One1
    = One1


type Rows
    = Rows


type Classes
    = Classes


type alias SelIn =
    { dist : F (R2 A C), dist3 : F (R3 A C B), x3 : F (R3 A C B), upd1 : F (R3 A D B), upd2 : F (R3 A C D) }


select : E.Value
select =
    let
        ins =
            Sig.record SelIn
                |> Sig.field .dist (Sig.label "dist" (Sig.f32 (T.r2 a c)))
                |> Sig.field .dist3 (Sig.label "dist3" (Sig.f32 (T.r3 a c b)))
                |> Sig.field .x3 (Sig.label "x3" (Sig.f32 (T.r3 a c b)))
                |> Sig.field .upd1 (Sig.label "upd1" (Sig.f32 (T.r3 a d b)))
                |> Sig.field .upd2 (Sig.label "upd2" (Sig.f32 (T.r3 a c d)))

        idx1 =
            T.fromList T.int64 (T.r1 d) [ 3, 0 ]

        idx2 =
            T.fromList T.int64 (T.r1 d) [ 2, 2 ]

        put1 x u =
            x |> T.put Axis.retag1of3 idx1 u

        putAdd2 x u =
            x |> T.putAdd Axis.retag2of3 idx2 u

        rows =
            T.dim Rows 20000

        big values =
            T.fromList T.float32 (T.r1 (T.dim Classes (List.length values))) values |> T.broadcastTo rows Axis.axis0of2
    in
    family "select" [ ( "dist", "distinct" ), ( "dist3", "distinct" ) ] ins <|
        [ named "topKValues" "topKValues" [ "dist" ] [] (\i -> T.topK Axis.retag1of2 k2 i.dist |> Tuple.first)
        , named "topKIndices" "topKIndices" [ "dist" ] [] (\i -> T.topK Axis.retag1of2 k2 i.dist |> Tuple.second)
        , named "topKMiddle" "topKMiddle" [ "dist3" ] [] (\i -> T.topK Axis.retag1of3 k2 i.dist3 |> Tuple.first)
        , named "topKMiddleIndices" "topKMiddleIndices" [ "dist3" ] [] (\i -> T.topK Axis.retag1of3 k2 i.dist3 |> Tuple.second)
        , named "bottomK" "bottomK" [ "dist" ] [] (\i -> T.bottomK Axis.retag1of2 k2 i.dist |> Tuple.first)
        , named "bottomKIndices" "bottomKIndices" [ "dist" ] [] (\i -> T.bottomK Axis.retag1of2 k2 i.dist |> Tuple.second)
        , named "sortDesc" "sortDesc" [ "dist" ] [] (\i -> T.sort { descending = True } Axis.last2 i.dist |> Tuple.first)
        , named "sortDescIndices" "sortDescIndices" [ "dist" ] [] (\i -> T.sort { descending = True } Axis.last2 i.dist |> Tuple.second)
        , named "sortAscMiddle" "sortAscMiddle" [ "dist3" ] [] (\i -> T.sort { descending = False } Axis.axis1of3 i.dist3 |> Tuple.first)
        , named "sortAscMiddleIndices" "sortAscMiddleIndices" [ "dist3" ] [] (\i -> T.sort { descending = False } Axis.axis1of3 i.dist3 |> Tuple.second)
        , named "putAxis1" "putAxis1" [ "x3", "upd1" ] [] (\i -> put1 i.x3 i.upd1)
        , namedGrad "putAxis1" "putAxis1" [ "x3", "upd1" ] "x3" [] (\i -> gradWrt (\x -> put1 x i.upd1) i.x3)
        , namedGrad "putAxis1" "putAxis1" [ "x3", "upd1" ] "upd1" [] (\i -> gradWrt (put1 i.x3) i.upd1)
        , named "putAddAxis2" "putAddAxis2" [ "x3", "upd2" ] [] (\i -> putAdd2 i.x3 i.upd2)
        , namedGrad "putAddAxis2" "putAddAxis2" [ "x3", "upd2" ] "x3" [] (\i -> gradWrt (\x -> putAdd2 x i.upd2) i.x3)
        , namedGrad "putAddAxis2" "putAddAxis2" [ "x3", "upd2" ] "upd2" [] (\i -> gradWrt (putAdd2 i.x3) i.upd2)
        , named "quickGelu" "quickGelu" [ "x3" ] [] (\i -> T.quickGelu i.x3)
        , namedGrad "quickGelu" "quickGelu" [ "x3" ] "x3" [] (\i -> gradWrt T.quickGelu i.x3)
        , named "greedy" "greedy" [ "dist" ] [] (\i -> Sampling.greedy i.dist)
        , named "keepTopK" "keepTopK" [ "dist" ] [ 2 ] (\i -> Sampling.keepTopK 2 i.dist)
        , named "categorical" "categoricalStats" [] [ 0.5, -1, 2, 0 ] (\_ -> Random.categorical (big [ 0.5, -1, 2, 0 ]) (Random.seed (T.int 3)))
        , named "nucleus" "nucleusStats" [] [ 0.6, 2, 1.5, 1, 0, -1, -2 ] (\_ -> Sampling.nucleus 0.6 (big [ 2, 1.5, 1, 0, -1, -2 ]) (Random.seed (T.int 4)))
        ]


type alias LyIn =
    { img : F (R4 D A B D)
    , steps : F (R1 A)
    , kvx : F (R3 D A B)
    , table : F (R2 C B)
    , seq : F (R2 A B)
    , scale : F (R1 B)
    , gimg : F (R4 D A A B)
    , gbias : F (R1 B)
    , rx : F (R3 D A B)
    , xs : F (R2 C M8)
    , wq : F (R2 M8 M8)
    , wk : F (R2 M8 Kv4)
    , wv : F (R2 M8 Kv4)
    , wk8 : F (R2 M8 M8)
    , wv8 : F (R2 M8 M8)
    , wo : F (R2 M8 M8)
    , mem : F (R2 A Mw6)
    , wkc : F (R2 Mw6 M8)
    , wvc : F (R2 Mw6 M8)
    , gate : F (R2 B F6)
    , up : F (R2 B F6)
    , down : F (R2 F6 B)
    }


layers : E.Value
layers =
    let
        m8 =
            T.dim M8 8

        kv4 =
            T.dim Kv4 4

        h4 =
            T.dim H4 4

        j2 =
            T.dim J2 2

        f6 =
            T.dim F6 6

        ins =
            Sig.record LyIn
                |> Sig.field .img (Sig.label "img" (Sig.f32 (T.r4 d a b d)))
                |> Sig.field .steps (Sig.label "steps" (Sig.f32 (T.r1 a)))
                |> Sig.field .kvx (Sig.label "kvx" (Sig.f32 (T.r3 d a b)))
                |> Sig.field .table (Sig.label "table" (Sig.f32 (T.r2 c b)))
                |> Sig.field .seq (Sig.label "seq" (Sig.f32 (T.r2 a b)))
                |> Sig.field .scale (Sig.label "scale" (Sig.f32 (T.r1 b)))
                |> Sig.field .gimg (Sig.label "gimg" (Sig.f32 (T.r4 d a a b)))
                |> Sig.field .gbias (Sig.label "gbias" (Sig.f32 (T.r1 b)))
                |> Sig.field .rx (Sig.label "rx" (Sig.f32 (T.r3 d a b)))
                |> Sig.field .xs (Sig.label "xs" (Sig.f32 (T.r2 c m8)))
                |> Sig.field .wq (Sig.label "wq" (Sig.f32 (T.r2 m8 m8)))
                |> Sig.field .wk (Sig.label "wk" (Sig.f32 (T.r2 m8 kv4)))
                |> Sig.field .wv (Sig.label "wv" (Sig.f32 (T.r2 m8 kv4)))
                |> Sig.field .wk8 (Sig.label "wk8" (Sig.f32 (T.r2 m8 m8)))
                |> Sig.field .wv8 (Sig.label "wv8" (Sig.f32 (T.r2 m8 m8)))
                |> Sig.field .wo (Sig.label "wo" (Sig.f32 (T.r2 m8 m8)))
                |> Sig.field .mem (Sig.label "mem" (Sig.f32 (T.r2 a (T.dim Mw6 6))))
                |> Sig.field .wkc (Sig.label "wkc" (Sig.f32 (T.r2 (T.dim Mw6 6) m8)))
                |> Sig.field .wvc (Sig.label "wvc" (Sig.f32 (T.r2 (T.dim Mw6 6) m8)))
                |> Sig.field .gate (Sig.label "gate" (Sig.f32 (T.r2 b f6)))
                |> Sig.field .up (Sig.label "up" (Sig.f32 (T.r2 b f6)))
                |> Sig.field .down (Sig.label "down" (Sig.f32 (T.r2 f6 b)))

        lin o w =
            { weight = w, bias = T.zeros T.float32 (T.r1 o) }

        grouped i =
            { query = lin m8 i.wq, key = lin kv4 i.wk, value = lin kv4 i.wv, out = lin m8 i.wo, model = m8, kvWidth = kv4, heads = h4, kvHeads = d, headDim = j2 }

        groupedFull i =
            { query = lin m8 i.wq, key = lin m8 i.wk8, value = lin m8 i.wv8, out = lin m8 i.wo, model = m8, kvWidth = m8, heads = h4, kvHeads = h4, headDim = j2 }

        cross i =
            { query = lin m8 i.wq, key = lin m8 i.wkc, value = lin m8 i.wvc, out = lin m8 i.wo, model = m8, heads = h4, headDim = j2 }

        interleaved =
            { base = 10000, pairing = Rotary.Interleaved }

        halves =
            { base = 10000, pairing = Rotary.Halves }

        upsample x =
            Nn.upsampleNearest2d 2 (T.dim H6 6) (T.dim W8 8) x

        rms i x =
            RmsNorm.apply { scale = i.scale, epsilon = 1.0e-5 } x

        gn i x =
            GroupNorm.apply { scale = i.scale, bias = i.gbias, groups = 2, epsilon = 1.0e-5 } x

        selfG i x =
            Attention.selfGrouped { causal = True, rotary = Just ( interleaved, T.iota c ) } (grouped i) x

        attendTo i x =
            x |> Attention.attendTo (cross i) i.mem

        ff i x =
            FeedForward.applyGated T.silu { gate = lin f6 i.gate, up = lin f6 i.up, down = lin b i.down } x

        cachedLast i =
            let
                four =
                    T.dim Four 4

                t6 =
                    T.dim T6 6

                g =
                    grouped i

                empty =
                    { keys = T.zeros T.float32 (T.r3 d t6 j2), values = T.zeros T.float32 (T.r3 d t6 j2) }

                ( c1, _ ) =
                    Attention.selfCached { rotary = Just halves } g (T.int 0) empty (T.slice Axis.retag0of2 0 four i.xs)
            in
            Attention.selfCached { rotary = Just halves } g (T.int 4) c1 (T.slice Axis.retag0of2 4 (T.dim One1 1) i.xs) |> Tuple.second

        one name args params f wrt g =
            [ named name name args params f, namedGrad name name args wrt params g ]
    in
    family "layers" [] ins <|
        List.concat
            [ one "upsample" [ "img" ] [] (\i -> upsample i.img) "img" (\i -> gradWrt upsample i.img)
            , [ named "timestepEmbedding" "timestepEmbedding" [ "steps" ] [ 0, 0 ] (\i -> Nn.timestepEmbedding { maxPeriod = 10000, cosFirst = False, shift = 0 } (T.dim F6 6) i.steps)
              , named "timestepEmbeddingFlip" "timestepEmbedding" [ "steps" ] [ 1, 1 ] (\i -> Nn.timestepEmbedding { maxPeriod = 10000, cosFirst = True, shift = 1 } (T.dim F6 6) i.steps)
              , mvalue "causalMaskAt" [] [ 0 ] (\_ -> Nn.causalMaskAt (T.int 0) a (T.dim T10 10))
              , { name = "causalMaskAt5", ref = "causalMaskAt", args = [], wrt = "", params = [ 5 ], fn = \_ -> mflat (Nn.causalMaskAt (T.int 5) a (T.dim T10 10)) }
              ]
            , one "repeatHeads" [ "kvx" ] [] (\i -> Nn.repeatHeads h4 i.kvx) "kvx" (\i -> gradWrt (Nn.repeatHeads h4) i.kvx)
            , one "unembed" [ "seq", "table" ] [] (\i -> Embedding.unembed { table = i.table } i.seq) "seq" (\i -> gradWrt (Embedding.unembed { table = i.table }) i.seq)
            , [ namedGrad "unembed" "unembed" [ "seq", "table" ] "table" [] (\i -> gradWrt (\t -> Embedding.unembed { table = t } i.seq) i.table) ]
            , one "rmsNorm" [ "seq", "scale" ] [] (\i -> rms i i.seq) "seq" (\i -> gradWrt (rms i) i.seq)
            , [ namedGrad "rmsNorm" "rmsNorm" [ "seq", "scale" ] "scale" [] (\i -> gradWrt (\s -> RmsNorm.apply { scale = s, epsilon = 1.0e-5 } i.seq) i.scale) ]
            , one "groupNorm" [ "gimg", "scale", "gbias" ] [] (\i -> gn i i.gimg) "gimg" (\i -> gradWrt (gn i) i.gimg)
            , [ namedGrad "groupNorm" "groupNorm" [ "gimg", "scale", "gbias" ] "scale" [] (\i -> gradWrt (\s -> GroupNorm.apply { scale = s, bias = i.gbias, groups = 2, epsilon = 1.0e-5 } i.gimg) i.scale) ]
            , one "rotaryInterleaved" [ "rx" ] [ 0 ] (\i -> Rotary.apply interleaved (T.iota a) i.rx) "rx" (\i -> gradWrt (Rotary.apply interleaved (T.iota a)) i.rx)
            , one "rotaryHalves" [ "rx" ] [ 7 ] (\i -> Rotary.apply halves (T.arange { start = 7, step = 1 } a) i.rx) "rx" (\i -> gradWrt (Rotary.apply halves (T.arange { start = 7, step = 1 } a)) i.rx)
            , one "gatedSilu" [ "seq", "gate", "up", "down" ] [] (\i -> ff i i.seq) "seq" (\i -> gradWrt (ff i) i.seq)
            , one "selfGrouped" [ "xs", "wq", "wk", "wv", "wo" ] [] (\i -> selfG i i.xs) "xs" (\i -> gradWrt (selfG i) i.xs)
            , [ named "selfGroupedFull" "selfGroupedFull" [ "xs", "wq", "wk8", "wv8", "wo" ] [] (\i -> Attention.selfGrouped { causal = False, rotary = Nothing } (groupedFull i) i.xs) ]
            , one "attendTo" [ "xs", "mem", "wq", "wkc", "wvc", "wo" ] [] (\i -> attendTo i i.xs) "xs" (\i -> gradWrt (attendTo i) i.xs)
            , [ named "cachedLast" "cachedLast" [ "xs", "wq", "wk", "wv", "wo" ] [] cachedLast ]
            ]
