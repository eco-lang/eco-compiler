module Round2Tests exposing (suite)

{-| Graphs share buffers by name. A _resident_ input or output is a buffer that whatever runs the
graph keeps between runs, under its resident name, while a _fed_ one is given or handed back with
every run (`Graph.Role`). `Train.step`, `Infer.step`, `Param.initInPlace` and `Param.importGraph`
share a parameter's buffer only because each uses the field's resident name from `Param.names`, and
a graph whose names or roles are wrong still builds. These tests pin the names and roles those
graphs give. They also check what `Max` writes for the CPU and for a GPU, and a set of build
errors and op counts for operations and layers.

The fixture is three axis tags, `A`, `B` and `C`, whose usual sizes are 3, 4 and 2 (`a`, `b`, `c`),
and `K` for the axis of a top-k's results. `two` describes two dense layers, `A` to `B` and `B` to
`C`, each with a trainable weight and bias and so four trainable fields; `twoNamed` is the same with
the first layer under `Param.named "first"`; `biasless` is one layer from `A` to `B` made by
`Linear.paramsWithoutBias`. `rawSig` describes four raw tensors labelled `w1`, `b1`, `w2` and `b2`,
whose weights are laid out output by input, the transpose of a `Linear` weight. The tests on
devices and on operations build their graphs, each with one output, by `Graph.function`.

The tests on devices establish:

  - A graph that permutes, takes `sin` and pads builds, and `toGenericTextOn Cpu` gives `Ok` of the
    text `toGenericText` gives.
  - Placed for GPU 0, a graph that permutes, scales and pads an `f32 [3, 4, 2]` input writes, as
    the operand and result types of its ops: for `rmo.mo.transpose`, the input with `gpu:0` and
    the `si64 [3]` permutation with no device; for `rmo.mul`, the permuted tensor and the `f32`
    rank-0 factor, both with `gpu:0`; and for `rmo.mo.pad.constant`, the scaled tensor with `gpu:0`,
    and the `si64 [6]` paddings and the `f32` rank-0 fill value with no device.
  - A top-k along the middle axis of three is written for the CPU, and for a GPU is refused with
    one message, which says only the last axis is supported.
  - A `cond` is refused for a GPU with one message, which says MAX needs the predicate on the CPU.
  - `acos` placed for GPU 0 writes `#M.device_ref<"gpu", 0>`.

The tests on operations and layers establish, on the CPU's generic text where they count ops (an
op is counted by its quoted name at the start of its line, after any `%n =`):

  - A top-k keeping 9 along an axis of size 4 is refused with "k = 9 but axis 1 has size 4".
  - A graph using both the values and the indices of one top-k holds one `rmo.top_k` op.
  - An ascending `sort` holds one `rmo.mo.bottom_k` op.
  - Differentiating the sum of a top-k's values is refused with "topK: cannot be differentiated".
  - `put` along the middle axis of a rank-3 tensor holds one `rmo.mo.scatter` op, and the text
    `transpose` nowhere.
  - `Nn.repeatHeads` to 3 heads from 2, `GroupNorm` with 3 groups over 4 channels, `Rotary` on a
    head of 3 features, and `upsampleNearest2d` by 2 from 3 × 3 to a declared 6 × 5 are each refused
    with an error naming those sizes.
  - `Nn.causalAttention` over an `f16` tensor builds.

The tests on resident names and roles establish:

  - `Param.names` gives `param0` to `param3` for `two`, and `first.param0`, `first.param1`,
    `param0`, `param1` for `twoNamed`. The named layer alone has the names it has in `twoNamed`,
    and `Param.named "outer" twoNamed` gives `outer.` names to the second layer only.
  - The first four inputs of `Train.step` over `twoNamed` are named as `Param.names` names its
    fields.
  - `biasless` has the one name `param` and a `Param.count` of 1, and its `Train.step` with
    `Optim.sgd 0.1` has exactly the inputs `param` and `batch`.
  - `Param.initInPlace` over `twoNamed` gives its four outputs resident roles under `twoNamed`'s
    names, in field order, and `Param.initGraph` over `two` gives all four outputs the fed role.
  - `Infer.step` over `two`, with a state labelled `h` and an input pair whose second tensor is a
    scalar, has exactly the inputs `param0` to `param3` and `infer.h`, each resident under its own
    name, then `arg0` and `arg1`, fed; the scalar input is declared `[1]`; and its outputs' roles
    are resident under `infer.h`, then fed.
  - `Infer.step` refuses a new state of another size with "Infer: state infer.h changes from
    f32[4] to f32[8]".
  - `Infer.initGraph` for two state slots labelled `keys` has no inputs, and its outputs are
    resident under `infer.keys0` and `infer.keys1`.
  - `Param.importGraph` over `twoNamed` from `rawSig` has the inputs `w1`, `b1`, `w2`, `b2`, each
    resident under its own name, and outputs resident under `twoNamed`'s four names.
  - `Param.importGraph` over one `Linear.params` layer refuses a converted weight of `f32 [3, 5]`
    for a field of `f32 [3, 4]`, with an error naming the field `param0` and both shapes.

Among what is not tested: running any graph, by MAX or by `Tensor.Eval`, so nothing checks that a
resident output reaches the buffer another graph's input reads; bytecode, as every device test reads
generic text; `whileLoop` on a GPU; the names and roles of `Train.step`'s state, step counter and
outputs, and the roles of its inputs; the names of `Infer.step`'s and `Param.initInPlace`'s outputs;
frozen and data fields; and the values `Param.initInPlace` writes.

-}

import Expect
import Graph
import Infer
import Max
import Nn
import Nn.GroupNorm as GroupNorm
import Nn.Linear as Linear exposing (Linear)
import Nn.Rotary as Rotary
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Test exposing (Test, describe, test)
import Train
import Transform


{-| An axis tag of the fixture, whose usual size is `a`.
-}
type A
    = A


{-| An axis tag of the fixture, whose usual size is `b`.
-}
type B
    = B


{-| An axis tag of the fixture, whose usual size is `c`.
-}
type C
    = C


{-| The size the fixture gives an `A` axis wherever a test does not make one with `T.dim`.
-}
a : Dim A
a =
    T.dim A 3


{-| The size the fixture gives a `B` axis wherever a test does not make one with `T.dim`.
-}
b : Dim B
b =
    T.dim B 4


{-| The size the fixture gives a `C` axis wherever a test does not make one with `T.dim`.
-}
c : Dim C
c =
    T.dim C 2


{-| Returns an expectation that passes when the build was refused with at least one error
containing `fragment`, and otherwise fails, quoting the errors or saying the graph was built.
-}
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


{-| Returns `check` applied to the built graph, or a failure quoting the errors when the build
was refused.
-}
expectGraph : (Graph.Graph -> Expect.Expectation) -> Result (List String) Graph.Graph -> Expect.Expectation
expectGraph check r =
    case r of
        Ok g ->
            check g

        Err e ->
            Expect.fail ("not built: " ++ String.join " | " e)


{-| Pairs each spec's name with its role.
-}
roles : List Graph.Spec -> List ( String, Graph.Role )
roles =
    List.map (\s -> ( s.name, s.role ))


{-| Two dense layers in sequence, from `A` to `B` and from `B` to `C`.
-}
type alias Two =
    { l1 : Linear F32 A B, l2 : Linear F32 B C }


{-| The description of `Two` by `Linear.params`, with no `named` part: four trainable fields,
each layer's weight and then its bias.
-}
two : Param.Spec Two
two =
    Param.record Two
        |> Param.sub .l1 (Linear.params T.float32 a b)
        |> Param.sub .l2 (Linear.params T.float32 b c)


{-| The description `two` with the first layer under `Param.named "first"`.
-}
twoNamed : Param.Spec Two
twoNamed =
    Param.record Two
        |> Param.sub .l1 (Param.named "first" (Linear.params T.float32 a b))
        |> Param.sub .l2 (Linear.params T.float32 b c)


{-| One dense layer, from `A` to `B`.
-}
type alias Biasless =
    { l : Linear F32 A B }


{-| The description of `Biasless` by `Linear.paramsWithoutBias`, whose one tensor field is the
weight.
-}
biasless : Param.Spec Biasless
biasless =
    Param.record Biasless |> Param.sub .l (Linear.paramsWithoutBias T.float32 a b)


{-| Applies the first layer of `p` to `x`, then `relu`, then the second layer.
-}
net : Two -> Tensor Float F32 (R2 n A) -> Tensor Float F32 (R2 n C)
net p x =
    x |> Linear.apply p.l1 |> T.relu |> Linear.apply p.l2


{-| The weights and biases of two dense layers as raw tensors, each weight laid out output by
input, the transpose of the `(in, out)` weight a `Linear` holds.
-}
type alias Raw =
    { w1 : Tensor Float F32 (R2 B A), b1 : Tensor Float F32 (R1 B), w2 : Tensor Float F32 (R2 C B), b2 : Tensor Float F32 (R1 C) }


{-| The signature of `Raw`, each slot labelled with its field's name.
-}
rawSig : Sig.Sig Raw
rawSig =
    Sig.record Raw
        |> Sig.field .w1 (Sig.label "w1" (Sig.f32 (T.r2 b a)))
        |> Sig.field .b1 (Sig.label "b1" (Sig.f32 (T.r1 b)))
        |> Sig.field .w2 (Sig.label "w2" (Sig.f32 (T.r2 c b)))
        |> Sig.field .b2 (Sig.label "b2" (Sig.f32 (T.r1 c)))


{-| An axis tag for the axis of a top-k's results.
-}
type K
    = K


{-| Returns the name of every op in the generic op text `text`, in order: on each line that, after
its indentation and any `%n =` result, starts with a quoted name, that name without its quotes.
-}
opNames : String -> List String
opNames text =
    String.lines text
        |> List.filterMap
            (\line ->
                let
                    t =
                        String.trimLeft line

                    afterResults =
                        if String.startsWith "%" t then
                            case String.indexes " = " t of
                                i :: _ ->
                                    String.dropLeft (i + 3) t

                                [] ->
                                    t

                        else
                            t
                in
                if String.startsWith "\"" afterResults then
                    String.dropLeft 1 afterResults |> String.split "\"" |> List.head

                else
                    Nothing
            )


{-| Returns how many ops of the generic op text `text` are named `name`.
-}
count : String -> String -> Int
count name text =
    List.length (List.filter ((==) name) (opNames text))


{-| Returns the line of the generic op text `text` holding the first op named `name`, trimmed, or
an empty string when no op has that name.
-}
opLine : String -> String -> String
opLine name text =
    String.lines text
        |> List.map String.trim
        |> List.filter (String.contains ("\"" ++ name ++ "\"("))
        |> List.head
        |> Maybe.withDefault ""


{-| Returns the built graph's generic op text for the CPU, or, when the build was refused, its
errors after `ERRORS:`.
-}
textOf : Result (List String) Graph.Graph -> String
textOf r =
    case r of
        Ok g ->
            Max.toGenericText g

        Err e ->
            "ERRORS: " ++ String.join " | " e


{-| Returns the built graph's generic op text placed for GPU 0, or the errors of the build or of
the placement.
-}
onGpu : Result (List String) Graph.Graph -> Result (List String) String
onGpu r =
    r |> Result.andThen (Max.toGenericTextOn (Max.Gpu 0))


{-| The tests the module docstring lists, grouped by subject.
-}
suite : Test
suite =
    describe "round 2"
        [ describe "devices"
            [ test "written for the CPU, a graph is what toGenericText writes" <|
                \_ ->
                    Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> x |> T.permute Axis.swap01of3 |> T.sin |> T.pad Axis.retag0of3 { before = 1, after = 0, value = 0.5 } (T.dim B 5))
                        |> expectGraph (\g -> Expect.equal (Ok (Max.toGenericText g)) (Max.toGenericTextOn Max.Cpu g))
            , test "on a GPU, data on the device, the permutation and paddings on the host" <|
                \_ ->
                    case onGpu (Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> x |> T.permute Axis.swap01of3 |> T.scale 2 |> T.pad Axis.retag0of3 { before = 1, after = 0, value = 0.5 } (T.dim B 5))) of
                        Ok text ->
                            Expect.equal
                                [ "(!mo.tensor<[3, 4, 2], f32, gpu:0>, !mo.tensor<[3], si64>) -> !mo.tensor<[4, 3, 2], f32, gpu:0>"
                                , "(!mo.tensor<[4, 3, 2], f32, gpu:0>, !mo.tensor<[], f32, gpu:0>) -> !mo.tensor<[4, 3, 2], f32, gpu:0>"
                                , "(!mo.tensor<[4, 3, 2], f32, gpu:0>, !mo.tensor<[6], si64>, !mo.tensor<[], f32>) -> !mo.tensor<[5, 3, 2], f32, gpu:0>"
                                ]
                                (List.map (\op -> opLine op text |> String.split " : " |> List.drop 1 |> String.join " : ") [ "rmo.mo.transpose", "rmo.mul", "rmo.mo.pad.constant" ])

                        Err e ->
                            Expect.fail (String.join " | " e)
            , test "topK off the last axis is refused on a GPU, not on the CPU" <|
                \_ ->
                    let
                        g =
                            Graph.function "g" (Sig.f32 (T.r3 a b c)) (\x -> T.topK Axis.retag1of3 (T.dim K 2) x |> Tuple.first)
                    in
                    Expect.equal ( True, True )
                        ( Result.map (always ()) (g |> Result.andThen (Max.toGenericTextOn Max.Cpu)) == Ok ()
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
                        |> (\t -> Expect.equal ( 1, 0 ) ( count "rmo.mo.scatter" t, List.length (String.indexes "transpose" t) ))
            , test "repeatHeads needs a multiple" <|
                \_ -> expectError "repeatHeads: 3 heads are not a multiple of 2 key/value heads" (Graph.function "g" (Sig.f32 (T.r3 c a b)) (Nn.repeatHeads (T.dim A 3)))
            , test "GroupNorm needs groups that divide the channels" <|
                \_ -> expectError "GroupNorm: 3 groups do not divide 4 channels" (Graph.function "g" (Sig.f32 (T.r4 c a a b)) (GroupNorm.apply { scale = T.zeros T.float32 (T.r1 b), bias = T.zeros T.float32 (T.r1 b), groups = 3, epsilon = 1.0e-5 }))
            , test "rotary needs an even head" <|
                \_ -> expectError "Rotary: a head of 3 features has no pairs" (Graph.function "g" (Sig.f32 (T.r3 c b a)) (Rotary.apply { base = 10000, pairing = Rotary.Halves } (T.iota b)))
            , test "upsampling checks its result's size" <|
                \_ -> expectError "upsampleNearest2d: 3 × 3 by 2 is not 6 × 5" (Graph.function "g" (Sig.f32 (T.r4 c a a b)) (Nn.upsampleNearest2d 2 (T.dim A 6) (T.dim C 5)))
            , test "attention builds in f16" <|
                \_ -> Graph.function "g" (Sig.tensor T.float16 (T.r3 c a b)) (\q -> q |> Nn.causalAttention q q) |> expectGraph (\_ -> Expect.pass)
            ]
        , describe "resident names"
            [ test "unnamed specs are numbered param0 to param3" <|
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
            , test "initGraph gives every output the fed role" <|
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
                    Infer.step "run" two (Sig.label "h" (Sig.f32 (T.r1 b))) (Sig.f32 (T.r1 b)) (Sig.f32 (T.r1 b)) (\_ h x -> ( T.concat Axis.retag0of1 (T.dim B 8) [ h, x ], x ))
                        |> expectError "Infer: state infer.h changes from f32[4] to f32[8]"
            , test "initGraph has no inputs and resident state outputs" <|
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
