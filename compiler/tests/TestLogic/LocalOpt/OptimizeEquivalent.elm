module TestLogic.LocalOpt.OptimizeEquivalent exposing (expectEquivalentOptimization)

{-| Test infrastructure for verifying Erased and Typed optimization paths produce equivalent results.

This module compares the output of:

  - `Optimize.Erased.Module.optimize` (produces `Opt.LocalGraph`)
  - `Optimize.Typed.Module.optimizeTyped` (produces `TOpt.LocalGraph`)

The two IRs are structurally identical except that TypedOptimized carries
`Can.Type` on every expression and definition. This test verifies that
ignoring types, the structures are exactly the same.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Path as Path
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.LocalOpt.Erased.DecisionTree as DT
import Compiler.LocalOpt.Erased.Module as ErasedOptimize
import Compiler.LocalOpt.Typed.DecisionTree as TDT
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Erased.Module as ConstrainErased
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Expect
import System.TypeCheck.IO as IO
import TestLogic.TestPipeline as Pipeline


{-| Verify that Erased and Typed optimization paths produce equivalent results.

Both paths should produce structurally identical IRs (ignoring type annotations
in the Typed version).

-}
expectEquivalentOptimization : Src.Module -> Expect.Expectation
expectEquivalentOptimization srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case Result.run canonResult of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                errorCount =
                    List.length errorList
            in
            Expect.fail
                ("Canonicalization failed with "
                    ++ String.fromInt errorCount
                    ++ " error(s)"
                )

        ( _, Ok canModule ) ->
            -- Run type checking to get annotations
            let
                standardTypeCheck =
                    IO.unsafePerformIO (runStandardTypeCheck canModule)

                withIdsTypeCheck =
                    IO.unsafePerformIO (Pipeline.runWithIdsTypeCheck canModule)
            in
            case ( standardTypeCheck, withIdsTypeCheck ) of
                ( Err errCount, _ ) ->
                    Expect.fail
                        ("Standard type checking failed with "
                            ++ String.fromInt errCount
                            ++ " error(s)"
                        )

                ( _, Err errCount ) ->
                    Expect.fail
                        ("WithIds type checking failed with "
                            ++ String.fromInt errCount
                            ++ " error(s)"
                        )

                ( Ok annotations, Ok typedData ) ->
                    -- Run both optimization paths
                    let
                        erasedResult =
                            runErasedOptimization annotations canModule

                        typedResult =
                            runTypedOptimization typedData.annotations typedData.nodeTypes canModule
                    in
                    case ( erasedResult, typedResult ) of
                        ( Err erasedErr, _ ) ->
                            Expect.fail ("Erased optimization failed: " ++ erasedErr)

                        ( _, Err typedErr ) ->
                            Expect.fail ("Typed optimization failed: " ++ typedErr)

                        ( Ok erasedGraph, Ok typedGraph ) ->
                            -- Compare the two graphs
                            case compareLocalGraphs erasedGraph typedGraph of
                                Nothing ->
                                    Expect.pass

                                Just mismatch ->
                                    Expect.fail
                                        ("Optimization results differ:\n" ++ mismatch)



-- ============================================================================
-- TYPE CHECKING RUNNERS
-- ============================================================================


runStandardTypeCheck : Can.Module -> IO.IO (Result Int (Dict String Name.Name Can.Annotation))
runStandardTypeCheck modul =
    ConstrainErased.constrain modul
        |> IO.andThen Solve.run
        |> IO.map
            (\result ->
                case result of
                    Ok annotations ->
                        Ok annotations

                    Err (NE.Nonempty _ rest) ->
                        Err (1 + List.length rest)
            )



-- ============================================================================
-- OPTIMIZATION RUNNERS
-- ============================================================================


runErasedOptimization : Dict String Name.Name Can.Annotation -> Can.Module -> Result String Opt.LocalGraph
runErasedOptimization annotations canModule =
    case Result.run (ErasedOptimize.optimize annotations canModule) of
        ( _, Ok graph ) ->
            Ok graph

        ( _, Err _ ) ->
            Err "Erased optimization produced an error"


runTypedOptimization : Dict String Name.Name Can.Annotation -> Dict Int Int Can.Type -> Can.Module -> Result String TOpt.LocalGraph
runTypedOptimization annotations exprTypes canModule =
    let
        -- Run PostSolve to fix Group B types and compute kernel env
        postSolveResult =
            PostSolve.postSolve annotations canModule exprTypes

        fixedNodeTypes =
            postSolveResult.nodeTypes

        kernelEnv =
            postSolveResult.kernelEnv

        typedModule =
            TCanBuild.fromCanonical canModule fixedNodeTypes
    in
    case Result.run (TypedOptimize.optimizeTyped annotations fixedNodeTypes kernelEnv typedModule) of
        ( _, Ok graph ) ->
            Ok graph

        ( _, Err _ ) ->
            Err "Typed optimization produced an error"



-- ============================================================================
-- LOCAL GRAPH COMPARISON
-- ============================================================================


compareLocalGraphs : Opt.LocalGraph -> TOpt.LocalGraph -> Maybe String
compareLocalGraphs (Opt.LocalGraph erasedMain erasedNodes erasedFields) (TOpt.LocalGraph typedData) =
    -- Compare main
    case compareMains erasedMain typedData.main of
        Just err ->
            Just ("Main mismatch: " ++ err)

        Nothing ->
            -- Compare nodes
            case compareNodeDicts erasedNodes typedData.nodes of
                Just err ->
                    Just ("Nodes mismatch: " ++ err)

                Nothing ->
                    -- Compare fields
                    if erasedFields == typedData.fields then
                        Nothing

                    else
                        Just "Fields dictionaries differ"


compareMains : Maybe Opt.Main -> Maybe TOpt.Main -> Maybe String
compareMains erasedMain typedMain =
    case ( erasedMain, typedMain ) of
        ( Nothing, Nothing ) ->
            Nothing

        ( Just Opt.Static, Just TOpt.Static ) ->
            Nothing

        ( Just (Opt.Dynamic _ erasedExpr), Just (TOpt.Dynamic _ typedExpr) ) ->
            -- Ignore the Can.Type, compare expressions
            compareExprs erasedExpr typedExpr

        ( Nothing, Just _ ) ->
            Just "Erased has no main but Typed does"

        ( Just _, Nothing ) ->
            Just "Erased has main but Typed does not"

        ( Just Opt.Static, Just (TOpt.Dynamic _ _) ) ->
            Just "Erased has Static main but Typed has Dynamic"

        ( Just (Opt.Dynamic _ _), Just TOpt.Static ) ->
            Just "Erased has Dynamic main but Typed has Static"


compareNodeDicts : Dict (List String) Opt.Global Opt.Node -> Dict (List String) TOpt.Global TOpt.Node -> Maybe String
compareNodeDicts erasedNodes typedNodes =
    let
        erasedKeys =
            Dict.keys Opt.compareGlobal erasedNodes
                |> List.map Opt.toComparableGlobal

        typedKeys =
            Dict.keys TOpt.compareGlobal typedNodes
                |> List.map TOpt.toComparableGlobal
    in
    if erasedKeys /= typedKeys then
        Just
            ("Different node keys. Erased: "
                ++ String.fromInt (List.length erasedKeys)
                ++ ", Typed: "
                ++ String.fromInt (List.length typedKeys)
            )

    else
        -- Compare each node by iterating over erased nodes
        let
            erasedNodeList =
                Dict.keys Opt.compareGlobal erasedNodes

            comparePair (Opt.Global home name) =
                let
                    key =
                        Opt.toComparableGlobal (Opt.Global home name)

                    typedGlobal =
                        TOpt.Global home name
                in
                case ( Dict.get Opt.toComparableGlobal (Opt.Global home name) erasedNodes, Dict.get TOpt.toComparableGlobal typedGlobal typedNodes ) of
                    ( Just erasedNode, Just typedNode ) ->
                        case compareNodes erasedNode typedNode of
                            Nothing ->
                                Nothing

                            Just err ->
                                Just ("Node " ++ String.join "." key ++ ": " ++ err)

                    _ ->
                        Just ("Missing node: " ++ String.join "." key)

            mismatches =
                List.filterMap comparePair erasedNodeList
        in
        List.head mismatches



-- ============================================================================
-- NODE COMPARISON
-- ============================================================================


compareNodes : Opt.Node -> TOpt.Node -> Maybe String
compareNodes erasedNode typedNode =
    case ( erasedNode, typedNode ) of
        ( Opt.Define erasedExpr erasedDeps, TOpt.Define typedExpr typedDeps _ ) ->
            compareDepsAndExpr erasedDeps typedDeps erasedExpr typedExpr

        ( Opt.TrackedDefine region1 erasedExpr erasedDeps, TOpt.TrackedDefine region2 typedExpr typedDeps _ ) ->
            if region1 /= region2 then
                Just "TrackedDefine region mismatch"

            else
                compareDepsAndExpr erasedDeps typedDeps erasedExpr typedExpr

        ( Opt.Ctor idx1 arity1, TOpt.Ctor idx2 arity2 _ ) ->
            if idx1 /= idx2 then
                Just "Ctor index mismatch"

            else if arity1 /= arity2 then
                Just "Ctor arity mismatch"

            else
                Nothing

        ( Opt.Enum idx1, TOpt.Enum idx2 _ ) ->
            if idx1 /= idx2 then
                Just "Enum index mismatch"

            else
                Nothing

        ( Opt.Box, TOpt.Box _ ) ->
            Nothing

        ( Opt.Link (Opt.Global home1 name1), TOpt.Link (TOpt.Global home2 name2) ) ->
            if home1 /= home2 || name1 /= name2 then
                Just "Link target mismatch"

            else
                Nothing

        ( Opt.Cycle names1 values1 defs1 deps1, TOpt.Cycle names2 values2 defs2 deps2 ) ->
            if names1 /= names2 then
                Just "Cycle names mismatch"

            else if not (compareDeps deps1 deps2) then
                Just "Cycle deps mismatch"

            else
                case compareNameExprPairs values1 values2 of
                    Just err ->
                        Just ("Cycle values: " ++ err)

                    Nothing ->
                        compareDefLists defs1 defs2

        ( Opt.Manager eff1, TOpt.Manager eff2 ) ->
            if compareEffectsType eff1 eff2 then
                Nothing

            else
                Just "Manager effects type mismatch"

        ( Opt.Kernel chunks1 deps1, TOpt.Kernel chunks2 deps2 ) ->
            if chunks1 /= chunks2 then
                Just "Kernel chunks mismatch"

            else if not (compareDeps deps1 deps2) then
                Just "Kernel deps mismatch"

            else
                Nothing

        ( Opt.PortIncoming erasedExpr erasedDeps, TOpt.PortIncoming typedExpr typedDeps _ ) ->
            compareDepsAndExpr erasedDeps typedDeps erasedExpr typedExpr

        ( Opt.PortOutgoing erasedExpr erasedDeps, TOpt.PortOutgoing typedExpr typedDeps _ ) ->
            compareDepsAndExpr erasedDeps typedDeps erasedExpr typedExpr

        _ ->
            Just
                ("Node type mismatch: "
                    ++ nodeTypeName erasedNode
                    ++ " vs "
                    ++ typedNodeTypeName typedNode
                )


nodeTypeName : Opt.Node -> String
nodeTypeName node =
    case node of
        Opt.Define _ _ ->
            "Define"

        Opt.TrackedDefine _ _ _ ->
            "TrackedDefine"

        Opt.Ctor _ _ ->
            "Ctor"

        Opt.Enum _ ->
            "Enum"

        Opt.Box ->
            "Box"

        Opt.Link _ ->
            "Link"

        Opt.Cycle _ _ _ _ ->
            "Cycle"

        Opt.Manager _ ->
            "Manager"

        Opt.Kernel _ _ ->
            "Kernel"

        Opt.PortIncoming _ _ ->
            "PortIncoming"

        Opt.PortOutgoing _ _ ->
            "PortOutgoing"


typedNodeTypeName : TOpt.Node -> String
typedNodeTypeName node =
    case node of
        TOpt.Define _ _ _ ->
            "Define"

        TOpt.TrackedDefine _ _ _ _ ->
            "TrackedDefine"

        TOpt.Ctor _ _ _ ->
            "Ctor"

        TOpt.Enum _ _ ->
            "Enum"

        TOpt.Box _ ->
            "Box"

        TOpt.Link _ ->
            "Link"

        TOpt.Cycle _ _ _ _ ->
            "Cycle"

        TOpt.Manager _ ->
            "Manager"

        TOpt.Kernel _ _ ->
            "Kernel"

        TOpt.PortIncoming _ _ _ ->
            "PortIncoming"

        TOpt.PortOutgoing _ _ _ ->
            "PortOutgoing"


compareDepsAndExpr : EverySet (List String) Opt.Global -> EverySet (List String) TOpt.Global -> Opt.Expr -> TOpt.Expr -> Maybe String
compareDepsAndExpr erasedDeps typedDeps erasedExpr typedExpr =
    if not (compareDeps erasedDeps typedDeps) then
        Just "Dependencies mismatch"

    else
        compareExprs erasedExpr typedExpr


compareDeps : EverySet (List String) Opt.Global -> EverySet (List String) TOpt.Global -> Bool
compareDeps erasedDeps typedDeps =
    let
        erasedList =
            EverySet.toList Opt.compareGlobal erasedDeps |> List.map Opt.toComparableGlobal |> List.sort

        typedList =
            EverySet.toList TOpt.compareGlobal typedDeps |> List.map TOpt.toComparableGlobal |> List.sort
    in
    erasedList == typedList


compareEffectsType : Opt.EffectsType -> TOpt.EffectsType -> Bool
compareEffectsType eff1 eff2 =
    case ( eff1, eff2 ) of
        ( Opt.Cmd, TOpt.Cmd ) ->
            True

        ( Opt.Sub, TOpt.Sub ) ->
            True

        ( Opt.Fx, TOpt.Fx ) ->
            True

        _ ->
            False



-- ============================================================================
-- EXPRESSION COMPARISON
-- ============================================================================


compareExprs : Opt.Expr -> TOpt.Expr -> Maybe String
compareExprs erasedExpr typedExpr =
    case ( erasedExpr, typedExpr ) of
        ( Opt.Bool r1 b1, TOpt.Bool r2 b2 _ ) ->
            compareRegionAndValue r1 r2 b1 b2 "Bool"

        ( Opt.Chr r1 s1, TOpt.Chr r2 s2 _ ) ->
            compareRegionAndValue r1 r2 s1 s2 "Chr"

        ( Opt.Str r1 s1, TOpt.Str r2 s2 _ ) ->
            compareRegionAndValue r1 r2 s1 s2 "Str"

        ( Opt.Int r1 i1, TOpt.Int r2 i2 _ ) ->
            compareRegionAndValue r1 r2 i1 i2 "Int"

        ( Opt.Float r1 f1, TOpt.Float r2 f2 _ ) ->
            if r1 /= r2 then
                Just "Float region mismatch"

            else if not (floatsEqual f1 f2) then
                Just ("Float value mismatch: " ++ String.fromFloat f1 ++ " vs " ++ String.fromFloat f2)

            else
                Nothing

        ( Opt.VarLocal n1, TOpt.VarLocal n2 _ ) ->
            if n1 == n2 then
                Nothing

            else
                Just ("VarLocal name mismatch: " ++ n1 ++ " vs " ++ n2)

        ( Opt.TrackedVarLocal r1 n1, TOpt.TrackedVarLocal r2 n2 _ ) ->
            compareRegionAndValue r1 r2 n1 n2 "TrackedVarLocal"

        ( Opt.VarGlobal r1 (Opt.Global home1 name1), TOpt.VarGlobal r2 (TOpt.Global home2 name2) _ ) ->
            if r1 /= r2 then
                Just "VarGlobal region mismatch"

            else if home1 /= home2 || name1 /= name2 then
                Just "VarGlobal target mismatch"

            else
                Nothing

        ( Opt.VarEnum r1 (Opt.Global home1 name1) idx1, TOpt.VarEnum r2 (TOpt.Global home2 name2) idx2 _ ) ->
            if r1 /= r2 then
                Just "VarEnum region mismatch"

            else if home1 /= home2 || name1 /= name2 then
                Just "VarEnum global mismatch"

            else if idx1 /= idx2 then
                Just "VarEnum index mismatch"

            else
                Nothing

        ( Opt.VarBox r1 (Opt.Global home1 name1), TOpt.VarBox r2 (TOpt.Global home2 name2) _ ) ->
            if r1 /= r2 then
                Just "VarBox region mismatch"

            else if home1 /= home2 || name1 /= name2 then
                Just "VarBox global mismatch"

            else
                Nothing

        ( Opt.VarCycle r1 home1 n1, TOpt.VarCycle r2 home2 n2 _ ) ->
            if r1 /= r2 then
                Just "VarCycle region mismatch"

            else if home1 /= home2 || n1 /= n2 then
                Just "VarCycle target mismatch"

            else
                Nothing

        ( Opt.VarDebug r1 n1 home1 m1, TOpt.VarDebug r2 n2 home2 m2 _ ) ->
            if r1 /= r2 || n1 /= n2 || home1 /= home2 || m1 /= m2 then
                Just "VarDebug mismatch"

            else
                Nothing

        ( Opt.VarKernel r1 home1 n1, TOpt.VarKernel r2 home2 n2 _ ) ->
            if r1 /= r2 || home1 /= home2 || n1 /= n2 then
                Just "VarKernel mismatch"

            else
                Nothing

        ( Opt.List r1 items1, TOpt.List r2 items2 _ ) ->
            if r1 /= r2 then
                Just "List region mismatch"

            else
                compareExprLists items1 items2

        ( Opt.Function args1 body1, TOpt.Function args2 body2 _ ) ->
            if args1 /= List.map Tuple.first args2 then
                Just "Function args mismatch"

            else
                compareExprs body1 body2

        ( Opt.TrackedFunction args1 body1, TOpt.TrackedFunction args2 body2 _ ) ->
            if args1 /= List.map Tuple.first args2 then
                Just "TrackedFunction args mismatch"

            else
                compareExprs body1 body2

        ( Opt.Call r1 func1 args1, TOpt.Call r2 func2 args2 _ ) ->
            if r1 /= r2 then
                Just "Call region mismatch"

            else
                case compareExprs func1 func2 of
                    Just err ->
                        Just ("Call func: " ++ err)

                    Nothing ->
                        compareExprLists args1 args2

        ( Opt.TailCall n1 args1, TOpt.TailCall n2 args2 _ ) ->
            if n1 /= n2 then
                Just "TailCall name mismatch"

            else
                compareNameExprPairs args1 args2

        ( Opt.If branches1 else1, TOpt.If branches2 else2 _ ) ->
            case compareBranchLists branches1 branches2 of
                Just err ->
                    Just ("If branches: " ++ err)

                Nothing ->
                    compareExprs else1 else2

        ( Opt.Let def1 body1, TOpt.Let def2 body2 _ ) ->
            case compareDefs def1 def2 of
                Just err ->
                    Just ("Let def: " ++ err)

                Nothing ->
                    compareExprs body1 body2

        ( Opt.Destruct destr1 body1, TOpt.Destruct destr2 body2 _ ) ->
            case compareDestructors destr1 destr2 of
                Just err ->
                    Just ("Destruct: " ++ err)

                Nothing ->
                    compareExprs body1 body2

        ( Opt.Case label1 root1 decider1 jumps1, TOpt.Case label2 root2 decider2 jumps2 _ ) ->
            if label1 /= label2 then
                Just "Case label mismatch"

            else if root1 /= root2 then
                Just "Case root mismatch"

            else
                case compareDeciders decider1 decider2 of
                    Just err ->
                        Just ("Case decider: " ++ err)

                    Nothing ->
                        compareJumpLists jumps1 jumps2

        ( Opt.Accessor r1 n1, TOpt.Accessor r2 n2 _ ) ->
            compareRegionAndValue r1 r2 n1 n2 "Accessor"

        ( Opt.Access rec1 r1 n1, TOpt.Access rec2 r2 n2 _ ) ->
            if r1 /= r2 then
                Just "Access region mismatch"

            else if n1 /= n2 then
                Just "Access field mismatch"

            else
                compareExprs rec1 rec2

        ( Opt.Update r1 rec1 fields1, TOpt.Update r2 rec2 fields2 _ ) ->
            if r1 /= r2 then
                Just "Update region mismatch"

            else
                case compareExprs rec1 rec2 of
                    Just err ->
                        Just ("Update record: " ++ err)

                    Nothing ->
                        compareFieldDicts fields1 fields2

        ( Opt.Record fields1, TOpt.Record fields2 _ ) ->
            compareRecordFields fields1 fields2

        ( Opt.TrackedRecord r1 fields1, TOpt.TrackedRecord r2 fields2 _ ) ->
            if r1 /= r2 then
                Just "TrackedRecord region mismatch"

            else
                compareFieldDicts fields1 fields2

        ( Opt.Unit, TOpt.Unit _ ) ->
            Nothing

        ( Opt.Tuple r1 a1 b1 rest1, TOpt.Tuple r2 a2 b2 rest2 _ ) ->
            if r1 /= r2 then
                Just "Tuple region mismatch"

            else
                case compareExprs a1 a2 of
                    Just err ->
                        Just ("Tuple first: " ++ err)

                    Nothing ->
                        case compareExprs b1 b2 of
                            Just err ->
                                Just ("Tuple second: " ++ err)

                            Nothing ->
                                compareExprLists rest1 rest2

        ( Opt.Shader src1 attrs1 unis1, TOpt.Shader src2 attrs2 unis2 _ ) ->
            if src1 /= src2 then
                Just "Shader source mismatch"

            else if attrs1 /= attrs2 then
                Just "Shader attributes mismatch"

            else if unis1 /= unis2 then
                Just "Shader uniforms mismatch"

            else
                Nothing

        _ ->
            Just
                ("Expression type mismatch: "
                    ++ exprTypeName erasedExpr
                    ++ " vs "
                    ++ typedExprTypeName typedExpr
                )


exprTypeName : Opt.Expr -> String
exprTypeName expr =
    case expr of
        Opt.Bool _ _ ->
            "Bool"

        Opt.Chr _ _ ->
            "Chr"

        Opt.Str _ _ ->
            "Str"

        Opt.Int _ _ ->
            "Int"

        Opt.Float _ _ ->
            "Float"

        Opt.VarLocal _ ->
            "VarLocal"

        Opt.TrackedVarLocal _ _ ->
            "TrackedVarLocal"

        Opt.VarGlobal _ _ ->
            "VarGlobal"

        Opt.VarEnum _ _ _ ->
            "VarEnum"

        Opt.VarBox _ _ ->
            "VarBox"

        Opt.VarCycle _ _ _ ->
            "VarCycle"

        Opt.VarDebug _ _ _ _ ->
            "VarDebug"

        Opt.VarKernel _ _ _ ->
            "VarKernel"

        Opt.List _ _ ->
            "List"

        Opt.Function _ _ ->
            "Function"

        Opt.TrackedFunction _ _ ->
            "TrackedFunction"

        Opt.Call _ _ _ ->
            "Call"

        Opt.TailCall _ _ ->
            "TailCall"

        Opt.If _ _ ->
            "If"

        Opt.Let _ _ ->
            "Let"

        Opt.Destruct _ _ ->
            "Destruct"

        Opt.Case _ _ _ _ ->
            "Case"

        Opt.Accessor _ _ ->
            "Accessor"

        Opt.Access _ _ _ ->
            "Access"

        Opt.Update _ _ _ ->
            "Update"

        Opt.Record _ ->
            "Record"

        Opt.TrackedRecord _ _ ->
            "TrackedRecord"

        Opt.Unit ->
            "Unit"

        Opt.Tuple _ _ _ _ ->
            "Tuple"

        Opt.Shader _ _ _ ->
            "Shader"


typedExprTypeName : TOpt.Expr -> String
typedExprTypeName expr =
    case expr of
        TOpt.Bool _ _ _ ->
            "Bool"

        TOpt.Chr _ _ _ ->
            "Chr"

        TOpt.Str _ _ _ ->
            "Str"

        TOpt.Int _ _ _ ->
            "Int"

        TOpt.Float _ _ _ ->
            "Float"

        TOpt.VarLocal _ _ ->
            "VarLocal"

        TOpt.TrackedVarLocal _ _ _ ->
            "TrackedVarLocal"

        TOpt.VarGlobal _ _ _ ->
            "VarGlobal"

        TOpt.VarEnum _ _ _ _ ->
            "VarEnum"

        TOpt.VarBox _ _ _ ->
            "VarBox"

        TOpt.VarCycle _ _ _ _ ->
            "VarCycle"

        TOpt.VarDebug _ _ _ _ _ ->
            "VarDebug"

        TOpt.VarKernel _ _ _ _ ->
            "VarKernel"

        TOpt.List _ _ _ ->
            "List"

        TOpt.Function _ _ _ ->
            "Function"

        TOpt.TrackedFunction _ _ _ ->
            "TrackedFunction"

        TOpt.Call _ _ _ _ ->
            "Call"

        TOpt.TailCall _ _ _ ->
            "TailCall"

        TOpt.If _ _ _ ->
            "If"

        TOpt.Let _ _ _ ->
            "Let"

        TOpt.Destruct _ _ _ ->
            "Destruct"

        TOpt.Case _ _ _ _ _ ->
            "Case"

        TOpt.Accessor _ _ _ ->
            "Accessor"

        TOpt.Access _ _ _ _ ->
            "Access"

        TOpt.Update _ _ _ _ ->
            "Update"

        TOpt.Record _ _ ->
            "Record"

        TOpt.TrackedRecord _ _ _ ->
            "TrackedRecord"

        TOpt.Unit _ ->
            "Unit"

        TOpt.Tuple _ _ _ _ _ ->
            "Tuple"

        TOpt.Shader _ _ _ _ ->
            "Shader"



-- ============================================================================
-- HELPER COMPARISON FUNCTIONS
-- ============================================================================


compareRegionAndValue : A.Region -> A.Region -> a -> a -> String -> Maybe String
compareRegionAndValue r1 r2 v1 v2 name =
    if r1 /= r2 then
        Just (name ++ " region mismatch")

    else if v1 /= v2 then
        Just (name ++ " value mismatch")

    else
        Nothing


{-| Compare two floats with NaN-aware equality.
In IEEE 754, NaN /= NaN, but for our purposes if both are NaN they should be considered equal.
-}
floatsEqual : Float -> Float -> Bool
floatsEqual a b =
    if isNaN a && isNaN b then
        True

    else
        a == b


compareExprLists : List Opt.Expr -> List TOpt.Expr -> Maybe String
compareExprLists erasedList typedList =
    if List.length erasedList /= List.length typedList then
        Just
            ("List length mismatch: "
                ++ String.fromInt (List.length erasedList)
                ++ " vs "
                ++ String.fromInt (List.length typedList)
            )

    else
        List.map2 compareExprs erasedList typedList
            |> List.filterMap identity
            |> List.head


compareNameExprPairs : List ( Name.Name, Opt.Expr ) -> List ( Name.Name, TOpt.Expr ) -> Maybe String
compareNameExprPairs erasedPairs typedPairs =
    if List.length erasedPairs /= List.length typedPairs then
        Just "Pairs list length mismatch"

    else
        let
            comparePair ( n1, e1 ) ( n2, e2 ) =
                if n1 /= n2 then
                    Just ("Name mismatch: " ++ n1 ++ " vs " ++ n2)

                else
                    compareExprs e1 e2
        in
        List.map2 comparePair erasedPairs typedPairs
            |> List.filterMap identity
            |> List.head


compareBranchLists : List ( Opt.Expr, Opt.Expr ) -> List ( TOpt.Expr, TOpt.Expr ) -> Maybe String
compareBranchLists erasedBranches typedBranches =
    if List.length erasedBranches /= List.length typedBranches then
        Just "Branch list length mismatch"

    else
        let
            compareBranch ( cond1, body1 ) ( cond2, body2 ) =
                case compareExprs cond1 cond2 of
                    Just err ->
                        Just ("Branch condition: " ++ err)

                    Nothing ->
                        compareExprs body1 body2
        in
        List.map2 compareBranch erasedBranches typedBranches
            |> List.filterMap identity
            |> List.head


compareJumpLists : List ( Int, Opt.Expr ) -> List ( Int, TOpt.Expr ) -> Maybe String
compareJumpLists erasedJumps typedJumps =
    if List.length erasedJumps /= List.length typedJumps then
        Just "Jump list length mismatch"

    else
        let
            compareJump ( idx1, expr1 ) ( idx2, expr2 ) =
                if idx1 /= idx2 then
                    Just ("Jump index mismatch: " ++ String.fromInt idx1 ++ " vs " ++ String.fromInt idx2)

                else
                    compareExprs expr1 expr2
        in
        List.map2 compareJump erasedJumps typedJumps
            |> List.filterMap identity
            |> List.head


compareFieldDicts : Dict String (A.Located Name.Name) Opt.Expr -> Dict String (A.Located Name.Name) TOpt.Expr -> Maybe String
compareFieldDicts erasedFields typedFields =
    let
        locatedToComparable (A.At _ name) =
            name

        compareLocated a b =
            A.compareLocated a b

        erasedKeys =
            Dict.keys compareLocated erasedFields

        typedKeys =
            Dict.keys compareLocated typedFields

        erasedComparableKeys =
            List.map locatedToComparable erasedKeys

        typedComparableKeys =
            List.map locatedToComparable typedKeys
    in
    if erasedComparableKeys /= typedComparableKeys then
        Just "Field keys mismatch"

    else
        let
            compareField locKey =
                case ( Dict.get locatedToComparable locKey erasedFields, Dict.get locatedToComparable locKey typedFields ) of
                    ( Just e1, Just e2 ) ->
                        compareExprs e1 e2

                    _ ->
                        Just ("Missing field: " ++ locatedToComparable locKey)
        in
        List.filterMap compareField erasedKeys |> List.head


compareRecordFields : Dict String Name.Name Opt.Expr -> Dict String Name.Name TOpt.Expr -> Maybe String
compareRecordFields erasedFields typedFields =
    let
        compareNames a b =
            Basics.compare a b

        erasedKeys =
            Dict.keys compareNames erasedFields

        typedKeys =
            Dict.keys compareNames typedFields
    in
    if erasedKeys /= typedKeys then
        Just "Record field keys mismatch"

    else
        let
            compareField key =
                case ( Dict.get identity key erasedFields, Dict.get identity key typedFields ) of
                    ( Just e1, Just e2 ) ->
                        compareExprs e1 e2

                    _ ->
                        Just ("Missing record field: " ++ key)
        in
        List.filterMap compareField erasedKeys |> List.head


compareLocatedNameLists : List (A.Located Name.Name) -> List (A.Located Name.Name) -> Bool
compareLocatedNameLists list1 list2 =
    list1 == list2



-- ============================================================================
-- DEFINITION COMPARISON
-- ============================================================================


compareDefs : Opt.Def -> TOpt.Def -> Maybe String
compareDefs erasedDef typedDef =
    case ( erasedDef, typedDef ) of
        ( Opt.Def r1 n1 e1, TOpt.Def r2 n2 e2 _ ) ->
            if r1 /= r2 then
                Just "Def region mismatch"

            else if n1 /= n2 then
                Just ("Def name mismatch: " ++ n1 ++ " vs " ++ n2)

            else
                compareExprs e1 e2

        ( Opt.TailDef r1 n1 args1 e1, TOpt.TailDef r2 n2 args2 e2 _ ) ->
            if r1 /= r2 then
                Just "TailDef region mismatch"

            else if n1 /= n2 then
                Just ("TailDef name mismatch: " ++ n1 ++ " vs " ++ n2)

            else if args1 /= List.map Tuple.first args2 then
                Just "TailDef args mismatch"

            else
                compareExprs e1 e2

        _ ->
            Just "Def type mismatch (Def vs TailDef)"


compareDefLists : List Opt.Def -> List TOpt.Def -> Maybe String
compareDefLists erasedDefs typedDefs =
    if List.length erasedDefs /= List.length typedDefs then
        Just "Def list length mismatch"

    else
        List.map2 compareDefs erasedDefs typedDefs
            |> List.filterMap identity
            |> List.head


compareDestructors : Opt.Destructor -> TOpt.Destructor -> Maybe String
compareDestructors (Opt.Destructor n1 p1) (TOpt.Destructor n2 p2 _) =
    if n1 /= n2 then
        Just ("Destructor name mismatch: " ++ n1 ++ " vs " ++ n2)

    else
        comparePaths p1 p2


comparePaths : Opt.Path -> TOpt.Path -> Maybe String
comparePaths erasedPath typedPath =
    case ( erasedPath, typedPath ) of
        ( Opt.Index idx1 rest1, TOpt.Index idx2 _ rest2 ) ->
            if idx1 /= idx2 then
                Just "Path Index mismatch"

            else
                comparePaths rest1 rest2

        ( Opt.ArrayIndex idx1 rest1, TOpt.ArrayIndex idx2 rest2 ) ->
            if idx1 /= idx2 then
                Just "Path ArrayIndex mismatch"

            else
                comparePaths rest1 rest2

        ( Opt.Field n1 rest1, TOpt.Field n2 rest2 ) ->
            if n1 /= n2 then
                Just ("Path Field mismatch: " ++ n1 ++ " vs " ++ n2)

            else
                comparePaths rest1 rest2

        ( Opt.Unbox rest1, TOpt.Unbox rest2 ) ->
            comparePaths rest1 rest2

        ( Opt.Root n1, TOpt.Root n2 ) ->
            if n1 /= n2 then
                Just ("Path Root mismatch: " ++ n1 ++ " vs " ++ n2)

            else
                Nothing

        _ ->
            Just "Path type mismatch"



-- ============================================================================
-- DECIDER COMPARISON
-- ============================================================================


compareDeciders : Opt.Decider Opt.Choice -> TOpt.Decider TOpt.Choice -> Maybe String
compareDeciders erasedDecider typedDecider =
    case ( erasedDecider, typedDecider ) of
        ( Opt.Leaf choice1, TOpt.Leaf choice2 ) ->
            compareChoices choice1 choice2

        ( Opt.Chain tests1 success1 failure1, TOpt.Chain tests2 success2 failure2 ) ->
            case compareDTTestLists tests1 tests2 of
                Just err ->
                    Just ("Chain tests: " ++ err)

                Nothing ->
                    case compareDeciders success1 success2 of
                        Just err ->
                            Just ("Chain success: " ++ err)

                        Nothing ->
                            compareDeciders failure1 failure2

        ( Opt.FanOut path1 options1 fallback1, TOpt.FanOut path2 options2 fallback2 ) ->
            case compareDTPaths path1 path2 of
                Just err ->
                    Just ("FanOut path: " ++ err)

                Nothing ->
                    case compareOptionLists options1 options2 of
                        Just err ->
                            Just ("FanOut options: " ++ err)

                        Nothing ->
                            compareDeciders fallback1 fallback2

        _ ->
            Just "Decider type mismatch"


compareChoices : Opt.Choice -> TOpt.Choice -> Maybe String
compareChoices erasedChoice typedChoice =
    case ( erasedChoice, typedChoice ) of
        ( Opt.Inline e1, TOpt.Inline e2 ) ->
            compareExprs e1 e2

        ( Opt.Jump idx1, TOpt.Jump idx2 ) ->
            if idx1 /= idx2 then
                Just ("Jump index mismatch: " ++ String.fromInt idx1 ++ " vs " ++ String.fromInt idx2)

            else
                Nothing

        _ ->
            Just "Choice type mismatch (Inline vs Jump)"


compareOptionLists : List ( DT.Test, Opt.Decider Opt.Choice ) -> List ( TDT.Test, TOpt.Decider TOpt.Choice ) -> Maybe String
compareOptionLists erasedOptions typedOptions =
    if List.length erasedOptions /= List.length typedOptions then
        Just "Options list length mismatch"

    else
        let
            compareOption ( test1, decider1 ) ( test2, decider2 ) =
                case compareDTTests test1 test2 of
                    Just err ->
                        Just err

                    Nothing ->
                        compareDeciders decider1 decider2
        in
        List.map2 compareOption erasedOptions typedOptions
            |> List.filterMap identity
            |> List.head


compareDTTestLists : List ( DT.Path, DT.Test ) -> List ( TDT.Path, TDT.Test ) -> Maybe String
compareDTTestLists erasedTests typedTests =
    if List.length erasedTests /= List.length typedTests then
        Just "Chain tests length mismatch"

    else
        let
            compareTest ( path1, test1 ) ( path2, test2 ) =
                case compareDTPaths path1 path2 of
                    Just err ->
                        Just err

                    Nothing ->
                        compareDTTests test1 test2
        in
        List.map2 compareTest erasedTests typedTests
            |> List.filterMap identity
            |> List.head


compareDTPaths : DT.Path -> TDT.Path -> Maybe String
compareDTPaths erasedPath typedPath =
    case ( erasedPath, typedPath ) of
        ( Path.Empty, TypedPath.Empty ) ->
            Nothing

        ( Path.Index idx1 rest1, TypedPath.Index idx2 _ rest2 ) ->
            -- Ignore ContainerHint in typed path; just compare index and rest
            if idx1 /= idx2 then
                Just "DT Path Index mismatch"

            else
                compareDTPaths rest1 rest2

        ( Path.Unbox rest1, TypedPath.Unbox rest2 ) ->
            compareDTPaths rest1 rest2

        _ ->
            Just "DT Path structure mismatch"


compareDTTests : DT.Test -> TDT.Test -> Maybe String
compareDTTests erasedTest typedTest =
    case ( erasedTest, typedTest ) of
        ( Test.IsCtor home1 name1 idx1 arity1 opts1, Test.IsCtor home2 name2 idx2 arity2 opts2 ) ->
            if home1 /= home2 || name1 /= name2 || idx1 /= idx2 || arity1 /= arity2 || opts1 /= opts2 then
                Just "DT Test IsCtor mismatch"

            else
                Nothing

        ( Test.IsCons, Test.IsCons ) ->
            Nothing

        ( Test.IsNil, Test.IsNil ) ->
            Nothing

        ( Test.IsTuple, Test.IsTuple ) ->
            Nothing

        ( Test.IsInt i1, Test.IsInt i2 ) ->
            if i1 /= i2 then
                Just "DT Test IsInt mismatch"

            else
                Nothing

        ( Test.IsChr c1, Test.IsChr c2 ) ->
            if c1 /= c2 then
                Just "DT Test IsChr mismatch"

            else
                Nothing

        ( Test.IsStr s1, Test.IsStr s2 ) ->
            if s1 /= s2 then
                Just "DT Test IsStr mismatch"

            else
                Nothing

        ( Test.IsBool b1, Test.IsBool b2 ) ->
            if b1 /= b2 then
                Just "DT Test IsBool mismatch"

            else
                Nothing

        _ ->
            Just "DT Test type mismatch"
