module FixLOWTests exposing (suite)

{-| Regression tests for the round-2 LOW fixes: lowering for MAX and graph building (Graph,
Max, Signature, Tensor.Internal.Lower, Mo, Ir, Device, Shared).
-}

import Expect exposing (Expectation)
import Graph
import Max
import Signature as Sig
import Tensor as T
import Tensor.Axis as Axis
import Tensor.Control as Control
import Tensor.Internal.Expr as E
import Tensor.Internal.Lower as Lower
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Mo as Mo
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I
import Tensor.Internal.Values exposing (Values(..))
import Test exposing (Test, describe, test)
import Transform


type B
    = B


type A
    = A


type K
    = K


three =
    T.dim B 3


four =
    T.dim B 4


vec3 =
    Sig.f32 (T.r1 three)


vec4 =
    Sig.f32 (T.r1 four)


{-| Passes when building failed with a message containing `needle`.
-}
expectError : String -> Result (List String) Graph.Graph -> Expectation
expectError needle r =
    case r of
        Ok _ ->
            Expect.fail ("built, but expected an error containing " ++ needle)

        Err es ->
            if List.any (String.contains needle) es then
                Expect.pass

            else
                Expect.fail ("no error containing " ++ needle ++ " in: " ++ String.join " | " es)


{-| The output specs' shapes, or the errors.
-}
outShapes : Result (List String) Graph.Graph -> Result (List String) (List (List Int))
outShapes =
    Result.map (Graph.outputs >> List.map .shape)


{-| A one-slot signature like `s`, but with the slot's dtype and shape replaced.
-}
declaring : Maybe P.DT -> Maybe (List Int) -> Sig.Sig a -> Sig.Sig a
declaring dt sh (I.SigBuilder s) =
    I.SigBuilder { s | slots = List.map (\sl -> { sl | dtype = dt, shape = sh }) s.slots }


{-| The signature `s` with every slot resident under `n`.
-}
resident : String -> Sig.Sig a -> Sig.Sig a
resident n (I.SigBuilder s) =
    I.SigBuilder { s | slots = List.map (\sl -> { sl | role = I.Resident n }) s.slots }


suite : Test
suite =
    describe "FixLOW"
        [ describe "B043 an operand that names no value is caught"
            [ test "an output read from an input of another graph lowers to an operand that names no value" <|
                \_ ->
                    let
                        stray =
                            I.Tensor (E.input "h" 0 P.F32 [ 3 ])

                        ops =
                            Lower.graph "g" [] [ ( "result", I.tensor (T.relu stray) ) ]
                    in
                    Expect.notEqual [] (Ir.unboundOperands ops)
            , test "a cond in a cond branch reading the graph input has every operand bound" <|
                \_ ->
                    let
                        positive x =
                            T.sumAll x |> T.greaterThan (T.float 0)

                        nested x =
                            Control.cond (positive x)
                                Sig.anyTensor
                                Sig.anyTensor
                                (\y -> Control.cond (T.sumAll y |> T.greaterThan (T.float 1)) Sig.anyTensor Sig.anyTensor (\z -> T.plus z x) T.negate y)
                                T.negate
                                x
                    in
                    case Graph.function "g" vec3 nested of
                        Ok (I.Graph gr) ->
                            Expect.equal [] (Ir.unboundOperands gr.ops)

                        Err e ->
                            Expect.fail (String.join " | " e)
            ]
        , describe "B018 an eager shared function checks its arguments"
            [ test "an argument of another shape is refused" <|
                \_ ->
                    let
                        sq =
                            Transform.shared "sq" vec3 vec3 (\x -> T.times x x)
                    in
                    expectError "shared sq: argument 0 is f32[4], the signature says f32[3]"
                        (Graph.function "g" vec4 (\x -> Transform.call sq x))
            , test "an argument of the declared shape builds" <|
                \_ ->
                    let
                        sq =
                            Transform.shared "sq" vec3 vec3 (\x -> T.times x x)
                    in
                    Expect.equal (Ok [ [ 3 ] ]) (outShapes (Graph.function "g" vec3 (\x -> Transform.call sq x)))
            ]
        , describe "B029 output signatures are checked"
            [ test "Graph.build refuses an output whose shape is not the declared one" <|
                \_ ->
                    expectError "output 0 (result) is f32[4], its signature says f32[3]" (Graph.build "g" vec4 vec3 identity)
            , test "Graph.build refuses an output whose dtype is not the declared one" <|
                \_ ->
                    expectError "is f32[4], its signature says f64[4]" (Graph.build "g" vec4 (declaring (Just P.F64) (Just [ 4 ]) vec4) identity)
            , test "an output signature that declares nothing accepts any result" <|
                \_ ->
                    Expect.equal (Ok [ [ 4 ] ]) (outShapes (Graph.function "g" vec4 T.relu))
            , test "a shared function refuses a result whose shape is not its declared one" <|
                \_ ->
                    let
                        f =
                            Transform.shared "f" vec4 vec3 identity
                    in
                    expectError "shared f: result 0 is f32[4], the signature says f32[3]"
                        (Graph.function "g" vec4 (\x -> Transform.call f x))
            ]
        , describe "B013 Signature.list and one never shift tensors"
            [ test "lists of the wrong lengths are refused, naming Signature.list" <|
                \_ ->
                    expectError "Signature.list: expected 2 values, got 1"
                        (Graph.build "g" vec3 (Sig.pair (Sig.list 2 vec3) (Sig.list 2 vec3)) (\x -> ( [ x ], [ x, x, x ] )))
            , test "a list one too long is refused" <|
                \_ ->
                    expectError "Signature.list: expected 2 values, got 3"
                        (Graph.build "g" vec3 (Sig.list 2 vec3) (\x -> [ x, x, x ]))
            , test "a list of the right length builds" <|
                \_ ->
                    Expect.equal (Ok [ [ 3 ], [ 3 ] ]) (outShapes (Graph.build "g" vec3 (Sig.list 2 vec3) (\x -> [ x, T.relu x ])))
            , test "a slot with no tensor left builds a failed tensor" <|
                \_ ->
                    case vec3 of
                        I.SigBuilder s ->
                            Expect.equal True (s.build [] |> Tuple.first |> I.tensor |> E.poisoned)
            ]
        , describe "B035 a shared function keeps an argument's broadcast axis"
            [ test "traced on the arguments" <|
                \_ ->
                    let
                        f =
                            Transform.shared "f" Sig.anyTensor Sig.anyTensor (\a -> T.plus a (T.ones T.float32 (T.r2 three four)))
                    in
                    Expect.equal (Ok [ [ 3, 4 ] ])
                        (outShapes (Graph.function "g" vec4 (\x -> Transform.call f (T.rows x))))
            , test "with an eager trace" <|
                \_ ->
                    let
                        f =
                            Transform.shared "f" (Sig.f32 (T.r2 (T.dim A 1) four)) (Sig.f32 (T.r2 (T.dim A 3) four)) (\a -> T.plus a (T.ones T.float32 (T.r2 (T.dim A 3) four)))
                    in
                    Expect.equal (Ok [ [ 3, 4 ] ])
                        (outShapes (Graph.function "g" vec4 (\x -> Transform.call f (T.rows x))))
            ]
        , describe "B031 resident names"
            [ test "two inputs with one resident name are refused" <|
                \_ ->
                    expectError "inputs 0 and 1 have the same resident name w"
                        (Graph.build "g" (Sig.pair (resident "w" vec3) (resident "w" vec3)) vec3 (\( a, b ) -> T.plus a b))
            , test "two outputs with one resident name are refused" <|
                \_ ->
                    expectError "outputs 0 and 1 have the same resident name w"
                        (Graph.build "g" vec3 (Sig.pair (resident "w" vec3) (resident "w" vec3)) (\a -> ( a, a )))
            , test "an input and an output may share a resident name" <|
                \_ ->
                    Expect.equal (Ok [ [ 3 ] ]) (outShapes (Graph.build "g" (resident "w" vec3) (resident "w" vec3) T.relu))
            ]
        , describe "B048 negative slot sizes"
            [ test "an input slot with a negative size is refused" <|
                \_ ->
                    expectError "input 0 (arg) has a negative size: [-3]" (Graph.function "g" (Sig.f32 (T.r1 (T.dim B -3))) T.relu)
            ]
        , describe "B091 a negative GPU index"
            [ test "is refused" <|
                \_ ->
                    case Graph.function "g" vec3 T.relu of
                        Ok g ->
                            Expect.equal ( True, True )
                                ( Max.toBytecodeOn (Max.Gpu -1) g |> Result.map (always ()) |> (/=) (Ok ())
                                , Max.toGenericTextOn (Max.Gpu -1) g == Err [ "Max: there is no GPU with the negative index -1" ]
                                )

                        Err e ->
                            Expect.fail (String.join " | " e)
            ]
        , describe "B037 non-finite and negative-zero literals at the dtype's width"
            [ test "f64 infinity" <|
                \_ -> Expect.equal "#M.dense_array<0x7FF0000000000000> : tensor<f64>" (Mo.constText P.F64 [] (FloatValues [ 1 / 0 ]))
            , test "f64 NaN and -infinity" <|
                \_ -> Expect.equal "#M.dense_array<0x7FF8000000000000, 0xFFF0000000000000> : tensor<2xf64>" (Mo.constText P.F64 [ 2 ] (FloatValues [ 0 / 0, -1 / 0 ]))
            , test "f16" <|
                \_ -> Expect.equal "#M.dense_array<0x7E00, 0x7C00, 0xFC00> : tensor<3xf16>" (Mo.constText P.F16 [ 3 ] (FloatValues [ 0 / 0, 1 / 0, -1 / 0 ]))
            , test "bf16" <|
                \_ -> Expect.equal "#M.dense_array<0x7FC0, 0x7F80, 0xFF80> : tensor<3xbf16>" (Mo.constText P.BF16 [ 3 ] (FloatValues [ 0 / 0, 1 / 0, -1 / 0 ]))
            , test "f32 keeps its patterns" <|
                \_ -> Expect.equal "#M.dense_array<0x7FC00000, 0x7F800000, 0xFF800000> : tensor<3xf32>" (Mo.constText P.F32 [ 3 ] (FloatValues [ 0 / 0, 1 / 0, -1 / 0 ]))
            , test "negative zero keeps its sign" <|
                \_ -> Expect.equal "#M.dense_array<-0.0, 0.0> : tensor<2xf32>" (Mo.constText P.F32 [ 2 ] (FloatValues [ -0.0, 0.0 ]))
            ]
        , describe "INT follow-up: si64 constants"
            [ test "2^60 is written exactly" <|
                \_ -> Expect.equal "#M.dense_array<1152921504606846976, -1152921504606846976> : tensor<2xsi64>" (Mo.constText P.SI64 [ 2 ] (IntValues [ 2 ^ 60, -(2 ^ 60) ]))
            ]
        , describe "B057 messages"
            [ test "a slot with a shape but no dtype says shape or dtype" <|
                \_ -> expectError "input 0 has no shape or dtype" (Graph.function "g" (declaring Nothing (Just [ 3 ]) vec3) T.relu)
            , test "a bottom-k off the last axis is refused under its own op name" <|
                \_ ->
                    case Graph.function "g" (Sig.f32 (T.r2 three four)) (\x -> T.bottomK Axis.retag0of2 (T.dim K 2) x |> Tuple.first) of
                        Ok g ->
                            Expect.equal (Err [ "rmo.mo.bottom_k: on a GPU only the last axis is supported" ]) (Max.toGenericTextOn (Max.Gpu 0) g)

                        Err e ->
                            Expect.fail (String.join " | " e)
            , test "the round-trip hint gives its causes as examples" <|
                \_ -> expectError "at position 0 (for example a record field's accessor" (Graph.build "g" (Sig.map T.relu T.exp vec3) Sig.anyTensor identity)
            ]
        ]
