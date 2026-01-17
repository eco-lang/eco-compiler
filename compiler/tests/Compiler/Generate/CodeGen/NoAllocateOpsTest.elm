module Compiler.Generate.CodeGen.NoAllocateOpsTest exposing (suite)

{-| Tests for CGEN_039: No Allocate Ops in Codegen invariant.

MLIR codegen must not emit `eco.allocate*` ops; these are introduced by later
lowering passes.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , recordExpr
        , strExpr
        , tType
        , tVar
        , tuple3Expr
        , tupleExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , checkNone
        , violationsToExpectation
        , walkAllOps
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_039: No Allocate Ops in Codegen"
        [ Test.test "List construction doesn't use allocate ops" listNoAllocateTest
        , Test.test "Tuple construction doesn't use allocate ops" tupleNoAllocateTest
        , Test.test "Record construction doesn't use allocate ops" recordNoAllocateTest
        , Test.test "Custom ADT construction doesn't use allocate ops" customNoAllocateTest
        , Test.test "Complex module doesn't use allocate ops" complexNoAllocateTest
        ]



-- INVARIANT CHECKER


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



-- TEST HELPER


{-| Maybe union type for tests.
-}
maybeUnion : UnionDef
maybeUnion =
    { name = "Maybe"
    , args = [ "a" ]
    , ctors =
        [ { name = "Just", args = [ tVar "a" ] }
        , { name = "Nothing", args = [] }
        ]
    }


{-| Helper to create a module that includes the Maybe type.
-}
makeModuleWithMaybe : String -> Src.Expr -> Src.Module
makeModuleWithMaybe name expr =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = name
          , args = []
          , tipe = tType "Maybe" [ tType "Int" [] ]
          , body = expr
          }
        ]
        [ maybeUnion ]
        []


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkNoAllocateOps mlirModule)



-- TEST CASES


listNoAllocateTest : () -> Expectation
listNoAllocateTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ intExpr 1, intExpr 2, intExpr 3 ]))


tupleNoAllocateTest : () -> Expectation
tupleNoAllocateTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (strExpr "hello")))


recordNoAllocateTest : () -> Expectation
recordNoAllocateTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr
                [ ( "x", intExpr 1 )
                , ( "y", intExpr 2 )
                , ( "name", strExpr "test" )
                ]
            )
        )


customNoAllocateTest : () -> Expectation
customNoAllocateTest _ =
    runInvariantTest (makeModuleWithMaybe "testValue" (callExpr (ctorExpr "Just") [ intExpr 42 ]))


complexNoAllocateTest : () -> Expectation
complexNoAllocateTest _ =
    -- Complex module with multiple allocation-triggering constructs
    -- Using list and record instead of Maybe for simplicity
    let
        list =
            listExpr [ intExpr 1, intExpr 2 ]

        record =
            recordExpr [ ( "a", intExpr 3 ) ]

        innerTuple =
            tuple3Expr (intExpr 4) (intExpr 5) (intExpr 6)
    in
    runInvariantTest
        (makeModule "testValue"
            (tupleExpr
                (tupleExpr list record)
                innerTuple
            )
        )
