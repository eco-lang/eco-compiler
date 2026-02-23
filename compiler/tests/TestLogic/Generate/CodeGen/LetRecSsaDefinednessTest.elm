module TestLogic.Generate.CodeGen.LetRecSsaDefinednessTest exposing (suite)

{-| Test suite for SSA Definedness in let-rec codegen.

Every SSA value used as an operand within a function must have a corresponding
definition (as an op result or block/function argument). This catches the
"undeclared SSA value" bug that forceResultVar prevents for recursive let
bindings where placeholder SSA vars are captured by sibling closures.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.LetRecSsaDefinedness exposing (expectLetRecSsaDefinedness)


suite : Test
suite =
    Test.describe "SSA Definedness (let-rec placeholder)"
        [ StandardTestSuites.expectSuite expectLetRecSsaDefinedness "passes SSA definedness check"
        ]
