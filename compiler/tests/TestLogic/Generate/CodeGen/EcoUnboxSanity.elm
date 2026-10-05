module TestLogic.Generate.CodeGen.EcoUnboxSanity exposing (expectEcoUnboxSanity)

{-| Checks the types around each `eco.unbox` inside a top-level function of the
MLIR generated for a program, so that an unbox applied to something other than
a boxed value, or producing something other than a primitive, does not go
unnoticed.

`eco.unbox` takes a boxed value, of type `!eco.value`, and produces the
primitive it holds: `i1` for a Bool, `i16` for a Char, `i64` for an Int or `f64`
for a Float. Several checkers read an op's operand types from its
`_operand_types` attribute, as `TestLogic.Generate.CodeGen.Invariants`
describes. That attribute is what the generator wrote down, not the type of the
value the op consumes, so this checker looks each operand up instead, in the
types given where the value is defined.

`expectEcoUnboxSanity` compiles a source module with
`TestLogic.TestPipeline.runToMlir` and checks each top-level `func.func` of the
generated `MlirModule` separately. For each function it first builds a _type
environment_: one map from SSA name to type, holding the function op's results
and every block argument and op result defined anywhere inside it, at any depth.
It then reports an `eco.unbox` nested in the function, at any depth:

  - that does not have exactly one operand;
  - that does not have exactly one result;
  - whose operand is not in the environment: a function's body is isolated
    from the rest of the module, so every value it uses is defined in it;
  - whose operand's type in the environment is not `!eco.value`; or
  - whose result type is not `i1`, `i16`, `i64` or `f64`, so an `i8` or `i32`
    result is reported.

Only the first of these that applies is reported for an op.

Among what is not tested:

  - an `eco.unbox` outside every top-level `func.func`;
  - whether the result type matches the kind of value that was boxed.

The type environment is one map for the whole function, so a name defined more
than once in a function is looked up with the type of the definition visited
last.

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , isEcoPrimitive
        , isEcoValueType
        , typeEnvOfOp
        , violationsToExpectation
        , walkOpsInRegion
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when no
`eco.unbox` in a top-level function breaks the rules listed in this module's
docstring. When `runToMlir` fails, it fails with the pipeline's error, prefixed
with `Compilation failed:`.
-}
expectEcoUnboxSanity : Src.Module -> Expectation
expectEcoUnboxSanity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkEcoUnboxSanity mlirModule)


{-| Returns the violations of every `eco.unbox` in the module's top-level
`func.func` ops, each function checked against its own type environment.
-}
checkEcoUnboxSanity : MlirModule -> List Violation
checkEcoUnboxSanity mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Returns the violations of every `eco.unbox` nested in `funcOp`, at any
depth, with operand types looked up in the type environment of `funcOp`.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            typeEnvOfOp funcOp

        allOps =
            walkOpsInOp funcOp

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkUnboxOp typeEnv) unboxOps


{-| Returns the violation for one `eco.unbox`, or `Nothing` when it passes.

The checks are made in this order, and only the first that fails is reported:
exactly one operand, exactly one result, an operand whose type in `typeEnv` is
`!eco.value` (an operand not in `typeEnv` is reported as undefined), and a
result type that `isEcoPrimitive` accepts.

-}
checkUnboxOp : TypeEnv -> MlirOp -> Maybe Violation
checkUnboxOp typeEnv op =
    case op.operands of
        [ operandName ] ->
            case op.results of
                [ ( _, resultType ) ] ->
                    case Dict.get operandName typeEnv of
                        Nothing ->
                            Just
                                { opId = op.id
                                , opName = op.name
                                , message =
                                    "eco.unbox operand '"
                                        ++ operandName
                                        ++ "' has no definition in its function"
                                }

                        Just operandType ->
                            if not (isEcoValueType operandType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox operand '"
                                            ++ operandName
                                            ++ "' is not eco.value, got "
                                            ++ typeToString operandType
                                    }

                            else if not (isEcoPrimitive resultType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox result is not primitive, got "
                                            ++ typeToString resultType
                                    }

                            else
                                Nothing

                _ ->
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.unbox should have exactly 1 result, has "
                                ++ String.fromInt (List.length op.results)
                        }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "eco.unbox should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }


{-| Returns every op nested in `op`'s regions, at any depth, not including `op`
itself.
-}
walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


{-| Returns how a type is written in a violation message: its MLIR spelling, or
the word `function` for any function type.
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
