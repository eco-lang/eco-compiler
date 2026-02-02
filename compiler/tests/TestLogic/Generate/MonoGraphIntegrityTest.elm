module TestLogic.Generate.MonoGraphIntegrityTest exposing (suite)

{-| Test suite for MonoGraph integrity invariants:

  - MONO\_004: All functions are callable MonoNodes
  - MONO\_005: Specialization registry is complete and consistent
  - MONO\_010: MonoGraph is type complete
  - MONO\_011: MonoGraph is closed and hygienic

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoGraphIntegrity
    exposing
        ( expectCallableMonoNodes
        , expectMonoGraphClosed
        , expectMonoGraphComplete
        , expectSpecRegistryComplete
        )


suite : Test
suite =
    Test.describe "MonoGraph integrity invariants"
        [ Test.describe "MONO_004: All functions are callable MonoNodes"
            [ StandardTestSuites.expectSuite expectCallableMonoNodes "has callable function nodes"
            ]
        , Test.describe "MONO_005: Specialization registry is complete"
            [ StandardTestSuites.expectSuite expectSpecRegistryComplete "has complete registry"
            ]
        , Test.describe "MONO_010: MonoGraph is type complete"
            [ StandardTestSuites.expectSuite expectMonoGraphComplete "is type complete"
            ]
        , Test.describe "MONO_011: MonoGraph is closed and hygienic"
            [ StandardTestSuites.expectSuite expectMonoGraphClosed "is closed"
            ]
        ]
