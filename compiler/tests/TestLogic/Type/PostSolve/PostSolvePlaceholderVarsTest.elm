module TestLogic.Type.PostSolve.PostSolvePlaceholderVarsTest exposing (suite)

{-| Test suite for invariant POST\_009.

POST\_009: PostSolve-generated placeholder TVars used for structural repair of
Group B expressions must not appear in function positions in the fixed NodeTypes
map for non-kernel expressions so that all function types visible to
TypedCanonical TypedOptimized and monomorphization are expressed solely in terms
of solver- or annotation-derived type variables.

Detection strategy: For each non-kernel node, TVars in function positions
(TLambda components) in the post type are checked against that node's own
pre-type vars. For Group B nodes with no pre-type, the enclosing definition's
annotation vars serve as the legitimate set.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Type.PostSolve as PostSolve
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers
import TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants as Invariants


{-| A violation of POST\_009.
-}
type alias Violation =
    { nodeId : Int
    , kind : String
    , postType : Can.Type
    , placeholderVars : List String
    , details : String
    }


suite : Test
suite =
    Test.describe "POST_009: No Placeholder Vars in Function Positions"
        [ StandardTestSuites.expectSuite expectNoPlaceholderVars "no-placeholder-vars"
        ]


{-| Check that a module passes POST\_009.
-}
expectNoPlaceholderVars : Src.Module -> Expect.Expectation
expectNoPlaceholderVars srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                -- Classify node kinds (to exempt VarKernel nodes)
                nodeKinds =
                    Invariants.collectNodeKinds artifacts.canonical

                -- Build expression node map for kind reporting and scope lookup
                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> Data.Map.fromList identity

                -- Check all non-kernel post types for placeholder TVars in function positions
                violations =
                    Array.foldl
                        (\maybePostType ( nodeId, acc ) ->
                            case maybePostType of
                                Nothing ->
                                    ( nodeId + 1, acc )

                                Just postType ->
                                    if nodeId < 0 then
                                        ( nodeId + 1, acc )

                                    else
                                        case Data.Map.get identity nodeId nodeKinds of
                                            Just Invariants.KVarKernel ->
                                                -- Kernel nodes are exempt
                                                ( nodeId + 1, acc )

                                            _ ->
                                                case checkNoPlaceholdersInFuncPositions nodeId postType artifacts.nodeTypesPre exprNodes artifacts.annotations of
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


{-| Check that a post type has no placeholder TVars in function positions.

A "placeholder in function position" is a TVar within a TLambda that was
introduced by PostSolve (not present in the node's own pre-type or the
enclosing definition's annotation).

Per-node check:

  - If the node has a pre-type, its free vars are the legitimate set.
  - If the node has no pre-type (Group B), use the enclosing definition's
    annotation vars as the legitimate set.

-}
checkNoPlaceholdersInFuncPositions :
    Int
    -> Can.Type
    -> PostSolve.NodeTypes
    -> Data.Map.Dict Int Int Helpers.ExprNode
    -> Dict.Dict String Can.Annotation
    -> Maybe Violation
checkNoPlaceholdersInFuncPositions nodeId postType nodeTypesPre exprNodes annotations =
    let
        -- Collect TVars that appear in function positions in the post type
        funcPositionVars =
            collectFuncPositionVars postType

        -- Compute legitimate vars for THIS node (not global)
        legitimateVars =
            case Array.get nodeId nodeTypesPre |> Maybe.andThen identity of
                Just preType ->
                    -- Node has a pre-type: its free vars are legitimate
                    Helpers.freeTypeVars preType

                Nothing ->
                    -- No pre-type (Group B): use enclosing def's annotation vars
                    case Data.Map.get identity nodeId exprNodes of
                        Just exprNode ->
                            Helpers.enclosingAnnotationVars
                                exprNode.enclosingDef
                                annotations

                        Nothing ->
                            EverySet.empty

        -- Filter to only those that are NOT in the legitimate set
        placeholders =
            funcPositionVars
                |> EverySet.toList compare
                |> List.filter (\name -> not (EverySet.member identity name legitimateVars))
    in
    if List.isEmpty placeholders then
        Nothing

    else
        Just
            { nodeId = nodeId
            , kind = getExprKind nodeId exprNodes
            , postType = postType
            , placeholderVars = placeholders
            , details =
                "Post type contains PostSolve-generated placeholder TVars in function positions: ["
                    ++ String.join ", " placeholders
                    ++ "]. These should be solver/annotation-derived only."
            }


{-| Collect all TVar names that appear in function positions (within TLambda).

"Function position" means any TVar that is part of a TLambda argument or result,
including nested TLambdas.

-}
collectFuncPositionVars : Can.Type -> EverySet String String
collectFuncPositionVars tipe =
    case tipe of
        Can.TLambda arg result ->
            -- Both arg and result are in function position
            EverySet.union
                (Helpers.freeTypeVars arg)
                (Helpers.freeTypeVars result)

        Can.TType _ _ args ->
            -- TVars inside type constructors are not in function position,
            -- but nested TLambdas inside type args may contain function positions
            List.foldl
                (\t acc -> EverySet.union acc (collectFuncPositionVars t))
                EverySet.empty
                args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ fieldType) acc ->
                    EverySet.union acc (collectFuncPositionVars fieldType)
                )
                EverySet.empty
                fields

        Can.TTuple a b cs ->
            List.foldl
                (\t acc -> EverySet.union acc (collectFuncPositionVars t))
                (EverySet.union (collectFuncPositionVars a) (collectFuncPositionVars b))
                cs

        Can.TAlias _ _ _ aliasType ->
            case aliasType of
                Can.Holey t ->
                    collectFuncPositionVars t

                Can.Filled t ->
                    collectFuncPositionVars t

        Can.TVar _ ->
            -- A bare TVar at top level is NOT in function position
            EverySet.empty

        Can.TUnit ->
            EverySet.empty


{-| Get the expression kind for an ID.
-}
getExprKind : Int -> Data.Map.Dict Int Int Helpers.ExprNode -> String
getExprKind nodeId exprNodes =
    case Data.Map.get identity nodeId exprNodes of
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
            "POST_009 violations: "
                ++ String.fromInt (List.length violations)
                ++ " expression(s) with placeholder TVars in function positions\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


formatViolation : Violation -> String
formatViolation v =
    "POST_009 violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ " ("
        ++ v.kind
        ++ "):\n  postType:        "
        ++ typeToString v.postType
        ++ "\n  placeholderVars: ["
        ++ String.join ", " v.placeholderVars
        ++ "]\n  details:         "
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
