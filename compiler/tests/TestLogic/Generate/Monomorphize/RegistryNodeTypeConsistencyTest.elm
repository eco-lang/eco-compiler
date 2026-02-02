module TestLogic.Generate.Monomorphize.RegistryNodeTypeConsistencyTest exposing (suite)

{-| Test suite for MONO\_017: Registry type matches node type.

For every SpecId in SpecializationRegistry.reverseMapping, the stored
MonoType must equal the type of the corresponding MonoNode.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.Monomorphize.RegistryNodeTypeConsistency exposing (expectRegistryNodeTypeConsistency)


suite : Test
suite =
    Test.describe "MONO_017: Registry type matches node type"
        [ StandardTestSuites.expectSuite expectRegistryNodeTypeConsistency "registry type matches node"
        ]
