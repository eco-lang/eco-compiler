module TestLogic.Generate.CodeGen.BooleanConstants exposing (expectBooleanConstants)

{-| Checks how a Bool is represented in generated MLIR (CGEN\_009, REP\_ABI\_001,
REP\_CLOSURE\_001, FORBID\_CLOSURE\_001), so that a Bool passed as a raw `i1` into
a heap object, a closure or a call boundary fails a test instead of going
unnoticed.

A Bool has two representations in the MLIR the code generator emits. In SSA
operand context it is `i1`, a one-bit integer, which is what an `eco.case`
with `case_kind` `"bool"` branches on. In a heap object, in a closure capture
and at a function boundary it is `!eco.value`, a boxed value (True and False
are embedded constants, HEAP\_010). `Compiler.Generate.MLIR.Types` decides which
representation applies where.

`expectBooleanConstants` compiles a program to MLIR and fails, with one line
per violation, on either of two kinds:

  - A True or False `eco.constant`, recognised by its integer `kind` attribute
    (1 for True, 0 for False, as `Compiler.Generate.MLIR.Ops.ecoConstantTrue`
    and `ecoConstantFalse` build it), whose results are not exactly one
    `!eco.value`.
  - An operand of type `i1` given to an op that crosses a heap, closure or
    call boundary: `eco.construct.*`, `eco.papCreate`, `eco.papCreateGroup`,
    `eco.papExtend`, `eco.call` and `eco.return`. The operand's type is its
    defined type, the type of the op result or block argument that introduces
    the SSA name within the enclosing top-level op, not the op's
    `_operand_types` record (`eco.papCreateGroup` has none).

Among what is not checked: an `i1` stored inside an SSA aggregate that
`eco.to_heap` moves to the heap; and `i1` operands of any other op, such as
`eco.yield` or the arithmetic and comparison ops where `i1` is legitimate.

@docs expectBooleanConstants

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractResultTypes
        , findOpsNamed
        , getIntAttr
        , isEcoValueType
        , typeEnvOfOp
        , violationsToExpectation
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR with `TestLogic.TestPipeline.runToMlir` and
passes when the result has none of the violations the module docstring lists.

Fails with `Compilation failed:` and the pipeline's error when an earlier stage
fails.

-}
expectBooleanConstants : Src.Module -> Expectation
expectBooleanConstants srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBooleanConstants mlirModule)


{-| Returns the violations in `mlirModule`: first each True/False
`eco.constant` whose results are not one `!eco.value`, then each `i1` operand of
a boundary op.
-}
checkBooleanConstants : MlirModule -> List Violation
checkBooleanConstants mlirModule =
    let
        constantViolations =
            findOpsNamed "eco.constant" mlirModule
                |> List.filter isBoolConstant
                |> List.filterMap checkBoolConstantType
    in
    constantViolations ++ checkI1Usage mlirModule


{-| Returns whether `op` is a True or False `eco.constant`: its integer `kind`
attribute is 1 (True) or 0 (False).
-}
isBoolConstant : MlirOp -> Bool
isBoolConstant op =
    case getIntAttr "kind" op of
        Just 0 ->
            True

        Just 1 ->
            True

        _ ->
            False


{-| Returns a violation unless `op` has exactly one result, of type
`!eco.value`.
-}
checkBoolConstantType : MlirOp -> Maybe Violation
checkBoolConstantType op =
    case extractResultTypes op of
        [ resultType ] ->
            if isEcoValueType resultType then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Bool constant must produce !eco.value, got "
                            ++ typeToString resultType
                    }

        resultTypes ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "Bool constant must have exactly one result, has "
                        ++ String.fromInt (List.length resultTypes)
                }


{-| Returns a violation for each `i1` operand of a boundary op, for every
top-level op of the module; operand types are looked up in the defined types of
that top-level op.
-}
checkI1Usage : MlirModule -> List Violation
checkI1Usage mlirModule =
    List.concatMap
        (\topOp ->
            let
                env =
                    typeEnvOfOp topOp
            in
            walkOpAndChildren topOp
                |> List.filter isBoundaryOp
                |> List.concatMap (checkNoI1Operands env)
        )
        mlirModule.body


{-| Returns whether `op` passes its operands across a heap, closure or call
boundary.
-}
isBoundaryOp : MlirOp -> Bool
isBoundaryOp op =
    String.startsWith "eco.construct." op.name
        || List.member op.name [ "eco.papCreate", "eco.papCreateGroup", "eco.papExtend", "eco.call", "eco.return" ]


{-| Returns a violation for each operand of `op` whose defined type in `env` is
`i1`. An operand with no defined type in `env` is not reported.
-}
checkNoI1Operands : TypeEnv -> MlirOp -> List Violation
checkNoI1Operands env op =
    op.operands
        |> List.indexedMap
            (\index name ->
                if Dict.get name env == Just I1 then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "operand "
                                ++ String.fromInt index
                                ++ " ("
                                ++ name
                                ++ ") is i1 (Bool) but must be !eco.value at a heap/closure/call boundary"
                        }

                else
                    Nothing
            )
        |> List.filterMap identity


{-| Returns a short name for `t` for a violation message: the MLIR spelling of
an integer or float type, `!` followed by the name of a named struct, and
`function` for any function type.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"
