module TestLogic.Generate.CodeGen.NoAllocateOps exposing (expectNoAllocateOps)

{-| Catches the code generator emitting an explicit allocation op.

This module assumes, as its failure message says, that allocation ops are
introduced only by a lowering step that runs after code generation, so the
MLIR the code generator produces must contain none. An _allocation op_ here is
an op named `eco.allocate`, `eco.allocate_ctor`, `eco.allocate_string` or
`eco.allocate_closure`. No module under `src` builds an op with any of these
names, so the check guards against one being introduced.

`expectNoAllocateOps` compiles one source module to MLIR with
`TestLogic.TestPipeline.runToMlir` and fails if any op in the result, at any
depth, has one of those four names. Ops are matched by exact name, so an op
whose name merely begins with `eco.allocate` is not reported.

Among what is not tested: MLIR produced by bootstrap Stage 5 (the substitution
engine), since `runToMlir` is the production pipeline.

@docs expectNoAllocateOps

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , checkNone
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
the result contains no allocation op.

It fails with the pipeline's error message when compilation fails, and
otherwise with a message naming the first allocation op found.

-}
expectNoAllocateOps : Src.Module -> Expectation
expectNoAllocateOps srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkNoAllocateOps mlirModule)


{-| The names of the allocation ops: the ops that must not appear in the code
generator's output.
-}
allocateOps : List String
allocateOps =
    [ "eco.allocate"
    , "eco.allocate_ctor"
    , "eco.allocate_string"
    , "eco.allocate_closure"
    ]


{-| Returns one violation for each op in `mlirModule`, at any depth, whose
name is one of `allocateOps`.
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
