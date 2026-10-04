module Compiler.Generate.MLIR.IntrinsicsListConsTest exposing (suite)

{-| Tests for the part of `KernelIntrinsics.kernelIntrinsic` that decides whether a
call to the `List.cons` kernel can be replaced by an inline list construction
(`ConstructList`), and what MLIR type the new cell's head slot gets.

The head slot type decides how the head is stored in the list cell: unboxed as
`i64`, `f64` or `i16`, or boxed as `!eco.value`. The heads given a primitive slot
here (Int, Float and Char) are the heads for which
`Compiler.Generate.MLIR.KernelAbi` calls the `_Int`, `_Float` and `_Char`
variants of the `List.cons` kernel. A head that is an unsettled `number` type
variable gets neither a primitive slot here nor a suffixed variant there.
Without these tests, a change to the classifier that accepted a shape, or chose
a head slot type, out of step with the kernel call it replaces could go
unnoticed. A declined call (`Nothing`) is generated as it would be without the
intrinsic.

The classifier is reached through the exposed `kernelIntrinsic`, with the home
`"List"` and the name `"cons"`, the same entry point code generation calls. It
classifies by types alone. `Compiler.Generate.MLIR.Expr` then applies
the `list.consIntrinsic` configuration flag and a check that a primitive head
slot is fed by an operand of that same type or a boxed one, before emitting
anything; neither is exercised here.

The fixture is `MonoType` values built directly. `listOfInt` serves the
Int-head test and the declined tests; the other head tests each build a list of
their own head type.

The tests establish:

  - A String head, with String list tail and result, gives a `!eco.value` head
    slot.
  - An Int head gives an `i64` slot, a Float head `f64` and a Char head `i16`,
    each with a list of its own type as tail and result.
  - A Bool head gives a `!eco.value` slot, not a primitive one.
  - A head that is a `number` type variable (`MVar _ CNumber`) is declined,
    although its ABI type (the MLIR type `Types.monoTypeToAbi` gives it at a
    function boundary) is `i64`.
  - An `Int` tail, or an `Int` result, is declined.
  - A call with one argument, or with none, is declined.
  - `List.reverse` is not classified as a list construction, and neither is a
    `cons` in the home `"Platform"`.

Among what is not tested: heads of other types (tuples, records, custom types,
functions, lists, other type variables), a tail or result that is a type
variable, and every other kernel the classifier handles.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.KernelIntrinsics as KernelIntrinsics
import Expect
import Test exposing (Test, describe, test)


{-| A list of `Int`, for the Int-head test and the declined tests.

It is built with the bare `MList` constructor and a hash field of 0, not through
the smart constructor. Of a tail or a result, the classifier asks only whether
its ABI type is boxed, and that does not read the hash.

-}
listOfInt : Mono.MonoType
listOfInt =
    Mono.MList 0 Mono.MInt


{-| Asks the classifier about a two-argument `List.cons` call with the given head,
tail and result types.
-}
consOf : Mono.MonoType -> Mono.MonoType -> Mono.MonoType -> Maybe KernelIntrinsics.Intrinsic
consOf headTy tailTy resultTy =
    KernelIntrinsics.kernelIntrinsic "List" "cons" [ headTy, tailTy ] resultTy


{-| The tests, in two groups: calls given a `ConstructList`, and calls declined.
-}
suite : Test
suite =
    describe "Generate.MLIR.Intrinsics — List.cons"
        [ describe "admits, with the head kind taken from the head MonoType"
            [ test "boxed head (String) -> !eco.value slot" <|
                \_ ->
                    consOf Mono.MString (Mono.MList 0 Mono.MString) (Mono.MList 0 Mono.MString)
                        |> Expect.equal (Just (KernelIntrinsics.ConstructList { headMlirType = Types.ecoValue }))
            , test "Int head -> i64 slot (the _Int axis)" <|
                \_ ->
                    consOf Mono.MInt listOfInt listOfInt
                        |> Expect.equal (Just (KernelIntrinsics.ConstructList { headMlirType = Types.ecoInt }))
            , test "Float head -> f64 slot (the _Float axis)" <|
                \_ ->
                    consOf Mono.MFloat (Mono.MList 0 Mono.MFloat) (Mono.MList 0 Mono.MFloat)
                        |> Expect.equal (Just (KernelIntrinsics.ConstructList { headMlirType = Types.ecoFloat }))
            , test "Char head -> i16 slot (the _Char axis)" <|
                \_ ->
                    consOf Mono.MChar (Mono.MList 0 Mono.MChar) (Mono.MList 0 Mono.MChar)
                        |> Expect.equal (Just (KernelIntrinsics.ConstructList { headMlirType = Types.ecoChar }))
            , test "Bool head is boxed, not a primitive slot (REP: Bool is never unboxed in heap fields)" <|
                \_ ->
                    consOf Mono.MBool (Mono.MList 0 Mono.MBool) (Mono.MList 0 Mono.MBool)
                        |> Expect.equal (Just (KernelIntrinsics.ConstructList { headMlirType = Types.ecoValue }))
            ]
        , describe "declines (⇒ the site keeps today's kernel call)"
            [ test "unsettled CNumber head — maps to i64 under monoTypeToAbi but is NOT the _Int axis" <|
                \_ ->
                    consOf (Mono.MVar TypeIds.firstMVarId Mono.CNumber) listOfInt listOfInt
                        |> Expect.equal Nothing
            , test "scalar tail (the kernelDevirtShapeOk hazard)" <|
                \_ ->
                    consOf Mono.MInt Mono.MInt listOfInt
                        |> Expect.equal Nothing
            , test "scalar result" <|
                \_ ->
                    consOf Mono.MInt listOfInt Mono.MInt
                        |> Expect.equal Nothing
            , test "unsaturated / wrong arity" <|
                \_ ->
                    KernelIntrinsics.kernelIntrinsic "List" "cons" [ Mono.MInt ] listOfInt
                        |> Expect.equal Nothing
            , test "no args at all (the unapplied `cons` value path, Expr.elm:775)" <|
                \_ ->
                    KernelIntrinsics.kernelIntrinsic "List" "cons" [] listOfInt
                        |> Expect.equal Nothing
            , test "a different List kernel is not claimed" <|
                \_ ->
                    KernelIntrinsics.kernelIntrinsic "List" "reverse" [ listOfInt ] listOfInt
                        |> Expect.equal Nothing
            , test "a different home is not claimed" <|
                \_ ->
                    KernelIntrinsics.kernelIntrinsic "Platform" "cons" [ Mono.MInt, listOfInt ] listOfInt
                        |> Expect.equal Nothing
            ]
        ]
