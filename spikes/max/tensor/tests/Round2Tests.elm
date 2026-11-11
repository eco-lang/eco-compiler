module Round2Tests exposing (suite)

{-| Round 2 (plans/tensor-api-round2.md): resident names, `Param.named`, constant biases,
`initInPlace`, `Infer`, `importGraph`, and the build-time rules of the new operations and layers.
-}

import Expect
import Graph
import Tensor.Control as Control
import Infer
import Nn
import Nn.GroupNorm as GroupNorm
import Nn.Rotary as Rotary
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, Floating, R1, R2, R3, R4, Tensor)
import Tensor.Axis as Axis
import Test exposing (Test, describe, test)
import Train
import Transform


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
    T.dim C 2


errorsOf : Result (List String) Graph.Graph -> List String
errorsOf r =
    case r of
        Ok _ ->
            []

        Err e ->
            e


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


expectGraph : (Graph.Graph -> Expect.Expectation) -> Result (List String) Graph.Graph -> Expect.Expectation
expectGraph check r =
    case r of
        Ok g ->
            check g

        Err e ->
            Expect.fail ("not built: " ++ String.join " | " e)


roles : List Graph.Spec -> List ( String, Graph.Role )
roles =
    List.map (\s -> ( s.name, s.role ))


type alias Two =
    { l1 : Linear F32 A B, l2 : Linear F32 B C }


two : Param.Spec Two
two =
    Param.record Two
        |> Param.sub .l1 (Linear.params T.float32 a b)
        |> Param.sub .l2 (Linear.params T.float32 b c)


twoNamed : Param.Spec Two
twoNamed =
    Param.record Two
        |> Param.sub .l1 (Param.named "first" (Linear.params T.float32 a b))
        |> Param.sub .l2 (Linear.params T.float32 b c)


type alias Biasless =
    { l : Linear F32 A B }


biasless : Param.Spec Biasless
biasless =
    Param.record Biasless |> Param.sub .l (Linear.paramsWithoutBias T.float32 a b)


net : Two -> Tensor Floating F32 (R2 n A) -> Tensor Floating F32 (R2 n C)
net p x =
    x |> Linear.apply p.l1 |> T.relu |> Linear.apply p.l2


type alias Raw =
    { w1 : Tensor Floating F32 (R2 B A), b1 : Tensor Floating F32 (R1 B), w2 : Tensor Floating F32 (R2 C B), b2 : Tensor Floating F32 (R1 C) }


rawSig : Sig.Sig Raw
rawSig =
    Sig.record Raw
        |> Sig.field .w1 (Sig.label "w1" (Sig.f32 (T.r2 b a)))
        |> Sig.field .b1 (Sig.label "b1" (Sig.f32 (T.r1 b)))
        |> Sig.field .w2 (Sig.label "w2" (Sig.f32 (T.r2 c b)))
        |> Sig.field .b2 (Sig.label "b2" (Sig.f32 (T.r1 c)))


type K
    = K


count : String -> String -> Int
count fragment text =
    List.length (String.indexes fragment text)


textOf : Result (List String) Graph.Graph -> String
textOf r =
    case r of
        Ok g ->
            Graph.toGenericText g

        Err e ->
            "ERRORS: " ++ String.join " | " e


onGpu : Result (List String) Graph.Graph -> Result (List String) String
onGpu r =
    r |> Result.andThen (Graph.toGenericTextOn (Graph.Gpu 0))


suite : Test
suite =
    describe "round 2"
        [ describe "devices"
            [ test "written for the CPU, a graph is what round 1 wrote" <|
                \_ ->
                    let
                        g =
                            Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> x |> T.permute Axis.swap01of3 |> T.sin |> T.pad Axis.retag0of3 { before = 1, after = 0, value = 0.5 } (T.dim B 5))
                    in
                    Expect.equal (Result.map Graph.toGenericText g) (g |> Result.andThen (Graph.toGenericTextOn Graph.Cpu))
            , test "on a GPU, data on the device, the permutation and paddings on the host" <|
                \_ ->
                    case onGpu (Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> x |> T.permute Axis.swap01of3 |> T.scale 2 |> T.pad Axis.retag0of3 { before = 1, after = 0, value = 0.5 } (T.dim B 5))) of
                        Ok text ->
                            Expect.equal ( True, True, True )
                                ( String.contains "!mo.tensor<[3, 4, 2], f32, gpu:0>" text
                                , String.contains "!mo.tensor<[3], si64>" text
                                , String.contains "!mo.tensor<[], f32, gpu:0>" text
                                )

                        Err e ->
                            Expect.fail (String.join " | " e)
            , test "topK off the last axis is refused on a GPU, not on the CPU" <|
                \_ ->
                    let
                        g =
                            Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> T.topK Axis.retag1of3 (T.dim K 2) x |> Tuple.first)
                    in
                    Expect.equal ( True, True )
                        ( Result.map (always ()) (g |> Result.andThen (Graph.toGenericTextOn Graph.Cpu)) == Ok ()
                        , case onGpu g of
                            Err [ e ] ->
                                String.contains "on a GPU only the last axis" e

                            _ ->
                                False
                        )
            , test "a branch is refused on a GPU (MAX needs the predicate on the CPU)" <|
                \_ ->
                    case onGpu (Graph.function "g" (Sig.f32 (T.r1 b)) (\x -> Control.cond (T.sumAll x |> T.greaterThan (T.float 0)) Sig.anyTensor Sig.anyTensor T.relu T.negate x)) of
                        Err [ e ] ->
                            Expect.equal True (String.contains "MAX needs their predicate on the CPU" e)

                        other ->
                            Expect.fail (Debug.toString other)
            , test "a custom kernel names the GPU" <|
                \_ -> onGpu (Graph.function "g" (Sig.f32 (T.r1 b)) T.acos) |> Result.map (String.contains "#M.device_ref<\"gpu\", 0>") |> Expect.equal (Ok True)
            ]
        , describe "operations"
            [ test "topK refuses k larger than the axis" <|
                \_ -> expectError "k = 9 but axis 1 has size 4" (Graph.function "g" (Sig.f32 (T.r2 a b)) (\x -> T.topK Axis.retag1of2 (T.dim K 9) x |> Tuple.first))
            , test "values and indices share one rmo.top_k" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r2 a b)) (\x -> T.topK Axis.retag1of2 (T.dim K 2) x |> (\( v, i ) -> v |> T.plus (T.toFloat i)))
                        |> textOf
                        |> count "rmo.top_k"
                        |> Expect.equal 1
            , test "sort ascending is one rmo.mo.bottom_k" <|
                \_ -> Graph.function "g" (Sig.f32 (T.r2 a b)) (\x -> T.sort { descending = False } Axis.last2 x |> Tuple.first) |> textOf |> count "rmo.mo.bottom_k" |> Expect.equal 1
            , test "differentiating through topK is refused" <|
                \_ -> expectError "topK: cannot be differentiated" (Graph.function "g" (Sig.f32 (T.r2 a b)) (Transform.grad (\x -> T.topK Axis.retag1of2 (T.dim K 2) x |> Tuple.first |> T.sumAll)))
            , test "put on a middle axis is one scatter, no transposes" <|
                \_ ->
                    Graph.function "g" (Sig.pair (Sig.f32 (T.r3 a b c)) (Sig.f32 (T.r3 a c c))) (\( x, u ) -> x |> T.put Axis.retag1of3 (T.fromList T.int64 (T.r1 c) [ 3, 0 ]) u)
                        |> textOf
                        |> (\t -> Expect.equal ( 1, 0 ) ( count "rmo.mo.scatter" t, count "transpose" t ))
            , test "repeatHeads needs a multiple" <|
                \_ -> expectError "repeatHeads: 3 heads are not a multiple of 2 key/value heads" (Graph.function "g" (Sig.f32 (T.r3 c a b)) (Nn.repeatHeads (T.dim A 3)))
            , test "GroupNorm needs groups that divide the channels" <|
                \_ -> expectError "GroupNorm: 3 groups do not divide 4 channels" (Graph.function "g" (Sig.f32 (T.r4 c a a b)) (GroupNorm.apply { scale = T.zeros T.float32 (T.r1 b), bias = T.zeros T.float32 (T.r1 b), groups = 3, epsilon = 1.0e-5 }))
            , test "rotary needs an even head" <|
                \_ -> expectError "Rotary: a head of 3 features has no pairs" (Graph.function "g" (Sig.f32 (T.r3 c b a)) (Rotary.apply { base = 10000, pairing = Rotary.Halves } (T.iota b)))
            , test "upsampling checks its result's size" <|
                \_ -> expectError "upsampleNearest2d: 3 × 3 by 2 is not 6 × 5" (Graph.function "g" (Sig.f32 (T.r4 c a a b)) (Nn.upsampleNearest2d 2 (T.dim A 6) (T.dim C 5)))
            , test "attention builds in f16" <|
                \_ -> Expect.equal [] (errorsOf (Graph.function "g" (Sig.tensor T.float16 (T.r3 c a b)) (\q -> q |> Nn.causalAttention q q)))
            ]
        , describe "resident names"
            [ test "unnamed specs keep round 1's names" <|
                \_ -> Expect.equal [ "param0", "param1", "param2", "param3" ] (Param.names two)
            , test "a named part has names of its own; the rest are numbered among themselves" <|
                \_ -> Expect.equal [ "first.param0", "first.param1", "param0", "param1" ] (Param.names twoNamed)
            , test "a named part alone has the names it has inside the whole" <|
                \_ -> Expect.equal [ "first.param0", "first.param1" ] (Param.names (Param.named "first" (Linear.params T.float32 a b)))
            , test "the innermost name wins" <|
                \_ -> Expect.equal [ "first.param0", "first.param1", "outer.param0", "outer.param1" ] (Param.names (Param.named "outer" twoNamed))
            , test "Train uses the same names" <|
                \_ ->
                    Train.step twoNamed (Optim.sgd 0.1) (Sig.pair (Sig.f32 (T.r2 c a)) (Sig.f32 (T.r2 c c))) (\p ( x, y ) -> net p x |> T.minus y |> T.relu |> T.sumAll)
                        |> expectGraph (\g -> Expect.equal [ "first.param0", "first.param1", "param0", "param1" ] (List.take 4 (List.map .name (Graph.inputs g))))
            ]
        , describe "constant biases"
            [ test "a linear without bias has one parameter" <|
                \_ -> Expect.equal ( [ "param" ], 1 ) ( Param.names biasless, Param.count biasless )
            , test "its training step reads only the weight" <|
                \_ ->
                    Train.step biasless (Optim.sgd 0.1) (Sig.f32 (T.r2 c a)) (\p x -> Linear.apply p.l x |> T.sumAll)
                        |> expectGraph (\g -> Expect.equal [ "param", "batch" ] (List.map .name (Graph.inputs g)))
            ]
        , describe "initInPlace"
            [ test "writes the parameters into their resident buffers" <|
                \_ ->
                    Param.initInPlace "init" twoNamed
                        |> expectGraph
                            (\g ->
                                Expect.equal
                                    [ Graph.Resident "first.param0", Graph.Resident "first.param1", Graph.Resident "param0", Graph.Resident "param1" ]
                                    (List.map .role (Graph.outputs g))
                            )
            , test "initGraph still sends them back" <|
                \_ -> Param.initGraph "init" two |> expectGraph (\g -> Expect.equal [ Graph.Fed, Graph.Fed, Graph.Fed, Graph.Fed ] (List.map .role (Graph.outputs g)))
            ]
        , describe "Infer"
            [ test "parameters and state are resident, the input fed, a scalar input travels as [1]" <|
                \_ ->
                    Infer.step "run" two (Sig.label "h" (Sig.f32 (T.r2 c c))) (Sig.pair (Sig.f32 (T.r2 c a)) (Sig.f32 T.scalar)) (Sig.f32 (T.r2 c c)) (\p h ( x, s ) -> ( h |> T.plus (net p x), h |> T.scale 2 |> T.plus (T.broadcast Axis.axis0of2 (T.broadcast Axis.axis0of1 s)) ))
                        |> expectGraph
                            (\g ->
                                Expect.equal
                                    ( [ ( "param0", Graph.Resident "param0" ), ( "param1", Graph.Resident "param1" ), ( "param2", Graph.Resident "param2" ), ( "param3", Graph.Resident "param3" ), ( "infer.h", Graph.Resident "infer.h" ), ( "arg0", Graph.Fed ), ( "arg1", Graph.Fed ) ]
                                    , [ [ 1 ] ]
                                    , List.map .role (Graph.outputs g)
                                    )
                                    ( roles (Graph.inputs g)
                                    , List.drop 6 (List.map .shape (Graph.inputs g))
                                    , [ Graph.Resident "infer.h", Graph.Fed ]
                                    )
                            )
            , test "a state that changes size is refused" <|
                \_ ->
                    Infer.step "run" two (Sig.label "h" (Sig.f32 (T.r1 b))) (Sig.f32 (T.r1 b)) (Sig.f32 (T.r1 b)) (\_ h x -> ( T.concat Axis.retag0of1 b [ h, x ], x ))
                        |> expectError "Infer: state infer.h changes from f32[4] to f32[8]"
            , test "initGraph writes the state on the host" <|
                \_ ->
                    Infer.initGraph "init" (Sig.list 2 (Sig.label "keys" (Sig.f32 (T.r2 a b)))) [ T.zeros T.float32 (T.r2 a b), T.zeros T.float32 (T.r2 a b) ]
                        |> expectGraph (\g -> Expect.equal ( [], [ Graph.Resident "infer.keys0", Graph.Resident "infer.keys1" ] ) ( Graph.inputs g, List.map .role (Graph.outputs g) ))
            ]
        , describe "importGraph"
            [ test "raw tensors in, parameters out, both resident" <|
                \_ ->
                    Param.importGraph "import" twoNamed rawSig (\r -> { l1 = { weight = T.transpose r.w1, bias = r.b1 }, l2 = { weight = T.transpose r.w2, bias = r.b2 } })
                        |> expectGraph
                            (\g ->
                                Expect.equal
                                    ( [ ( "w1", Graph.Resident "w1" ), ( "b1", Graph.Resident "b1" ), ( "w2", Graph.Resident "w2" ), ( "b2", Graph.Resident "b2" ) ]
                                    , [ ( "first.param0", Graph.Resident "first.param0" ), ( "first.param1", Graph.Resident "first.param1" ), ( "param0", Graph.Resident "param0" ), ( "param1", Graph.Resident "param1" ) ]
                                    )
                                    ( roles (Graph.inputs g), roles (Graph.outputs g) )
                            )
            , test "a conversion of the wrong size is refused with both shapes" <|
                \_ ->
                    Param.importGraph "import" (Linear.params T.float32 a b) (Sig.label "w" (Sig.f32 (T.r2 a (T.dim B 5)))) (\w -> { weight = w, bias = T.zeros T.float32 (T.r1 b) })
                        |> expectError "importGraph: param0 is f32[3,5], the parameter is f32[3,4]"
            ]
        ]
