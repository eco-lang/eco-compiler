module TestLogic.Type.PostSolve.PostSolveNoSyntheticHolesTest exposing (suite)

{-| Test suite for invariant POST\_003.

POST\_003: After PostSolve, no unresolved synthetic placeholders remain in any
non-kernel expression type anywhere in the type tree. This directly targets
the MONO\_018 "polymorphic remnant" class of bugs.

The test:

1.  Identifies "hole var names" - TVar names from pre-types of synthetic expressions
2.  Checks that no non-kernel expression's post-type contains any hole var names

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Data.Map as DataMap
import Data.Set as EverySet exposing (EverySet)
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| A violation of POST\_003.
-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , postType : Can.Type
    , holeVarsFound : List String
    , details : String
    }


suite : Test
suite =
    Test.describe "POST_003: No Synthetic Holes"
        [ StandardTestSuites.expectSuite expectNoSyntheticHoles "no-synthetic-holes"
        ]


{-| Check that a module passes POST\_003.
-}
expectNoSyntheticHoles : Src.Module -> Expect.Expectation
expectNoSyntheticHoles srcModule =
    case Compile.compileToPostSolveDetailed srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                -- Step 1: Compute hole var names from synthetic expression pre-types
                holeVarNames =
                    computeHoleVarNames artifacts

                -- Step 2: Collect kernel expression IDs (exempt from check)
                kernelExprIds =
                    Helpers.collectKernelExprIds artifacts.canonical

                -- Step 3: Build expression node map for kind reporting
                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> DataMap.fromList identity

                -- Step 4: Check all non-kernel expressions
                violations =
                    Array.foldl
                        (\maybePostType ( nodeId, acc ) ->
                            case maybePostType of
                                Nothing ->
                                    ( nodeId + 1, acc )

                                Just postType ->
                                    if nodeId < 0 then
                                        -- Skip negative IDs
                                        ( nodeId + 1, acc )

                                    else if EverySet.member identity nodeId kernelExprIds then
                                        -- Kernel expressions are exempt
                                        ( nodeId + 1, acc )

                                    else
                                        case checkNoHoleVars nodeId postType holeVarNames exprNodes of
                                            Nothing ->
                                                ( nodeId + 1, acc )

                                            Just violation ->
                                                ( nodeId + 1, violation :: acc )
                        )
                        ( 0, [] )
                        artifacts.nodeTypesPost
                        |> Tuple.second
            in
            case violations of
                [] ->
                    Expect.pass

                vs ->
                    Expect.fail (formatViolations vs)


{-| Compute the set of "hole var names" from synthetic expression pre-types.

These are TVar names that were left unresolved by the solver at synthetic
Group B expression sites. PostSolve should fill these.

We only consider numeric TVar names as "holes" because:

  - Solver-generated placeholder TVars use numeric names (e.g., "0", "1", "23")
  - PostSolve uses alphabetic names (e.g., "a", "ext")
  - Legitimate polymorphic TVars from user annotations use alphabetic names

This avoids false positives where legitimate polymorphism would be flagged.

-}
computeHoleVarNames : Compile.DetailedArtifacts -> EverySet String String
computeHoleVarNames artifacts =
    artifacts.syntheticExprIds
        |> EverySet.toList compare
        |> List.filterMap
            (\exprId ->
                case Array.get exprId artifacts.nodeTypesPre |> Maybe.andThen identity of
                    Just (Can.TVar name) ->
                        -- Only consider numeric names as holes (solver-generated placeholders)
                        if isSolverGeneratedVarName name then
                            Just name

                        else
                            Nothing

                    _ ->
                        Nothing
            )
        |> EverySet.fromList identity


{-| Check if a TVar name is solver-generated (numeric).

Solver-generated placeholder TVars use numeric names like "0", "1", "23".
User-defined polymorphic TVars and PostSolve-generated TVars use alphabetic names.

-}
isSolverGeneratedVarName : String -> Bool
isSolverGeneratedVarName name =
    case String.uncons name of
        Just ( first, _ ) ->
            Char.isDigit first

        Nothing ->
            False


{-| Check that a post-type contains no hole var names.
-}
checkNoHoleVars :
    Int
    -> Can.Type
    -> EverySet String String
    -> DataMap.Dict Int Int Helpers.ExprNode
    -> Maybe Violation
checkNoHoleVars nodeId postType holeVarNames exprNodes =
    let
        freeVars =
            Helpers.freeTypeVars postType

        -- Compute intersection by filtering freeVars to only those in holeVarNames
        foundHoles =
            freeVars
                |> EverySet.toList compare
                |> List.filter (\name -> EverySet.member identity name holeVarNames)
    in
    if List.isEmpty foundHoles then
        Nothing

    else
        Just
            { nodeId = nodeId
            , exprKind = getExprKind nodeId exprNodes
            , postType = postType
            , holeVarsFound = foundHoles
            , details =
                "Post-type contains unresolved synthetic hole vars: ["
                    ++ String.join ", " foundHoles
                    ++ "]"
            }


{-| Get the expression kind for an ID.
-}
getExprKind : Int -> DataMap.Dict Int Int Helpers.ExprNode -> String
getExprKind nodeId exprNodes =
    case DataMap.get identity nodeId exprNodes of
        Just node ->
            exprKindToString node.node

        Nothing ->
            "Unknown"


exprKindToString : Can.Expr_ -> String
exprKindToString expr =
    case expr of
        Can.VarLocal _ ->
            "VarLocal"

        Can.VarTopLevel _ _ ->
            "VarTopLevel"

        Can.VarKernel _ _ ->
            "VarKernel"

        Can.VarForeign _ _ _ ->
            "VarForeign"

        Can.VarCtor _ _ _ _ _ ->
            "VarCtor"

        Can.VarDebug _ _ _ ->
            "VarDebug"

        Can.VarOperator _ _ _ _ ->
            "VarOperator"

        Can.Chr _ ->
            "Chr"

        Can.Str _ ->
            "Str"

        Can.Int _ ->
            "Int"

        Can.Float _ ->
            "Float"

        Can.List _ ->
            "List"

        Can.Negate _ ->
            "Negate"

        Can.Binop _ _ _ _ _ _ ->
            "Binop"

        Can.Lambda _ _ ->
            "Lambda"

        Can.Call _ _ ->
            "Call"

        Can.If _ _ ->
            "If"

        Can.Let _ _ ->
            "Let"

        Can.LetRec _ _ ->
            "LetRec"

        Can.LetDestruct _ _ _ ->
            "LetDestruct"

        Can.Case _ _ ->
            "Case"

        Can.Accessor _ ->
            "Accessor"

        Can.Access _ _ ->
            "Access"

        Can.Update _ _ ->
            "Update"

        Can.Record _ ->
            "Record"

        Can.Unit ->
            "Unit"

        Can.Tuple _ _ _ ->
            "Tuple"

        Can.Shader _ _ ->
            "Shader"



-- ============================================================================
-- FORMATTING
-- ============================================================================


formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_003 violations: "
                ++ String.fromInt (List.length violations)
                ++ " expression(s) contain unresolved synthetic hole vars\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


formatViolation : Violation -> String
formatViolation v =
    "POST_003 violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ " ("
        ++ v.exprKind
        ++ "):\n  postType:     "
        ++ typeToString v.postType
        ++ "\n  holeVars:     ["
        ++ String.join ", " v.holeVarsFound
        ++ "]\n  details:      "
        ++ v.details


typeToString : Can.Type -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            "TVar \"" ++ name ++ "\""

        Can.TType _ name args ->
            "TType ("
                ++ name
                ++ ") ["
                ++ String.join ", " (List.map typeToString args)
                ++ "]"

        Can.TLambda a b ->
            "TLambda (" ++ typeToString a ++ " -> " ++ typeToString b ++ ")"

        Can.TRecord _ ext ->
            case ext of
                Nothing ->
                    "TRecord {...}"

                Just extName ->
                    "TRecord { " ++ extName ++ " | ... }"

        Can.TUnit ->
            "TUnit"

        Can.TTuple a b cs ->
            "TTuple ("
                ++ String.join ", " (List.map typeToString (a :: b :: cs))
                ++ ")"

        Can.TAlias _ name _ _ ->
            "TAlias " ++ name
