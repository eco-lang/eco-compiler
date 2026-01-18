module Compiler.Generate.CodeGen.CustomConstruction exposing
    ( expectCustomConstruction
    , checkCustomConstruction
    )

{-| Test logic for CGEN_020: Custom ADT Construction invariant.

`eco.construct.custom` is only for user-defined custom ADTs.
Attributes must have valid `tag` and `size`, and `size` must match operand count.

@docs expectCustomConstruction, checkCustomConstruction

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)


{-| Verify that custom construction invariants hold for a source module.

This compiles the module to MLIR and checks:

  - eco.construct.custom has required tag attribute
  - eco.construct.custom has required size attribute
  - size matches operand count
  - Built-in type constructors are not incorrectly using eco.construct.custom

-}
expectCustomConstruction : Src.Module -> Expectation
expectCustomConstruction srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomConstruction mlirModule)


{-| Check custom construction invariants.
-}
checkCustomConstruction : MlirModule -> List Violation
checkCustomConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        violations =
            List.concatMap checkCustomOp customOps
    in
    violations


checkCustomOp : MlirOp -> List Violation
checkCustomOp op =
    let
        maybeTag =
            getIntAttr "tag" op

        maybeSize =
            getIntAttr "size" op

        operandCount =
            List.length op.operands

        maybeConstructorName =
            getStringAttr "constructor" op
    in
    List.filterMap identity
        [ -- Check tag attribute exists
          case maybeTag of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing tag attribute"
                    }

            _ ->
                Nothing

        -- Check size attribute exists
        , case maybeSize of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing size attribute"
                    }

            Just size ->
                -- Check size matches operand count
                if size /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.construct.custom size="
                                ++ String.fromInt size
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else
                    Nothing

        -- Check not using custom for built-in list types
        , case maybeConstructorName of
            Just name ->
                if List.member name [ "Cons", "Nil" ] then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "List constructor '" ++ name ++ "' should use eco.construct.list or eco.constant, not eco.construct.custom"
                        }

                else
                    Nothing

            Nothing ->
                Nothing
        ]
