module Compiler.Generate.CodeGen.CgenInvariantsTest exposing (suite)

{-| Aggregated test suite for MLIR codegen invariants (CGEN_015 - CGEN_039).

This module combines all codegen invariant tests:

  - Type-specific construction (CGEN_015-020, CGEN_025)
  - Projection operations (CGEN_021-024)
  - Control flow (CGEN_028-031)
  - Attribute consistency (CGEN_026, CGEN_027, CGEN_032, CGEN_037)
  - Closure operations (CGEN_033, CGEN_034)
  - Module-level (CGEN_035, CGEN_036, CGEN_038, CGEN_039)

See design\_docs/invariants.csv for the full invariant definitions.

-}

import Compiler.Generate.CodeGen.CaseScrutineeTypeTest as CaseScrutineeTypeTest
import Compiler.Generate.CodeGen.CaseTagsCountTest as CaseTagsCountTest
import Compiler.Generate.CodeGen.CaseTerminationTest as CaseTerminationTest
import Compiler.Generate.CodeGen.CharTypeMappingTest as CharTypeMappingTest
import Compiler.Generate.CodeGen.ConstructResultTypeTest as ConstructResultTypeTest
import Compiler.Generate.CodeGen.CustomConstructionTest as CustomConstructionTest
import Compiler.Generate.CodeGen.CustomProjectionTest as CustomProjectionTest
import Compiler.Generate.CodeGen.DbgTypeIdsTest as DbgTypeIdsTest
import Compiler.Generate.CodeGen.JoinpointUniqueIdTest as JoinpointUniqueIdTest
import Compiler.Generate.CodeGen.JumpTargetTest as JumpTargetTest
import Compiler.Generate.CodeGen.KernelAbiConsistencyTest as KernelAbiConsistencyTest
import Compiler.Generate.CodeGen.ListConstructionTest as ListConstructionTest
import Compiler.Generate.CodeGen.ListProjectionTest as ListProjectionTest
import Compiler.Generate.CodeGen.NoAllocateOpsTest as NoAllocateOpsTest
import Compiler.Generate.CodeGen.OperandTypesAttrTest as OperandTypesAttrTest
import Compiler.Generate.CodeGen.PapCreateArityTest as PapCreateArityTest
import Compiler.Generate.CodeGen.PapExtendResultTest as PapExtendResultTest
import Compiler.Generate.CodeGen.RecordConstructionTest as RecordConstructionTest
import Compiler.Generate.CodeGen.RecordProjectionTest as RecordProjectionTest
import Compiler.Generate.CodeGen.SingletonConstantsTest as SingletonConstantsTest
import Compiler.Generate.CodeGen.TupleConstructionTest as TupleConstructionTest
import Compiler.Generate.CodeGen.TupleProjectionTest as TupleProjectionTest
import Compiler.Generate.CodeGen.TypeTableUniquenessTest as TypeTableUniquenessTest
import Compiler.Generate.CodeGen.UnboxedBitmapTest as UnboxedBitmapTest
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MLIR Codegen Invariants (CGEN_015-039)"
        [ typeSpecificConstruction
        , projectionOperations
        , controlFlowInvariants
        , attributeConsistency
        , closureOperations
        , moduleLevelInvariants
        ]


{-| CGEN_015-020, CGEN_025: Type-specific construction invariants
-}
typeSpecificConstruction : Test
typeSpecificConstruction =
    Test.describe "Type-Specific Construction"
        [ CharTypeMappingTest.suite -- CGEN_015
        , ListConstructionTest.suite -- CGEN_016
        , TupleConstructionTest.suite -- CGEN_017
        , RecordConstructionTest.suite -- CGEN_018
        , SingletonConstantsTest.suite -- CGEN_019
        , CustomConstructionTest.suite -- CGEN_020
        , ConstructResultTypeTest.suite -- CGEN_025
        ]


{-| CGEN_021-024: Projection operation invariants
-}
projectionOperations : Test
projectionOperations =
    Test.describe "Projection Operations"
        [ ListProjectionTest.suite -- CGEN_021
        , TupleProjectionTest.suite -- CGEN_022
        , RecordProjectionTest.suite -- CGEN_023
        , CustomProjectionTest.suite -- CGEN_024
        ]


{-| CGEN_028-031: Control flow invariants
-}
controlFlowInvariants : Test
controlFlowInvariants =
    Test.describe "Control Flow"
        [ CaseTerminationTest.suite -- CGEN_028
        , CaseTagsCountTest.suite -- CGEN_029
        , JumpTargetTest.suite -- CGEN_030
        , JoinpointUniqueIdTest.suite -- CGEN_031
        ]


{-| CGEN_026-027, CGEN_032, CGEN_037: Attribute consistency invariants
-}
attributeConsistency : Test
attributeConsistency =
    Test.describe "Attribute Consistency"
        [ UnboxedBitmapTest.suite -- CGEN_026, CGEN_027
        , OperandTypesAttrTest.suite -- CGEN_032
        , CaseScrutineeTypeTest.suite -- CGEN_037
        ]


{-| CGEN_033-034: Closure operation invariants
-}
closureOperations : Test
closureOperations =
    Test.describe "Closure Operations"
        [ PapCreateArityTest.suite -- CGEN_033
        , PapExtendResultTest.suite -- CGEN_034
        ]


{-| CGEN_035-036, CGEN_038-039: Module-level invariants
-}
moduleLevelInvariants : Test
moduleLevelInvariants =
    Test.describe "Module-Level"
        [ TypeTableUniquenessTest.suite -- CGEN_035
        , DbgTypeIdsTest.suite -- CGEN_036
        , KernelAbiConsistencyTest.suite -- CGEN_038
        , NoAllocateOpsTest.suite -- CGEN_039
        ]
