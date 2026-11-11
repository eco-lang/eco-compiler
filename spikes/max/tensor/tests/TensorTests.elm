module TensorTests exposing (suite)

{-| Build-time behaviour of the tensor package: shape rules and their error texts, keys,
signatures' round trips, parameter layouts, witnesses. Values on MAX are `opcheck`'s job.
-}

import Bytes
import Bytes.Decode as Decode
import Expect
import Finetune.Qlora as Qlora
import Tensor.Check as Check
import Graph
import Nn.LayerNorm as LayerNorm
import Nn.Linear as Linear
import Param
import Signature as Sig
import Tensor.Control as Control
import Transform
import Tensor as T exposing (Dim, F32, Floating, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E
import Tensor.Internal.Key as K
import Tensor.Internal.Prim
import Tensor.Internal.Types as I
import Test exposing (Test, describe, test)


type A
    = A


type B
    = B


type C
    = C


a : Dim A
a =
    T.dim A 3


b : Dim B
b =
    T.dim B 4


c : Dim C
c =
    T.dim C 5


errorsOf : Result (List String) Graph.Graph -> List String
errorsOf r =
    case r of
        Err e ->
            e

        Ok _ ->
            []


expectError : String -> Result (List String) Graph.Graph -> Expect.Expectation
expectError fragment r =
    case r of
        Err e ->
            if List.any (String.contains fragment) e then
                Expect.pass

            else
                Expect.fail ("no error containing \"" ++ fragment ++ "\" in: " ++ String.join " | " e)

        Ok _ ->
            Expect.fail ("built, but expected an error containing \"" ++ fragment ++ "\"")


f34 : Sig.Sig (Tensor Floating F32 (R2 A B))
f34 =
    Sig.f32 (T.r2 a b)


type alias Pair =
    { gain : Tensor Floating F32 (R1 B), bias : Tensor Floating F32 (R1 B) }


suite : Test
suite =
    describe "tensor"
        [ describe "shape rules"
            [ test "a reshape must keep the element count" <|
                \_ -> expectError "cannot reshape [3, 4] (12 elements) to [5, 3]" (Graph.function "g" f34 (T.reshape (T.r2 c a)))
            , test "a broadcast axis cannot reach a reduction" <|
                \_ -> expectError "has no size here" (Graph.function "g" (Sig.f32 (T.r1 b)) (\v -> T.rows v |> T.sum Axis.axis0of2 |> asB))
            , test "a broadcast axis resolves in an element-wise operation" <|
                \_ -> Expect.equal [] (errorsOf (Graph.function "g" (Sig.pair f34 (Sig.f32 (T.r1 b))) (\( x, v ) -> x |> T.plus (T.rows v) |> T.sum Axis.axis0of2)))
            , test "a broadcast axis cannot be a graph output" <|
                \_ -> expectError "output result" (Graph.function "g" (Sig.f32 (T.r1 b)) (\v -> T.rows v |> asAB))
            , test "sizes that differ are refused where the tensors meet" <|
                \_ -> expectError "sizes differ: [3, 4] and [3, 5]" (Graph.function "g" (Sig.pair f34 (Sig.f32 (T.r2 a (T.dim B 5)))) (\( x, y ) -> x |> T.plus y))
            , test "a concat's declared size is checked" <|
                \_ -> expectError "concat: the result has 6 along axis 0, but its dimension says 7" (Graph.function "g" f34 (\x -> T.concat Axis.retag0of2 (T.dim C 7) [ x, x ]))
            , test "stack checks its count" <|
                \_ -> expectError "stack: 2 tensors, but the dimension says 3" (Graph.function "g" f34 (\x -> T.stack Axis.liftRank2 a [ x, x ]))
            , test "chunks must divide the axis" <|
                \_ -> expectError "chunks: 3 does not divide 4" (Graph.function "g" f34 (\x -> T.chunks Axis.retag1of2 (T.dim C 3) x |> List.head |> Maybe.withDefault (T.slice Axis.retag1of2 0 (T.dim C 3) x)))
            , test "a slice must fit" <|
                \_ -> expectError "is outside [3, 4]" (Graph.function "g" f34 (T.slice Axis.retag1of2 2 (T.dim C 3)))
            , test "negating unsigned integers is refused (MAX does not compile it)" <|
                \_ -> expectError "negate: MAX does not compile this for ui8 tensors" (Graph.function "g" (Sig.u8 (T.r1 b)) T.negate)
            , test "every error is reported, each once" <|
                \_ ->
                    Expect.equal 2
                        (List.length
                            (errorsOf
                                (Graph.function "g"
                                    f34
                                    (\x ->
                                        T.reshape (T.r2 c a) x
                                            |> T.plus (T.reshape (T.r2 c a) x)
                                            |> T.plus (T.reshape (T.r2 a c) (T.scale 2 x) |> T.transpose)
                                    )
                                )
                            )
                        )
            , test "graph inputs need shapes" <|
                \_ -> expectError "has no shape" (Graph.function "g" Sig.anyTensor (\x -> T.relu (x |> asAB)))
            , test "inputs of another graph are refused" <|
                \_ ->
                    let
                        outer =
                            Graph.function "first" f34 identity
                    in
                    case outer of
                        _ ->
                            expectError "input of graph" (Graph.function "second" f34 (\x -> x |> T.plus (foreign ())))
            ]
        , describe "keys"
            [ test "equal expressions get equal keys" <|
                \_ -> Expect.equal (E.key (I.tensor (T.relu (T.float 2)))) (E.key (I.tensor (T.relu (T.float 2))))
            , test "different constants get different keys" <|
                \_ -> Expect.notEqual (E.key (I.tensor (T.float 2))) (E.key (I.tensor (T.float 3)))
            , test "-0 and 0 differ" <|
                \_ -> Expect.notEqual (K.mixFloat 0 ( 1, 1 )) (K.mixFloat -0 ( 1, 1 ))
            , test "NaN keys itself" <|
                \_ -> Expect.equal (K.mixFloat (0 / 0) ( 1, 1 )) (K.mixFloat (0 / 0) ( 1, 1 ))
            , test "operand order matters" <|
                \_ -> Expect.notEqual (E.key (I.tensor (T.float 1 |> T.minus (T.float 2)))) (E.key (I.tensor (T.float 2 |> T.minus (T.float 1))))
            ]
        , describe "signatures"
            [ test "a record codec with a misplaced accessor is refused" <|
                \_ ->
                    expectError "does not give back what it builds"
                        (Graph.build "g"
                            (Sig.record Pair |> Sig.field .bias (Sig.f32 (T.r1 b)) |> Sig.field .gain (Sig.f32 (T.r1 b)))
                            (Sig.label "out" Sig.anyTensor)
                            (\p -> p.gain |> T.plus (T.scale 2 p.bias))
                        )
            , test "a map whose functions are not inverses is refused" <|
                \_ -> expectError "does not give back" (Graph.build "g" (Sig.map T.relu T.exp f34) Sig.anyTensor identity)
            , test "a parameter record whose config differs is refused" <|
                \_ ->
                    expectError "configuration field differs"
                        (Graph.build "g" (Param.sig (LayerNorm.params T.float32 b)) (Param.sig (LayerNorm.params T.float32 b)) (\p -> { p | epsilon = 0.1 }))
            , test "labels name inputs and number repeats" <|
                \_ ->
                    case Graph.build "g" (Sig.pair (Sig.label "w" f34) (Sig.pair (Sig.label "x" f34) (Sig.label "x" f34))) (Sig.label "y" Sig.anyTensor) (\( w, ( x, y ) ) -> w |> T.plus x |> T.plus y) of
                        Ok g ->
                            Expect.equal [ "w", "x0", "x1", "y" ] (List.map .name (Graph.inputs g) ++ List.map .name (Graph.outputs g))

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "parameters"
            [ test "the packed block of a linear layer" <|
                \_ -> Expect.equal (4 * 3 * 4 + 16) (Param.byteSize (Linear.params T.float32 a b))
            , test "initial bytes match the layout" <|
                \_ -> Expect.equal (Param.byteSize (Linear.params T.float32 a b)) (Bytes.width (Param.initial (Linear.params T.float32 a b) 42))
            , test "a parameter signature names its inputs" <|
                \_ ->
                    case Graph.function "g" (Param.sig (Linear.params T.float32 a b)) (\p -> T.sumAll p.weight |> T.plus (T.sumAll p.bias)) of
                        Ok g ->
                            Expect.equal [ "param0", "param1" ] (List.map .name (Graph.inputs g))

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "witnesses"
            [ test "last2 is axis 1" <|
                \_ -> Expect.equal (I.Axis 1) (Axis.last2 |> (\(I.Axis i) -> I.Axis i))
            , test "axis2of5 is axis 2" <|
                \_ -> Expect.equal 2 (Axis.axis2of5 |> (\(I.Axis i) -> i))
            , test "swap13of4 swaps 1 and 3" <|
                \_ -> Expect.equal [ ( 1, 3 ) ] (Axis.swap13of4 |> (\(I.Perm s) -> s))
            ]
        , describe "control flow and transforms"
            [ test "differentiating through a loop is refused" <|
                \_ ->
                    expectError "a loop cannot be differentiated"
                        (Graph.function "g"
                            (Sig.f32 (T.r1 b))
                            (Transform.grad (\v -> Control.whileLoop Sig.anyTensor (\w -> T.sumAll w |> T.greaterThan (T.float 1)) (T.scale 0.5) v |> T.sumAll))
                        )
            , test "a shared function may not read a graph input it was not given" <|
                \_ ->
                    expectError "a shared function reads a tensor that is not one of its arguments"
                        (Graph.function "g"
                            (Sig.pair (Sig.f32 (T.r1 b)) (Sig.f32 (T.r1 b)))
                            (\( x, y ) -> Transform.call (Transform.shared "f" (Sig.f32 (T.r1 b)) Sig.anyTensor (\v -> v |> T.plus y)) x)
                        )
            , test "vmap lowers by rules: one batched operation, no per-example slices" <|
                \_ ->
                    case Graph.function "g" f34 (Transform.vmap Axis.liftRank1 Axis.liftRank1 T.sin) of
                        Ok g ->
                            Expect.equal ( 1, 0 ) ( occurrences "\"rmo.mo.sin\"" (Graph.toGenericText g), occurrences "\"rmo.slice\"" (Graph.toGenericText g) )

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "cond, whileLoop and shared calls lower to mo.if, mo.while and mo.call" <|
                \_ ->
                    let
                        sq =
                            Transform.shared "sq" (Sig.f32 (T.r1 b)) Sig.anyTensor (\v -> v |> T.times v)
                    in
                    case
                        Graph.function "g"
                            (Sig.f32 (T.r1 b))
                            (\x ->
                                Control.cond (T.sumAll x |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor T.relu T.negate x
                                    |> Control.whileLoop Sig.anyTensor (\w -> T.sumAll w |> T.greaterThan (T.float 1)) (T.scale 0.5)
                                    |> Transform.call sq
                            )
                    of
                        Ok g ->
                            Expect.equal [ 1, 1, 1, 1 ] (List.map (\op -> occurrences op (Graph.toGenericText g)) [ "\"mo.if\"", "\"mo.while\"", "\"mo.call\"", "isSubgraph" ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "host-side helpers"
            [ test "QLoRA quantises to the nearest NF4 code, per block scaled by its largest magnitude" <|
                \_ ->
                    let
                        bytes =
                            Qlora.quantize 2 (T.dim A 2) (T.dim B 2) [ 0.5, -1, 0, 0.25 ]

                        decoder =
                            Decode.map2 Tuple.pair
                                (Decode.map4 (\w x y z -> [ w, x, y, z ]) Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8)
                                (Decode.bytes 12 |> Decode.andThen (\_ -> Decode.map2 (\p q -> [ p, q ]) (Decode.float32 Bytes.LE) (Decode.float32 Bytes.LE)))
                    in
                    Expect.equal (Just ( [ 12, 0, 7, 15 ], [ 1, 0.25 ] )) (Decode.decode decoder bytes)
            , test "normal initialisation has the requested spread" <|
                \_ ->
                    let
                        spec =
                            Param.record identity |> Param.normal 0.5 identity T.float32 (T.r1 (T.dim A 4000))

                        values =
                            Decode.decode (Decode.loop ( 4000, [] ) (\( n, acc ) -> if n == 0 then Decode.succeed (Decode.Done acc) else Decode.map (\v -> Decode.Loop ( n - 1, v :: acc )) (Decode.float32 Bytes.LE))) (Param.initial spec 7)
                                |> Maybe.withDefault []

                        mean =
                            List.sum values / 4000

                        std =
                            sqrt (List.sum (List.map (\v -> (v - mean) ^ 2) values) / 4000)
                    in
                    Expect.equal ( True, True ) ( abs mean < 0.03, abs (std - 0.5) < 0.03 )
            , test "allClose accepts within tolerance" <|
                \_ -> Expect.equal (Ok ()) (Check.allClose { rtol = 1.0e-3, atol = 0 } [ 1, 2.001 ] [ 1, 2 ])
            , test "allClose reports the first difference" <|
                \_ -> Expect.equal (Err "1 elements differ; first at 1: 2.1 vs 2") (Check.allClose { rtol = 1.0e-3, atol = 0 } [ 1, 2.1 ] [ 1, 2 ])
            ]
        , describe "lowering"
            [ test "a small graph's generic text" <|
                \_ ->
                    case Graph.function "f" f34 (\x -> x |> T.relu |> T.sum Axis.last2) of
                        Ok g ->
                            Expect.equal
                                [ "\"rmo.mo.relu\"", "\"rmo.mo.reduce.add\"", "{axis = 1 : index}", "newShape = #mosh<ape[3]>" ]
                                (List.filter (\s -> String.contains s (Graph.toGenericText g)) [ "\"rmo.mo.relu\"", "\"rmo.mo.reduce.add\"", "{axis = 1 : index}", "newShape = #mosh<ape[3]>" ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "a negative axis is never written" <|
                \_ ->
                    case Graph.function "f" (Sig.f32 (T.r3 a b c)) (T.softmax Axis.last3) of
                        Ok g ->
                            Expect.equal True (String.contains "{axis = 2 : index}" (Graph.toGenericText g))

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        ]


foreign : () -> Tensor Floating F32 (R2 A B)
foreign _ =
    I.Tensor (E.input "first" 0 Tensor.Internal.Prim.F32 [ 3, 4 ])


asB : Tensor Floating F32 (R1 B) -> Tensor Floating F32 (R1 B)
asB =
    identity


asAB : Tensor Floating F32 (R2 A B) -> Tensor Floating F32 (R2 A B)
asAB =
    identity


occurrences : String -> String -> Int
occurrences needle hay =
    List.length (String.indexes needle hay)
