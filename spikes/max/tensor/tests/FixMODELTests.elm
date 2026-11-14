module FixMODELTests exposing (suite)

import Bytes
import Bytes.Decode as Decode
import Dict
import Expect
import Finetune.Lora as Lora
import Finetune.Qlora as Qlora
import Graph
import Infer
import Nn
import Nn.Conv2d as Conv2d
import Nn.GroupNorm as GroupNorm
import Nn.Rotary as Rotary
import Nn.Sampling as Sampling
import Nn.Stack as Stack
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (F32, R1, Tensor)
import Tensor.Eval as Eval
import Tensor.Internal.Expr as E
import Tensor.Internal.Names as Names
import Tensor.Internal.Prim as Prim
import Tensor.Internal.Types as I
import Tensor.Random as Random
import Test exposing (Test, describe, test)
import Train
import Transform


type A
    = A


type B
    = B


type C
    = C


type alias Layer =
    { w : Tensor Float F32 (R1 A) }


layer : Param.Spec Layer
layer =
    Param.record Layer |> Param.zeros .w T.float32 (T.r1 (T.dim A 3))


type alias Layers =
    { layers : List Layer }


layers2 : Param.Spec Layers
layers2 =
    Param.record Layers |> Param.sub .layers (Param.list 2 layer)


three : Layers
three =
    { layers = List.repeat 3 { w = T.ones T.float32 (T.r1 (T.dim A 3)) } }


type alias Pair =
    { p : Tensor Float F32 (R1 A), q : Tensor Float F32 (R1 B) }


pairSpec : Param.Spec Pair
pairSpec =
    Param.record Pair
        |> Param.zeros .p T.float32 (T.r1 (T.dim A 3))
        |> Param.zeros .q T.float32 (T.r1 (T.dim B 4))


oneVec : Param.Spec (Tensor Float F32 (R1 A))
oneVec =
    Param.record identity |> Param.zeros identity T.float32 (T.r1 (T.dim A 3))


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


problemsOf : List (Tensor Float F32 (R1 A)) -> List (Maybe String)
problemsOf =
    List.map (I.tensor >> E.problem)


vecA : Sig.Sig (Tensor Float F32 (R1 A))
vecA =
    Sig.f32 (T.r1 (T.dim A 3))


seedOf : Int -> Random.Seed
seedOf n =
    Random.seed (T.full T.int64 n T.scalar)


{-| Returns the number of nodes reachable from `e` that compare two f16 operands into a mask.
-}
f16Comparisons : E.Expr -> Int
f16Comparisons e =
    let
        here =
            if E.dtype e == Prim.Bool && List.length (E.operands e) == 2 && List.all (\o -> E.dtype o == Prim.F16) (E.operands e) then
                1

            else
                0
    in
    here + List.sum (List.map f16Comparisons (E.operands e))


errOf : Result String a -> Maybe String
errOf r =
    case r of
        Ok _ ->
            Nothing

        Err e ->
            Just e


inputNames : Result (List String) Graph.Graph -> List String
inputNames r =
    case r of
        Ok g ->
            List.map .name (Graph.inputs g)

        Err e ->
            e


suite : Test
suite =
    describe "MODEL fixes"
        [ describe "B005 Qlora.quantize on large weights and bad block sizes"
            [ test "131072 blocks give 131072 scales without overflowing the stack" <|
                \_ ->
                    Qlora.quantize T.float32 1 (T.dim A 256) (T.dim B 512) (List.repeat (256 * 512) 0.5)
                        |> Result.map (\r -> ( Bytes.width r.codes, Bytes.width r.scales ))
                        |> Expect.equal (Ok ( 256 * 512, 256 * 512 * 4 ))
            , test "a block size of 0 is refused" <|
                \_ ->
                    Qlora.quantize T.float32 0 (T.dim A 2) (T.dim B 2) [ 1, 2, 3, 4 ]
                        |> errOf
                        |> Expect.equal (Just "Qlora.quantize: the block size is 0, but it must be positive")
            , test "a negative block size is refused" <|
                \_ ->
                    Qlora.quantize T.float32 -3 (T.dim A 2) (T.dim B 2) [ 1, 2, 3, 4 ]
                        |> errOf
                        |> Expect.equal (Just "Qlora.quantize: the block size is -3, but it must be positive")
            ]
        , describe "B011 Qlora.quantize and dequantize follow the description"
            [ test "a block size that does not divide i × o is refused" <|
                \_ ->
                    Qlora.quantize T.float64 4 (T.dim A 2) (T.dim B 3) (List.map toFloat (List.range 1 6))
                        |> errOf
                        |> Expect.equal (Just "Qlora.quantize: the block size 4 does not divide the 6 weights")
            , test "a weight count other than i × o is refused" <|
                \_ ->
                    Qlora.quantize T.float32 2 (T.dim A 2) (T.dim B 3) [ 1, 2, 3, 4 ]
                        |> errOf
                        |> Expect.equal (Just "Qlora.quantize: 4 weights were given for 2 × 3 = 6")
            , test "a NaN weight is refused" <|
                \_ ->
                    Qlora.quantize T.float32 2 (T.dim A 1) (T.dim B 2) [ 0 / 0, 1 ]
                        |> errOf
                        |> Expect.equal (Just "Qlora.quantize: a weight is NaN or infinite")
            , test "f64 scales are written as f64 and accepted by initialFrom" <|
                \_ ->
                    case Qlora.quantize T.float64 2 (T.dim A 2) (T.dim B 2) [ 0.5, -1, 0, 0.25 ] of
                        Ok q ->
                            Expect.equal
                                ( Decode.decode (Decode.map2 (\p r -> [ p, r ]) (Decode.float64 Bytes.LE) (Decode.float64 Bytes.LE)) q.scales
                                , Train.initialFrom (Qlora.params T.float64 2 (T.dim A 2) (T.dim B 2)) (Optim.sgd 0.1) [ ( "data0", q.codes ), ( "data1", q.scales ) ]
                                    |> Result.map (List.map (Tuple.mapSecond Bytes.width))
                                )
                                ( Just [ 1, 0.25 ], Ok [ ( "data0", 4 ), ( "data1", 16 ) ] )

                        Err e ->
                            Expect.fail e
            , test "codes are the nearest NF4 indices per block" <|
                \_ ->
                    Qlora.quantize T.float32 2 (T.dim A 2) (T.dim B 2) [ 0.5, -1, 0, 0.25 ]
                        |> Result.map (\q -> Decode.decode (Decode.map4 (\w x y z -> [ w, x, y, z ]) Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8) q.codes)
                        |> Expect.equal (Ok (Just [ 12, 0, 7, 15 ]))
            , test "dequantize refuses a blockSize that disagrees with the scales" <|
                \_ ->
                    { codes = T.zeros T.uint8 (T.r2 (T.dim A 2) (T.dim B 2)), scales = T.ones T.float32 (T.r1 (Qlora.blocks 2 (T.dim A 2) (T.dim B 2))), blockSize = 3 }
                        |> Qlora.dequantize
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "Qlora.dequantize: 2 scales of blocks of 3 cover 6 elements, but the weight has 4")
            , test "dequantize refuses a block size of 0" <|
                \_ ->
                    { codes = T.zeros T.uint8 (T.r2 (T.dim A 2) (T.dim B 2)), scales = T.ones T.float32 (T.r1 (Qlora.blocks 0 (T.dim A 2) (T.dim B 2))), blockSize = 0 }
                        |> Qlora.dequantize
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "Qlora.dequantize: the block size is 0, but it must be positive")
            , test "dequantize of a consistent weight gives codebook values times scales" <|
                \_ ->
                    { codes = T.fromList T.uint8 (T.r2 (T.dim A 2) (T.dim B 2)) [ 15, 0, 7, 15 ], scales = T.fromList T.float32 (T.r1 (Qlora.blocks 2 (T.dim A 2) (T.dim B 2))) [ 2, 0.5 ], blockSize = 2 }
                        |> Qlora.dequantize
                        |> Eval.floats
                        |> Expect.equal (Ok [ 2, -2, 0, 0.5 ])
            ]
        , describe "B010 Infer checks the number of state tensors"
            [ test "Infer.step refuses a new state shorter than the state signature" <|
                \_ ->
                    Infer.step "run" oneVec (Sig.list 2 (Sig.label "h" vecA)) vecA (Sig.list 1 vecA) (\_ hs x -> ( List.take 1 hs, [ x, x ] ))
                        |> expectError "run: Signature.list: expected 2 values, got 1"
            , test "Infer.step refuses a new state longer than the state signature" <|
                \_ ->
                    Infer.step "run" oneVec (Sig.list 2 (Sig.label "h" vecA)) vecA vecA (\_ hs x -> ( hs ++ [ x ], x ))
                        |> expectError "run: Signature.list: expected 2 values, got 3"
            , test "Infer.initGraph refuses more values than state slots" <|
                \_ ->
                    Infer.initGraph "init" (Sig.list 2 (Sig.label "h" vecA)) (List.repeat 3 (T.zeros T.float32 (T.r1 (T.dim A 3))))
                        |> expectError "init: Signature.list: expected 2 values, got 3"
            , test "Infer.step refuses a Param.sig state whose list is too short" <|
                \_ ->
                    Infer.step "run" oneVec (Param.sig layers2) vecA vecA (\_ r x -> ( { r | layers = List.take 1 r.layers }, x ))
                        |> expectError "run: Infer: the new state has 1 tensor, but the state signature has 2 slots"
            , test "Infer.step with a matching state builds" <|
                \_ ->
                    Infer.step "run" oneVec (Sig.list 2 (Sig.label "h" vecA)) vecA vecA (\_ hs x -> ( hs, x ))
                        |> inputNames
                        |> Expect.equal [ "param", "infer.h0", "infer.h1", "arg" ]
            ]
        , describe "B014 Param checks records against the description"
            [ test "importGraph refuses a list of 3 for Param.list 2" <|
                \_ ->
                    Param.importGraph "import" layers2 (Sig.label "w" vecA) (\w -> { layers = List.repeat 3 { w = w } })
                        |> expectError "import: importGraph: a list of 2 has 3"
            , test "importGraph refuses a list of 1 for Param.list 2" <|
                \_ ->
                    Param.importGraph "import" layers2 (Sig.label "w" vecA) (\w -> { layers = [ { w = w } ] })
                        |> expectError "import: importGraph: a list of 2 has 1"
            , test "importGraph refuses a config field of another value" <|
                \_ ->
                    Param.importGraph "import" (Lora.params T.float32 { rank = T.dim C 2, alpha = 1, initStd = 0.1 } (T.dim A 3) (T.dim B 4)) (Sig.label "w" vecA) (\_ -> { a = T.zeros T.float32 (T.r2 (T.dim A 3) (T.dim C 2)), b = T.zeros T.float32 (T.r2 (T.dim C 2) (T.dim B 4)), alpha = 2, rank = 2 })
                        |> expectError "import: importGraph: a configuration field differs"
            , test "importGraph with a list of 2 builds" <|
                \_ ->
                    Param.importGraph "import" layers2 (Sig.label "w" vecA) (\w -> { layers = [ { w = w }, { w = w } ] })
                        |> inputNames
                        |> Expect.equal [ "w" ]
            , test "mapElems marks every tensor of a list of 3 for Param.list 2" <|
                \_ ->
                    Param.mapElems identity layers2 three
                        |> .layers
                        |> List.map .w
                        |> problemsOf
                        |> Expect.equal [ Just "Param: a list of 2 has 3", Just "Param: a list of 2 has 3" ]
            , test "grad marks every tensor of a list of 3 for Param.list 2" <|
                \_ ->
                    Param.grad layers2 (\r -> r.layers |> List.map (.w >> T.sumAll) |> List.foldl T.plus (T.full T.float32 0 T.scalar)) three
                        |> .layers
                        |> List.map .w
                        |> problemsOf
                        |> Expect.equal [ Just "Param: a list of 2 has 3", Just "Param: a list of 2 has 3" ]
            , test "grad of a matching record has no build error" <|
                \_ ->
                    Param.grad layers2 (\r -> r.layers |> List.map (.w >> T.sumAll) |> List.foldl T.plus (T.full T.float32 0 T.scalar)) { layers = List.take 2 three.layers }
                        |> .layers
                        |> List.map .w
                        |> problemsOf
                        |> Expect.equal [ Nothing, Nothing ]
            ]
        , describe "B031 resident names do not collide"
            [ test "names gives w0, w2, w1 for w, w, w1" <|
                \_ ->
                    Names.names "x" [ "w", "w", "w1" ]
                        |> Expect.equal [ "w0", "w2", "w1" ]
            , test "names keeps the numbering when nothing collides" <|
                \_ ->
                    Names.names "x" [ "w", "b", "w", "arg", "x" ]
                        |> Expect.equal [ "w0", "b", "w1", "x0", "x1" ]
            , test "names skips numbers taken by another repeated label's names" <|
                \_ ->
                    Names.names "x" ([ "a1", "a1" ] ++ List.repeat 11 "a")
                        |> Expect.equal ([ "a10", "a11", "a0" ] ++ List.map (\i -> "a" ++ String.fromInt i) (List.range 2 9) ++ [ "a12", "a13" ])
            , test "Train.step prefixes optimizer state and step with the first field's group" <|
                \_ ->
                    Train.step (Param.named "gen" oneVec) (Optim.adamW 0.1) vecA (\p x -> T.sumAll (T.times p x))
                        |> inputNames
                        |> Expect.equal [ "gen.param", "gen.state0", "gen.state1", "gen.step", "batch" ]
            , test "Train.initial uses the prefixed names" <|
                \_ ->
                    Train.initial (Param.named "gen" oneVec) (Optim.adamW 0.1) 1
                        |> List.map Tuple.first
                        |> Expect.equal [ "gen.param", "gen.state0", "gen.state1", "gen.step" ]
            , test "Train.step keeps unprefixed names for a description whose first field is in no group" <|
                \_ ->
                    Train.step oneVec (Optim.adamW 0.1) vecA (\p x -> T.sumAll (T.times p x))
                        |> inputNames
                        |> Expect.equal [ "param", "state0", "state1", "step", "batch" ]
            , test "Infer.step refuses a state name equal to a parameter's" <|
                \_ ->
                    Infer.step "run" (Param.named "infer" oneVec) (Sig.label "param" vecA) vecA vecA (\p h x -> ( T.plus p h, x ))
                        |> expectError "run: Infer: the state's resident name infer.param is also a parameter's"
            , test "Infer.step gives state labels w, w, w1 distinct names" <|
                \_ ->
                    Infer.step "run" oneVec (Sig.pair (Sig.pair (Sig.label "w" vecA) (Sig.label "w" vecA)) (Sig.label "w1" vecA)) vecA vecA (\_ h x -> ( h, x ))
                        |> inputNames
                        |> Expect.equal [ "param", "infer.w0", "infer.w2", "infer.w1", "arg" ]
            ]
        , describe "B032 Train.step checks the optimizer's update"
            [ test "an update giving 1 and 3 states for two parameters is refused" <|
                \_ ->
                    Train.step pairSpec
                        (Optim.custom
                            { rate = Optim.Fixed 0.1
                            , slots = 2
                            , update =
                                \_ u ->
                                    case T.shapeOf u.param of
                                        [ 3 ] ->
                                            { param = u.param, state = [ u.grad ] }

                                        _ ->
                                            { param = u.param, state = [ u.grad, u.grad, u.grad ] }
                            }
                        )
                        (Sig.pair vecA (Sig.f32 (T.r1 (T.dim B 4))))
                        (\p ( x, y ) -> T.plus (T.sumAll (T.times p.p x)) (T.sumAll (T.times p.q y)))
                        |> expectError "train_step: Train: the optimizer's update gives 1 state tensors for param0, but the optimizer keeps 2"
            , test "a new state of another shape is refused" <|
                \_ ->
                    Train.step oneVec
                        (Optim.custom { rate = Optim.Fixed 0.1, slots = 1, update = \_ u -> { param = u.param, state = [ I.Tensor (I.tensor (T.sumAll u.grad)) ] } })
                        vecA
                        (\p x -> T.sumAll (T.times p x))
                        |> expectError "train_step: Train: the optimizer's update gives state 0 of param as f32[], but it must be f32[3]"
            , test "a new parameter of another shape is refused" <|
                \_ ->
                    Train.step oneVec
                        (Optim.custom { rate = Optim.Fixed 0.1, slots = 0, update = \_ u -> { param = I.Tensor (I.tensor (T.sumAll u.param)), state = [] } })
                        vecA
                        (\p x -> T.sumAll (T.times p x))
                        |> expectError "train_step: Train: the optimizer's update gives param as f32[], but the parameter is f32[3]"
            , test "fewer than 0 slots are refused" <|
                \_ ->
                    Train.step oneVec
                        (Optim.custom { rate = Optim.Fixed 0.1, slots = -1, update = \_ u -> { param = u.param, state = [] } })
                        vecA
                        (\p x -> T.sumAll (T.times p x))
                        |> errorsOf
                        |> Expect.equal [ "train_step: the optimizer keeps -1 state slots, but it must keep 0 or more" ]
            , test "AdamW still builds" <|
                \_ ->
                    Train.step pairSpec (Optim.adamW 0.1) (Sig.pair vecA (Sig.f32 (T.r1 (T.dim B 4)))) (\p ( x, y ) -> T.plus (T.sumAll (T.times p.p x)) (T.sumAll (T.times p.q y)))
                        |> errorsOf
                        |> Expect.equal []
            ]
        , describe "B039 dropout at rate 1"
            [ test "the gradient is zero" <|
                \_ ->
                    Transform.grad (\x -> T.sumAll (Nn.dropout { rate = 1, training = True } (seedOf 1) x)) (T.fromList T.float32 (T.r1 (T.dim A 2)) [ 1, 2 ])
                        |> Eval.floats
                        |> Expect.equal (Ok [ 0, 0 ])
            , test "the result is zero" <|
                \_ ->
                    Nn.dropout { rate = 1, training = True } (seedOf 1) (T.fromList T.float32 (T.r1 (T.dim A 2)) [ 1, 2 ])
                        |> Eval.floats
                        |> Expect.equal (Ok [ 0, 0 ])
            , test "a NaN rate is a build error" <|
                \_ ->
                    Nn.dropout { rate = 0 / 0, training = True } (seedOf 1) (T.fromList T.float32 (T.r1 (T.dim A 2)) [ 1, 2 ])
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "dropout: the rate is NaN")
            ]
        , describe "B038 causalAttention"
            [ test "one query over four keys is refused" <|
                \_ ->
                    let
                        k =
                            T.ones T.float32 (T.r3 (T.dim A 1) (T.dim B 4) (T.dim C 2))

                        q =
                            T.ones T.float32 (T.r3 (T.dim A 1) (T.dim B 1) (T.dim C 2))
                    in
                    q |> Nn.causalAttention k k |> I.tensor |> E.problem |> Expect.equal (Just "causalAttention: 4 keys, but 1 queries (the causal mask is square)")
            , test "four queries over four keys build" <|
                \_ ->
                    let
                        k =
                            T.ones T.float32 (T.r3 (T.dim A 1) (T.dim B 4) (T.dim C 2))
                    in
                    k |> Nn.causalAttention k k |> I.tensor |> E.problem |> Expect.equal Nothing
            ]
        , describe "B069 nucleus"
            [ test "on f16 logits the comparison with p is made in f32" <|
                \_ ->
                    Sampling.nucleus 0.5 (T.fromList T.float16 (T.r2 (T.dim A 1) (T.dim B 3)) [ 5, 0, 0 ]) (seedOf 1)
                        |> I.tensor
                        |> f16Comparisons
                        |> Expect.equal 0
            , test "p = 0 is a build error" <|
                \_ ->
                    Sampling.nucleus 0 (T.fromList T.float32 (T.r2 (T.dim A 1) (T.dim B 3)) [ 5, 0, 0 ]) (seedOf 1)
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "nucleus: p is 0, but it must be greater than 0")
            , test "a small p on f16 logits picks the top token" <|
                \_ ->
                    List.range 1 8
                        |> List.map (\s -> Sampling.nucleus 0.001 (T.fromList T.float16 (T.r2 (T.dim A 1) (T.dim B 3)) [ 5, 0, 0 ]) (seedOf s) |> Eval.ints)
                        |> Expect.equal (List.repeat 8 (Ok [ 0 ]))
            ]
        , test "B072 Train.step refuses clipGlobalNorm -1" <|
            \_ ->
                Train.step oneVec (Optim.clipGlobalNorm -1 (Optim.sgd 0.1)) vecA (\p x -> T.sumAll (T.times p x))
                    |> errorsOf
                    |> Expect.equal [ "train_step: clipGlobalNorm's bound is -1, but it must be greater than 0" ]
        , describe "B074 Lora's rank field"
            [ test "delta refuses a rank field that differs from the factors" <|
                \_ ->
                    Lora.delta { a = T.ones T.float32 (T.r2 (T.dim A 4) (T.dim C 2)), b = T.ones T.float32 (T.r2 (T.dim C 2) (T.dim B 3)), alpha = 2, rank = 4 }
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "Lora: the rank field is 4, but A has 2 columns")
            , test "delta with a matching rank scales by alpha / rank" <|
                \_ ->
                    Lora.delta { a = T.ones T.float32 (T.r2 (T.dim A 1) (T.dim C 2)), b = T.ones T.float32 (T.r2 (T.dim C 2) (T.dim B 1)), alpha = 2, rank = 2 }
                        |> Eval.floats
                        |> Expect.equal (Ok [ 2 ])
            ]
        , describe "B057 messages"
            [ test "importGraph's slot errors start with the graph name" <|
                \_ ->
                    Param.importGraph "import" oneVec (Sig.label "w" Sig.anyTensor) (\_ -> T.zeros T.float32 (T.r1 (T.dim A 3)))
                        |> errorsOf
                        |> Expect.equal [ "import: importGraph: raw tensor w has no dtype or shape" ]
            , test "Infer's slot errors start with the graph name" <|
                \_ ->
                    Infer.step "run" oneVec Sig.anyTensor vecA vecA (\_ h x -> ( h, x ))
                        |> errorsOf
                        |> Expect.equal [ "run: Infer: state slot 0 has no dtype or shape (Signature.anyTensor cannot describe it)" ]
            , test "GroupNorm with 0 groups says so" <|
                \_ ->
                    T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim A 1) (T.dim A 1) (T.dim B 4))
                        |> GroupNorm.apply { scale = T.ones T.float32 (T.r1 (T.dim B 4)), bias = T.zeros T.float32 (T.r1 (T.dim B 4)), groups = 0, epsilon = 1.0e-5 }
                        |> I.tensor
                        |> E.problem
                        |> Expect.equal (Just "GroupNorm: 0 groups, but there must be at least 1")
            ]
        , test "B054 Stack.applyWithDropout drops as Nn.dropout does" <|
            \_ ->
                let
                    x =
                        T.fromList T.float32 (T.r2 (T.dim A 1) (T.dim B 4)) [ 1, 2, 3, 4 ]

                    w0 =
                        T.fromList T.float32 (T.r2 (T.dim B 4) (T.dim C 4)) (List.map toFloat (List.range 1 16))

                    w1 =
                        T.ones T.float32 (T.r2 (T.dim C 4) (T.dim C 2))

                    (I.ParamBuilder spec) =
                        Stack.params T.float32 (T.dim B 4) (Stack.input |> Stack.denseTo (T.dim C 4) Stack.none |> Stack.denseTo (T.dim C 2) Stack.none)

                    stack =
                        Tuple.first (spec.build [ I.tensor w0, I.tensor (T.zeros T.float32 (T.r1 (T.dim C 4))), I.tensor w1, I.tensor (T.zeros T.float32 (T.r1 (T.dim C 2))) ])

                    cfg =
                        { rate = 0.5, training = True }

                    manual =
                        x |> T.matmul w0 |> Nn.dropout cfg (Random.salt 0 (seedOf 3)) |> T.matmul w1
                in
                Expect.equal (Eval.floats manual) (Eval.floats (Stack.applyWithDropout cfg (seedOf 3) stack x))
        , describe "MODEL round 2"
            [ test "dequantize refuses too few scales of blocks of 1 with its own message" <|
                \_ ->
                    { codes = T.zeros T.uint8 (T.r2 (T.dim A 2) (T.dim B 2)), scales = T.ones T.float32 (T.r1 (Qlora.blocks 2 (T.dim A 2) (T.dim B 2))), blockSize = 1 }
                        |> Qlora.dequantize
                        |> Eval.floats
                        |> Expect.equal (Err [ "eval: Qlora.dequantize: 2 scales of blocks of 1 cover 2 elements, but the weight has 4" ])
            , test "dequantize of failed codes reports the codes' error only" <|
                \_ ->
                    { codes = I.Tensor (E.failWith "bad codes" (I.tensor (T.zeros T.uint8 (T.r2 (T.dim A 2) (T.dim B 2))))), scales = T.ones T.float32 (T.r1 (Qlora.blocks 3 (T.dim A 2) (T.dim B 2))), blockSize = 3 }
                        |> Qlora.dequantize
                        |> Eval.floats
                        |> Expect.equal (Err [ "eval: bad codes" ])
            , test "GroupNorm keeps a failed x's own error" <|
                \_ ->
                    I.Tensor (E.failWith "bad x" (I.tensor (T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim A 1) (T.dim A 1) (T.dim B 4)))))
                        |> GroupNorm.apply { scale = T.ones T.float32 (T.r1 (T.dim B 4)), bias = T.zeros T.float32 (T.r1 (T.dim B 4)), groups = 3, epsilon = 1.0e-5 }
                        |> Eval.floats
                        |> Expect.equal (Err [ "eval: bad x" ])
            , test "Rotary keeps a failed x's own error" <|
                \_ ->
                    I.Tensor (E.failWith "bad x" (I.tensor (T.zeros T.float32 (T.r3 (T.dim A 1) (T.dim B 2) (T.dim C 3)))))
                        |> Rotary.apply { base = 10000, pairing = Rotary.Halves } (T.fromList T.int64 (T.r1 (T.dim B 2)) [ 0, 1 ])
                        |> Eval.floats
                        |> Expect.equal (Err [ "eval: bad x" ])
            , test "Conv2d.apply with stride 0 is a build error" <|
                \_ ->
                    T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim B 3) (T.dim B 3) (T.dim C 1))
                        |> Conv2d.apply { stride = ( 0, 1 ), padding = noPad } (T.dim B 3) (T.dim B 3) (conv 2)
                        |> Eval.floats
                        |> Result.mapError (List.any (String.contains "the strides must be positive"))
                        |> Expect.equal (Err True)
            , test "Conv2d.apply with a kernel larger than the padded input is a build error" <|
                \_ ->
                    T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim B 3) (T.dim B 3) (T.dim C 1))
                        |> Conv2d.apply { stride = ( 1, 1 ), padding = noPad } (T.dim B 1) (T.dim B 1) (conv 4)
                        |> Eval.floats
                        |> Result.mapError (List.any (String.contains "the kernel is larger than the padded input"))
                        |> Expect.equal (Err True)
            , test "Conv2d.apply rounds a stride's division down" <|
                \_ ->
                    T.ones T.float32 (T.r4 (T.dim A 1) (T.dim B 4) (T.dim B 4) (T.dim C 1))
                        |> Conv2d.apply { stride = ( 2, 2 ), padding = noPad } (T.dim B 2) (T.dim B 2) (conv 1)
                        |> Eval.floats
                        |> Expect.equal (Ok [ 1, 1, 1, 1 ])
            , test "Conv2d.applyTransposed whose paddings remove every row is a build error" <|
                \_ ->
                    T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim B 1) (T.dim B 1) (T.dim C 1))
                        |> Conv2d.applyTransposed { stride = ( 1, 1 ), padding = { top = 1, bottom = 0, left = 0, right = 0 } } (T.dim B 0) (T.dim B 1) (conv 1)
                        |> Eval.floats
                        |> Result.mapError (List.any (String.contains "the paddings remove every row or column"))
                        |> Expect.equal (Err True)
            , test "Conv2d.applyTransposed with stride 0 is a build error" <|
                \_ ->
                    T.zeros T.float32 (T.r4 (T.dim A 1) (T.dim B 2) (T.dim B 2) (T.dim C 1))
                        |> Conv2d.applyTransposed { stride = ( 0, 0 ), padding = noPad } (T.dim B 2) (T.dim B 2) (conv 1)
                        |> Eval.floats
                        |> Result.mapError (List.any (String.contains "the strides must be positive"))
                        |> Expect.equal (Err True)
            ]
        ]


noPad : Conv2d.Padding
noPad =
    { top = 0, bottom = 0, left = 0, right = 0 }


{-| A one-channel `k × k` convolution whose filter is all ones and whose bias is zero.
-}
conv : Int -> Conv2d.Conv2d F32 C C
conv k =
    let
        ( kh, kw ) =
            Conv2d.kernel ( k, k )
    in
    { filter = T.ones T.float32 (T.r4 kh kw (T.dim C 1) (T.dim C 1)), bias = T.zeros T.float32 (T.r1 (T.dim C 1)) }
