module Compiler.Generate.CodeGen.BlockTerminatorTest exposing (suite)

{-| Tests for CGEN_042: Block Terminator Presence invariant.

Every block in every region emitted by MLIR codegen must end with a
terminator operation (e.g. `eco.return`, `eco.jump`, `scf.yield`).

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , boolExpr
        , caseExpr
        , ctorExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pCtor
        , pList
        , pVar
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , allBlocks
        , findFuncOps
        , isValidTerminator
        , violationsToExpectation
        , walkAllOps
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_042: Block Terminator Presence"
        [ Test.test "Simple function has terminator" simpleFunctionTest
        , Test.test "If-then-else branches have terminators" ifElseTest
        , Test.test "Case expression branches have terminators" caseExprTest
        , Test.test "Nested case expressions have terminators" nestedCaseTest
        , Test.test "List pattern matching has terminators" listPatternTest
        ]



-- INVARIANT CHECKER


{-| Check block terminator presence invariants.
-}
checkBlockTerminators : MlirModule -> List Violation
checkBlockTerminators mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        violations =
            List.concatMap checkOpRegions allOps
    in
    violations


checkOpRegions : MlirOp -> List Violation
checkOpRegions op =
    List.indexedMap (checkRegion op) op.regions
        |> List.concat


checkRegion : MlirOp -> Int -> MlirRegion -> List Violation
checkRegion parentOp regionIdx region =
    let
        blocks =
            allBlocks region
    in
    List.indexedMap (checkBlock parentOp regionIdx) blocks
        |> List.concat


checkBlock : MlirOp -> Int -> Int -> MlirBlock -> List Violation
checkBlock parentOp regionIdx blockIdx block =
    let
        terminator =
            block.terminator

        blockDesc =
            if blockIdx == 0 then
                "entry block"

            else
                "block " ++ String.fromInt blockIdx
    in
    if not (isValidTerminator terminator) then
        [ { opId = parentOp.id
          , opName = parentOp.name
          , message =
                "region "
                    ++ String.fromInt regionIdx
                    ++ " "
                    ++ blockDesc
                    ++ " terminator '"
                    ++ terminator.name
                    ++ "' is not a valid terminator"
          }
        ]

    else if terminator.name == "" then
        [ { opId = parentOp.id
          , opName = parentOp.name
          , message =
                "region "
                    ++ String.fromInt regionIdx
                    ++ " "
                    ++ blockDesc
                    ++ " has empty/missing terminator"
          }
        ]

    else
        []



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


makeModuleWithMaybe : String -> Src.Expr -> Src.Module
makeModuleWithMaybe name expr =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = name
          , args = []
          , tipe = tType "Int" []
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
            violationsToExpectation (checkBlockTerminators mlirModule)



-- TEST CASES


simpleFunctionTest : () -> Expectation
simpleFunctionTest _ =
    -- Simple function should have eco.return terminator
    let
        modul =
            makeModule "testValue" (intExpr 42)
    in
    runInvariantTest modul


ifElseTest : () -> Expectation
ifElseTest _ =
    -- If-then-else should have terminators in both branches
    let
        modul =
            makeModule "testValue"
                (ifExpr (boolExpr True)
                    (intExpr 1)
                    (intExpr 0)
                )
    in
    runInvariantTest modul


caseExprTest : () -> Expectation
caseExprTest _ =
    -- Case expression should have terminators in all branches
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (ctorExpr "Nothing")
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


nestedCaseTest : () -> Expectation
nestedCaseTest _ =
    -- Nested case expressions should all have terminators
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (ctorExpr "Nothing")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , ifExpr (boolExpr True) (varExpr "x") (intExpr 0)
                      )
                    , ( pCtor "Nothing" []
                      , ifExpr (boolExpr False) (intExpr 1) (intExpr 2)
                      )
                    ]
                )
    in
    runInvariantTest modul


listPatternTest : () -> Expectation
listPatternTest _ =
    -- List pattern matching should have terminators
    let
        modul =
            makeModule "testValue"
                (caseExpr (listExpr [ intExpr 1, intExpr 2 ])
                    [ ( pCons (pVar "x") (pVar "rest"), varExpr "x" )
                    , ( pList [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul
