module Compiler.Generate.CodeGen.SingletonConstantsTest exposing (suite)

{-| Tests for CGEN_019: Singleton Constants invariant.

Well-known singletons (Unit, True, False, Nil, Nothing, EmptyString, EmptyRec)
must always use `eco.constant`, never `eco.construct.custom`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , boolExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , recordExpr
        , strExpr
        , tType
        , tVar
        , unitExpr
        )
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
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_019: Singleton Constants"
        [ Test.test "Unit uses eco.constant Unit" unitConstantTest
        , Test.test "True literal uses eco.constant True" trueLiteralTest
        , Test.test "False literal uses eco.constant False" falseLiteralTest
        , Test.test "Empty list (Nil) uses eco.constant Nil" nilConstantTest
        , Test.test "Nothing uses eco.constant Nothing" nothingConstantTest
        , Test.test "Empty record uses eco.constant EmptyRec" emptyRecConstantTest
        , Test.test "eco.construct.custom not used for known singletons" noCustomSingletonsTest
        ]



-- INVARIANT CHECKER


knownSingletons : List String
knownSingletons =
    [ "Unit", "True", "False", "Nil", "Nothing", "EmptyString", "EmptyRec" ]


{-| Check singleton constant invariants.
-}
checkSingletonConstants : MlirModule -> List Violation
checkSingletonConstants mlirModule =
    let
        -- Check eco.constant ops use valid kinds
        constantOps =
            findOpsNamed "eco.constant" mlirModule

        constantViolations =
            List.filterMap checkConstantKind constantOps

        -- Check eco.construct.custom doesn't create singletons
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        customViolations =
            List.filterMap checkForSingletonMisuse customOps

        -- Check eco.string_literal for empty string
        stringOps =
            findOpsNamed "eco.string_literal" mlirModule

        stringViolations =
            List.filterMap checkEmptyStringLiteral stringOps
    in
    constantViolations ++ customViolations ++ stringViolations


checkConstantKind : MlirOp -> Maybe Violation
checkConstantKind op =
    let
        maybeKind =
            getStringAttr "kind" op
    in
    case maybeKind of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.constant missing kind attribute"
                }

        Just kind ->
            if not (List.member kind knownSingletons) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.constant with unknown kind '" ++ kind ++ "'"
                    }

            else
                Nothing


checkForSingletonMisuse : MlirOp -> Maybe Violation
checkForSingletonMisuse op =
    let
        maybeConstructorName =
            getStringAttr "constructor" op

        maybeSize =
            getIntAttr "size" op
    in
    case maybeConstructorName of
        Just name ->
            if List.member name [ "True", "False", "Nothing", "Nil", "Unit" ] then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for singleton '" ++ name ++ "', should use eco.constant"
                    }

            else
                Nothing

        Nothing ->
            -- Check for nullary constructor pattern that might be a singleton
            case maybeSize of
                Just 0 ->
                    -- Could be a nullary constructor - this is OK if it's not a known singleton
                    Nothing

                _ ->
                    Nothing


checkEmptyStringLiteral : MlirOp -> Maybe Violation
checkEmptyStringLiteral op =
    let
        maybeValue =
            getStringAttr "value" op
    in
    case maybeValue of
        Just "" ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "Empty string should use eco.constant EmptyString, not eco.string_literal"
                }

        _ ->
            Nothing



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
            violationsToExpectation (checkSingletonConstants mlirModule)



-- TEST CASES


unitConstantTest : () -> Expectation
unitConstantTest _ =
    runInvariantTest (makeModule "testValue" unitExpr)


trueLiteralTest : () -> Expectation
trueLiteralTest _ =
    runInvariantTest (makeModule "testValue" (boolExpr True))


falseLiteralTest : () -> Expectation
falseLiteralTest _ =
    runInvariantTest (makeModule "testValue" (boolExpr False))


nilConstantTest : () -> Expectation
nilConstantTest _ =
    runInvariantTest (makeModule "testValue" (listExpr []))


nothingConstantTest : () -> Expectation
nothingConstantTest _ =
    runInvariantTest (makeModuleWithMaybe "testValue" (ctorExpr "Nothing"))


emptyRecConstantTest : () -> Expectation
emptyRecConstantTest _ =
    runInvariantTest (makeModule "testValue" (recordExpr []))


noCustomSingletonsTest : () -> Expectation
noCustomSingletonsTest _ =
    -- Test that compiles several values that might tempt codegen to use custom ops
    runInvariantTest
        (makeModule "testValue"
            (listExpr
                [ boolExpr True
                , boolExpr False
                ]
            )
        )
