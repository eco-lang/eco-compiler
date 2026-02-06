module TestLogic.Generate.CodeGen.NoAllocateOps exposing (expectNoAllocateOps, checkNoAllocateOps)

{-| Test logic for CGEN\_039: No Allocate Ops in Codegen invariant.

MLIR codegen must not emit `eco.allocate*` ops; these are introduced by later
lowering passes.

@docs expectNoAllocateOps, checkNoAllocateOps

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import TestLogic.TestPipeline exposing (runToMlir)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , checkNone
        , violationsToExpectation
        , walkAllOps
        )


{-| Verify that no allocate ops invariants hold for a source module.
-}
expectNoAllocateOps : Src.Module -> Expectation
expectNoAllocateOps srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkNoAllocateOps mlirModule)


allocateOps : List String
allocateOps =
    [ "eco.allocate"
    , "eco.allocate_ctor"
    , "eco.allocate_string"
    , "eco.allocate_closure"
    ]


{-| Check no allocate ops in codegen output.
-}
checkNoAllocateOps : MlirModule -> List Violation
checkNoAllocateOps mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        allocateOpsList =
            List.filter (\op -> List.member op.name allocateOps) allOps
    in
    checkNone "Found allocate op in codegen output; allocation ops should only be introduced by lowering" allocateOpsList
