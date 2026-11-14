module TensorTests exposing (suite)

{-| Tests of what the package does without running a graph: the errors `Graph.build` reports,
the keys that identify expressions, the names it gives a graph's inputs and outputs, the bytes
prepared as the first contents of resident buffers (`Param`), the axis witnesses of `Tensor.Axis`,
`Check.allClose`'s tolerance rule, and the MLIR text `Max` writes. Most of these never
appear in a value a graph computes, so they need tests of their own.

`Graph.build` returns either a graph or the list of what it found wrong; `Graph` states what it
refuses. A _key_ is the structural hash that serves as an expression's identity
(`Tensor.Internal.Key`). A _broadcast axis_ is a size-1 axis whose size is not yet known, made here
by `T.rows`; `Tensor` states where one takes a size and where it is refused.

The fixture is three axis tags, `A`, `B` and `C`, with the sizes 3, 4 and 5 in `a`, `b` and `c`, and
`f34`, a signature for one f32 tensor of shape [3, 4]. Most tests that build a graph name it `g`,
and most use `Graph.function`, which names the graph's one output `result`. Most tests that expect
a refusal go through `expectError`, which looks for a fragment of a message in any of the errors.

The tests establish:

  - A reshape of [3, 4] to [5, 3] is refused with both shapes and the source's element count in
    the message. A broadcast axis is refused by a reduction (`has no size here`), builds with no
    error when added by `T.plus` to a [3, 4] partner and then summed over that axis, and is refused
    at an output with a message naming `result`. `T.plus` of [3, 4] and [3, 5] is refused with both
    shapes in the message.
  - Size checks. A `T.concat` whose `Dim` says 7 for a result of 6, a `T.stack` of two tensors
    whose `Dim` says 3, `T.chunks` of 3 along an axis of 4, and a slice of 3 from position 2 of an
    axis of 4 are each refused with their own message.
  - `T.negate` of a `ui8` input is refused (`negate: MAX does not compile this for ui8 tensors`).
  - Two different failing reshapes, one of them written twice, with additions and a transpose
    built on them, give exactly two errors.
  - An input signature of `Sig.anyTensor` is refused (`has no shape`), and a graph `second` that
    reads an input made for a graph `first` is refused (`input of graph`).
  - Keys. Two separately built `T.relu (T.float 2)` have equal keys; the constants 2 and 3 have
    different keys, and so do a subtraction and the same subtraction with its operands swapped.
    `K.mixFloat` gives different keys for 0 and −0, and equal keys for NaN (`0 / 0`) mixed twice,
    although `NaN /= NaN`.
  - Signatures. As a graph's input, a record signature whose `Sig.field` accessors are in the
    opposite order to the record constructor's arguments is refused
    (`does not give back what it builds`), and so is `Sig.map T.relu T.exp`, whose second function
    does not undo the first. With `Param.sig` of a layer-norm description as both input and
    output, a body that changes the `epsilon` config field is refused
    (`configuration field differs`). Inputs labelled `w`, `x`, `x` and an output labelled `y` are
    named `w`, `x0`, `x1` and `y`.
  - Parameters of `Linear.params T.float32 a b`, a weight [3, 4] and a bias [4]. `Param.initial`
    gives `param0` with 48 bytes, then `param1` with 16. `Train.initialFrom` with `Optim.adamW 0.1`,
    given those entries in reverse order, returns `param0` with 48 bytes, `param1` with 16, `state0`
    to `state3` with 48, 48, 16 and 16, and `step` with 4; given only `param0` it fails with
    `no tensor for param1`; given 48 bytes under each name it fails with
    `param1: 48 bytes, but its dtype and shape take 16`. `Param.sig` names the inputs `param0` and
    `param1`.
  - Axis witnesses. `Axis.last2` is axis 1, `Axis.axis2of5` is axis 2, and `Axis.swap13of4` is the
    one swap of axes 1 and 3.
  - `Transform.grad` of a function through a `Control.whileLoop` on its argument is refused
    (`a loop cannot be differentiated`), and a shared function whose body reads a graph input it was
    not given is refused (`a shared function reads a tensor that is not one of its arguments`).
  - `Transform.vmap` of `T.sin` over the leading axis of a [3, 4] input writes generic text
    (`Max.toGenericText`) with exactly one `rmo.mo.sin` and no `rmo.slice`.
  - A `Control.cond`, then a `Control.whileLoop` on its result, then a call of a shared function
    on the loop's result, writes generic text with exactly one each of `mo.if`, `mo.while`,
    `mo.call` and `isSubgraph`.
  - `Qlora.quantize` with blocks of 2 gives, for [0.5, −1, 0, 0.25], the codes 12, 0, 7 and 15 in
    one byte each, and the scales 1 and 0.25 as little-endian f32.
  - `Param.initial` with seed 7 of a 4000-element f32 field drawn by `Param.normal 0.5` has a mean
    within 0.03 of 0 and a standard deviation within 0.03 of 0.5.
  - `Check.allClose` with `rtol` 1e-3 and `atol` 0 accepts [1, 2.001] against [1, 2], and refuses
    [1, 2.1] with `1 element differs; first at 1: 2.1 vs 2`.
  - Lowering. For a [3, 4] input through `T.relu` and a sum over the last axis, the generic text
    contains `rmo.mo.relu`, `rmo.mo.reduce.add`, `{axis = 1 : index}` and
    `newShape = #mosh<ape[3]>`. For `T.softmax` over the last axis of a rank-3 input it contains
    `{axis = 2 : index}` and not `axis = -`.

Among what is not tested:

  - Element values computed by MAX or by `Tensor.Eval`: no test runs a graph.
  - In the tests that use `expectError`, the rest of each message besides the fragment, and
    whether other errors come with it.
  - The contents of the entries `Train.initialFrom` returns: only their names and lengths are
    compared.
  - Bytecode (`Max.toBytecode`), placement for a GPU, and a `cond` or `whileLoop` nested in
    another.

-}

import Bytes
import Bytes.Decode as Decode
import Bytes.Encode
import Expect
import Finetune.Qlora as Qlora
import Graph
import Max
import Nn.LayerNorm as LayerNorm
import Nn.Linear as Linear
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F32, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Check as Check
import Tensor.Control as Control
import Tensor.Internal.Expr as E
import Tensor.Internal.Key as K
import Tensor.Internal.Prim
import Tensor.Internal.Types as I
import Test exposing (Test, describe, test)
import Train
import Transform


{-| An axis tag, the first axis of `f34`.
-}
type A
    = A


{-| An axis tag, the second axis of `f34` and the axis of every rank-1 graph input.
-}
type B
    = B


{-| An axis tag for a third axis: the axis the reshapes, concatenation, chunks and slices
produce, and the last axis of the rank-3 input.
-}
type C
    = C


{-| The fixture's size for axis `A`.
-}
a : Dim A
a =
    T.dim A 3


{-| The fixture's size for axis `B`.
-}
b : Dim B
b =
    T.dim B 4


{-| The fixture's size for axis `C`.
-}
c : Dim C
c =
    T.dim C 5


{-| Returns the errors in `r`, or none when the graph was built.
-}
errorsOf : Result (List String) Graph.Graph -> List String
errorsOf r =
    case r of
        Err e ->
            e

        Ok _ ->
            []


{-| Expects `r` to be a built graph. When the build was refused, the test fails with a message
listing the errors.
-}
expectBuilt : Result (List String) Graph.Graph -> Expect.Expectation
expectBuilt r =
    case r of
        Ok _ ->
            Expect.pass

        Err e ->
            Expect.fail ("not built: " ++ String.join " | " e)


{-| Expects `r` to be refused with at least one error containing `fragment`. When the graph builds,
the test fails saying so; when no error contains `fragment`, it fails with a message listing the
errors.
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


{-| A signature for one f32 tensor of shape `A` × `B`, which is [3, 4].
-}
f34 : Sig.Sig (Tensor Float F32 (R2 A B))
f34 =
    Sig.f32 (T.r2 a b)


{-| A record of two tensors of one type. Because the fields share a type, a record signature that
reads them in the wrong order still compiles; as a graph's input, the round trip `Graph.build`
checks refuses it.
-}
type alias Pair =
    { gain : Tensor Float F32 (R1 B), bias : Tensor Float F32 (R1 B) }


{-| The tests the module docstring lists.
-}
suite : Test
suite =
    describe "tensor"
        [ describe "shape rules"
            [ test "a reshape must keep the element count" <|
                \_ -> expectError "cannot reshape [3, 4] (12 elements) to [5, 3]" (Graph.function "g" f34 (T.reshape (T.r2 c a)))
            , test "a broadcast axis cannot reach a reduction" <|
                \_ -> expectError "has no size here" (Graph.function "g" (Sig.f32 (T.r1 b)) (\v -> T.rows v |> T.sum Axis.axis0of2 |> asB))
            , test "a broadcast axis resolves in an element-wise operation" <|
                \_ -> expectBuilt (Graph.function "g" (Sig.pair f34 (Sig.f32 (T.r1 b))) (\( x, v ) -> x |> T.plus (T.rows v) |> T.sum Axis.axis0of2))
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
                \_ -> expectError "input of graph" (Graph.function "second" f34 (\x -> x |> T.plus (foreign ())))
            ]
        , describe "keys"
            [ test "equal expressions get equal keys" <|
                \_ -> Expect.equal (E.key (I.tensor (T.relu (T.float 2)))) (E.key (I.tensor (T.relu (T.float 2))))
            , test "different constants get different keys" <|
                \_ -> Expect.notEqual (E.key (I.tensor (T.float 2))) (E.key (I.tensor (T.float 3)))
            , test "-0 and 0 differ" <|
                \_ -> Expect.notEqual (K.mixFloat 0 ( 1, 1 )) (K.mixFloat (negate 0) ( 1, 1 ))
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
            [ test "initial values: one tensor per field, by resident name, each its dtype × shape in bytes" <|
                \_ ->
                    Expect.equal [ ( "param0", 3 * 4 * 4 ), ( "param1", 4 * 4 ) ]
                        (List.map (Tuple.mapSecond Bytes.width) (Param.initial (Linear.params T.float32 a b) 42))
            , test "initialFrom takes the parameters by name, checks their sizes, and adds the optimizer state" <|
                \_ ->
                    let
                        spec =
                            Linear.params T.float32 a b

                        given =
                            Param.initial spec 42
                    in
                    Expect.equal
                        ( Result.map (List.map (Tuple.mapSecond Bytes.width)) (Train.initialFrom spec (Optim.adamW 0.1) (List.reverse given))
                        , Train.initialFrom spec (Optim.adamW 0.1) (List.take 1 given) |> Result.map (\_ -> ())
                        , Train.initialFrom spec (Optim.adamW 0.1) (List.map (Tuple.mapSecond (\_ -> Param.initial spec 1 |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault given0)) given) |> Result.map (\_ -> ())
                        )
                        ( Ok [ ( "param0", 48 ), ( "param1", 16 ), ( "state0", 48 ), ( "state1", 48 ), ( "state2", 16 ), ( "state3", 16 ), ( "step", 4 ) ]
                        , Err "no tensor for param1"
                        , Err "param1: 48 bytes, but its dtype and shape take 16"
                        )
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
                            Expect.equal ( 1, 0 ) ( occurrences "\"rmo.mo.sin\"" (Max.toGenericText g), occurrences "\"rmo.slice\"" (Max.toGenericText g) )

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
                            Expect.equal [ 1, 1, 1, 1 ] (List.map (\op -> occurrences op (Max.toGenericText g)) [ "\"mo.if\"", "\"mo.while\"", "\"mo.call\"", "isSubgraph" ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        , describe "preparing values"
            [ test "QLoRA quantises to the nearest NF4 code, per block scaled by its largest magnitude" <|
                \_ ->
                    case Qlora.quantize T.float32 2 (T.dim A 2) (T.dim B 2) [ 0.5, -1, 0, 0.25 ] of
                        Ok q ->
                            Expect.equal
                                ( Decode.decode (Decode.map4 (\w x y z -> [ w, x, y, z ]) Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8 Decode.unsignedInt8) q.codes
                                , Decode.decode (Decode.map2 (\p r -> [ p, r ]) (Decode.float32 Bytes.LE) (Decode.float32 Bytes.LE)) q.scales
                                , ( Bytes.width q.codes, Bytes.width q.scales )
                                )
                                ( Just [ 12, 0, 7, 15 ], Just [ 1, 0.25 ], ( 4, 8 ) )

                        Err e ->
                            Expect.fail e
            , test "normal initialisation has the requested spread" <|
                \_ ->
                    let
                        spec =
                            Param.record identity |> Param.normal 0.5 identity T.float32 (T.r1 (T.dim A 4000))

                        values =
                            Decode.decode
                                (Decode.loop ( 4000, [] )
                                    (\( n, acc ) ->
                                        if n == 0 then
                                            Decode.succeed (Decode.Done acc)

                                        else
                                            Decode.map (\v -> Decode.Loop ( n - 1, v :: acc )) (Decode.float32 Bytes.LE)
                                    )
                                )
                                (Param.initial spec 7 |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault given0)
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
                \_ -> Expect.equal (Err "1 element differs; first at 1: 2.1 vs 2") (Check.allClose { rtol = 1.0e-3, atol = 0 } [ 1, 2.1 ] [ 1, 2 ])
            ]
        , describe "lowering"
            [ test "a small graph's generic text" <|
                \_ ->
                    case Graph.function "f" f34 (\x -> x |> T.relu |> T.sum Axis.last2) of
                        Ok g ->
                            Expect.equal
                                [ "\"rmo.mo.relu\"", "\"rmo.mo.reduce.add\"", "{axis = 1 : index}", "newShape = #mosh<ape[3]>" ]
                                (List.filter (\s -> String.contains s (Max.toGenericText g)) [ "\"rmo.mo.relu\"", "\"rmo.mo.reduce.add\"", "{axis = 1 : index}", "newShape = #mosh<ape[3]>" ])

                        Err e ->
                            Expect.fail (String.join "; " e)
            , test "a negative axis is never written" <|
                \_ ->
                    case Graph.function "f" (Sig.f32 (T.r3 a b c)) (T.softmax Axis.last3) of
                        Ok g ->
                            Expect.equal ( True, False ) ( String.contains "{axis = 2 : index}" (Max.toGenericText g), String.contains "axis = -" (Max.toGenericText g) )

                        Err e ->
                            Expect.fail (String.join "; " e)
            ]
        ]


{-| Returns the tensor a graph named `first` built over `f34` has as its input, made directly so
that a graph of another name can read it.
-}
foreign : () -> Tensor Float F32 (R2 A B)
foreign _ =
    I.Tensor (E.input "first" 0 Tensor.Internal.Prim.F32 [ 3, 4 ])


{-| Returns its argument unchanged, fixing its type to a rank-1 f32 tensor along `B`.
-}
asB : Tensor Float F32 (R1 B) -> Tensor Float F32 (R1 B)
asB =
    identity


{-| Returns its argument unchanged, fixing its type to an f32 tensor of shape `A` × `B`.
-}
asAB : Tensor Float F32 (R2 A B) -> Tensor Float F32 (R2 A B)
asAB =
    identity


{-| Returns how many times `needle` occurs in `hay`.
-}
occurrences : String -> String -> Int
occurrences needle hay =
    List.length (String.indexes needle hay)


{-| Empty bytes, the default where a test takes the first entry of a list that should not be
empty. A test that falls back to it fails.
-}
given0 : Bytes.Bytes
given0 =
    Bytes.Encode.encode (Bytes.Encode.sequence [])
