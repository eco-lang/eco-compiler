module TestLogic.Type.PostSolve.PostSolveLambdaContextVarsTest exposing (suite)

{-| Test suite for invariant POST\_008.

POST\_008: For every lambda expression the set of free Can.TVar names appearing
in its post-PostSolve type must be a subset of the type variables available in
its surrounding solver environment (from its pre-PostSolve node type or
enclosing annotated scheme) ensuring that PostSolve does not introduce new
unconstrained lambda-local type variables and that all lambda polymorphism
originates from the main solver.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Type.PostSolve as PostSolve
import Data.Set as EverySet exposing (EverySet)
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| A violation of POST\_008.
-}
type alias Violation =
    { nodeId : Int
    , preType : Maybe Can.Type
    , postType : Can.Type
    , newVars : List String
    , details : String
    }


suite : Test
suite =
    Test.describe "POST_008: Lambda Context Vars"
        [ StandardTestSuites.expectSuite expectLambdaContextVars "lambda-context-vars"
        ]


{-| Check that a module passes POST\_008.
-}
expectLambdaContextVars : Src.Module -> Expect.Expectation
expectLambdaContextVars srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                -- Walk AST to find all lambda expression nodes
                lambdaNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.filter (\n -> isLambda n.node)

                violations =
                    List.filterMap
                        (\node ->
                            checkLambdaContextVars
                                node
                                artifacts.nodeTypesPre
                                artifacts.nodeTypesPost
                                artifacts.annotations
                        )
                        lambdaNodes
            in
            case violations of
                [] ->
                    Expect.pass

                vs ->
                    Expect.fail (formatViolations vs)


{-| Check if an expression node is a Lambda.
-}
isLambda : Can.Expr_ -> Bool
isLambda node =
    case node of
        Can.Lambda _ _ ->
            True

        _ ->
            False


{-| Check a single lambda for POST\_008 compliance.

The free type variables in the lambda's post-PostSolve type must be a subset
of the type variables available from the surrounding solver context.

Context vars are derived from:

1.  The lambda's pre-PostSolve type (if present) — its free vars are the context.
2.  The enclosing definition's annotation (if the lambda has no pre-type) —
    the quantified vars from `Forall freeVars _` are the context.
3.  If neither is available, flag as violation — a lambda with no pre-type and
    no enclosing annotation scope is always suspect.

-}
checkLambdaContextVars :
    Helpers.ExprNode
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> Dict.Dict String Can.Annotation
    -> Maybe Violation
checkLambdaContextVars exprNode nodeTypesPre nodeTypesPost annotations =
    case Array.get exprNode.id nodeTypesPost |> Maybe.andThen identity of
        Nothing ->
            -- No post type means no violation (missing type is POST_007's concern)
            Nothing

        Just postType ->
            let
                postVars =
                    Helpers.freeTypeVars postType

                -- Compute context vars from pre type or enclosing annotation
                ( contextVars, preTypeForReport ) =
                    case Array.get exprNode.id nodeTypesPre |> Maybe.andThen identity of
                        Just preType ->
                            -- Pre type exists: its free vars are the context
                            ( computeContextVars preType, Just preType )

                        Nothing ->
                            -- No pre type: use enclosing def's annotation vars
                            ( Helpers.enclosingAnnotationVars
                                exprNode.enclosingDef
                                annotations
                            , Nothing
                            )

                -- Check: postVars ⊆ contextVars
                newVars =
                    EverySet.diff postVars contextVars
                        |> EverySet.toList compare
            in
            if List.isEmpty newVars then
                Nothing

            else
                Just
                    { nodeId = exprNode.id
                    , preType = preTypeForReport
                    , postType = postType
                    , newVars = newVars
                    , details =
                        "Lambda post type contains type variables not in surrounding context: ["
                            ++ String.join ", " newVars
                            ++ "]"
                            ++ (case exprNode.enclosingDef of
                                    Just dn ->
                                        " (enclosing def: " ++ dn ++ ")"

                                    Nothing ->
                                        " (no enclosing def)"
                               )
                    }


{-| Compute the set of type variables available from the surrounding
solver context for a given pre-PostSolve type.

  - If the pre type is a bare TVar, the var name itself is the context.
  - If the pre type is structured, compute all free type vars from it.

-}
computeContextVars : Can.Type -> EverySet String String
computeContextVars preType =
    case preType of
        Can.TVar name ->
            -- A bare TVar placeholder: include the var name itself
            EverySet.insert identity name EverySet.empty

        _ ->
            -- Structured type: compute all free vars
            Helpers.freeTypeVars preType



-- ============================================================================
-- FORMATTING
-- ============================================================================


formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_008 violations: "
                ++ String.fromInt (List.length violations)
                ++ " lambda(s) with new unconstrained type variables\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


formatViolation : Violation -> String
formatViolation v =
    "POST_008 violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ ":\n  preType:  "
        ++ maybeTypeToString v.preType
        ++ "\n  postType: "
        ++ typeToString v.postType
        ++ "\n  newVars:  ["
        ++ String.join ", " v.newVars
        ++ "]\n  details:  "
        ++ v.details


maybeTypeToString : Maybe Can.Type -> String
maybeTypeToString mt =
    case mt of
        Just t ->
            typeToString t

        Nothing ->
            "(none)"


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
