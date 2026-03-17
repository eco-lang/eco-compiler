module TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr)

{-| Test logic for arith.cmpi predicate attribute invariant.

Every `arith.cmpi` op must have a `predicate` attribute (an integer specifying
eq=0, ne=1, slt=2, etc.). Currently, char comparisons (i16 operands) emit
`arith.cmpi` via `ecoBinaryOp` which does NOT include the `predicate` attribute,
while integer comparisons correctly use `arithCmpI` which does include it.

@docs expectCmpiPredicateAttr

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that every arith.cmpi op has a predicate attribute.
-}
expectCmpiPredicateAttr : Src.Module -> Expectation
expectCmpiPredicateAttr srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCmpiPredicateAttr mlirModule)


{-| Check that all arith.cmpi ops have a predicate attribute.
-}
checkCmpiPredicateAttr : MlirModule -> List Violation
checkCmpiPredicateAttr mlirModule =
    let
        cmpiOps =
            findOpsNamed "arith.cmpi" mlirModule
    in
    List.filterMap checkCmpiOp cmpiOps


checkCmpiOp : MlirOp -> Maybe Violation
checkCmpiOp op =
    case getIntAttr "predicate" op of
        Just _ ->
            Nothing

        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "arith.cmpi is missing required 'predicate' attribute"
                }
