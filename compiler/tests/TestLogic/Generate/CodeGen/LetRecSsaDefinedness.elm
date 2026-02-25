module TestLogic.Generate.CodeGen.LetRecSsaDefinedness exposing (expectLetRecSsaDefinedness)

{-| Test logic for SSA Definedness in let-rec codegen.

Every SSA value (%name) used as an operand within a function must be defined
somewhere in that function — either as an op result, a block argument, or a
function parameter. This catches the "undeclared SSA value" bug that the
forceResultVar mechanism in Expr.elm is designed to prevent.

For recursive let bindings, placeholder SSA vars (e.g. %helper) are captured
by sibling closures as operands. The forceResultVar mechanism must ensure that
the closure-construction op defines that same placeholder var in its results,
so every use has a corresponding definition.

@docs expectLetRecSsaDefinedness

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that SSA definedness holds for a source module.
-}
expectLetRecSsaDefinedness : Src.Module -> Expectation
expectLetRecSsaDefinedness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkLetRecSsaDefinedness mlirModule)


{-| Check that all SSA operands within each function have definitions.

For each function in the module, collects all SSA definitions (from op results
and block arguments) and all SSA uses (from op operands starting with "%").
Reports any use that has no corresponding definition.

-}
checkLetRecSsaDefinedness : MlirModule -> List Violation
checkLetRecSsaDefinedness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Check a single function for SSA definedness.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        defs =
            collectAllDefs funcOp

        uses =
            collectAllUses funcOp

        undefinedUses =
            Set.diff uses defs
    in
    undefinedUses
        |> Set.toList
        |> List.map
            (\name ->
                { opId = name
                , opName = "func.func @" ++ funcName
                , message =
                    "SSA value '"
                        ++ name
                        ++ "' is used as an operand but never defined in function '"
                        ++ funcName
                        ++ "'"
                }
            )


{-| Collect all SSA definitions in a function (from op results and block args).
-}
collectAllDefs : MlirOp -> Set String
collectAllDefs funcOp =
    List.foldl collectDefsFromRegion Set.empty funcOp.regions


collectDefsFromRegion : MlirRegion -> Set String -> Set String
collectDefsFromRegion (MlirRegion { entry, blocks }) acc =
    let
        withEntry =
            collectDefsFromBlock entry acc
    in
    List.foldl collectDefsFromBlock withEntry (OrderedDict.values blocks)


collectDefsFromBlock : MlirBlock -> Set String -> Set String
collectDefsFromBlock block acc =
    let
        -- Block arguments define SSA values
        withArgs =
            List.foldl (\( name, _ ) s -> Set.insert name s) acc block.args

        -- Op results define SSA values
        withBody =
            List.foldl collectDefsFromOp withArgs block.body
    in
    collectDefsFromOp block.terminator withBody


collectDefsFromOp : MlirOp -> Set String -> Set String
collectDefsFromOp op acc =
    let
        -- Results define SSA values
        withResults =
            List.foldl (\( name, _ ) s -> Set.insert name s) acc op.results
    in
    List.foldl collectDefsFromRegion withResults op.regions


{-| Collect all SSA uses in a function (from op operands starting with "%").
-}
collectAllUses : MlirOp -> Set String
collectAllUses funcOp =
    List.foldl collectUsesFromRegion Set.empty funcOp.regions


collectUsesFromRegion : MlirRegion -> Set String -> Set String
collectUsesFromRegion (MlirRegion { entry, blocks }) acc =
    let
        withEntry =
            collectUsesFromBlock entry acc
    in
    List.foldl collectUsesFromBlock withEntry (OrderedDict.values blocks)


collectUsesFromBlock : MlirBlock -> Set String -> Set String
collectUsesFromBlock block acc =
    let
        withBody =
            List.foldl collectUsesFromOp acc block.body
    in
    collectUsesFromOp block.terminator withBody


collectUsesFromOp : MlirOp -> Set String -> Set String
collectUsesFromOp op acc =
    let
        -- Only count operands that look like SSA values (start with "%")
        ssaOperands =
            List.filter (\name -> String.startsWith "%" name) op.operands

        withOperands =
            List.foldl Set.insert acc ssaOperands
    in
    List.foldl collectUsesFromRegion withOperands op.regions
