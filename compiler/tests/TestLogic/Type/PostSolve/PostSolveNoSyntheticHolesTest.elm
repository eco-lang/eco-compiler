module TestLogic.Type.PostSolve.PostSolveNoSyntheticHolesTest exposing (suite)

{-| Tests invariant POST\_003: once `Compiler.Type.PostSolve` has run, no type
variable that stood in for a synthetic placeholder is left anywhere in a node's
type. It is meant to catch a placeholder that PostSolve leaves unreplaced.

Constraint generation gives some expressions, such as string, character, float
and unit literals, a _synthetic placeholder_ as their type: a fresh variable
recorded for that expression alone.
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolveDetailed`
returns the ids of those expressions along with the node types from before and
after PostSolve. A _hole var_ is a placeholder that no constraint reached: a
type variable that is the whole pre-PostSolve type of a synthetic expression,
other than a definition's body, and occurs in no other node's pre-PostSolve
type (`PostSolveInvariantHelpers.orphanPlaceholderVars`, whose docstring says
why such a variable can only be a leftover).

The fixture is the standard catalogue of programs in
`SourceIR.Suite.StandardTestSuites`. For each program, the check:

  - fails with the compiler's message if the program does not compile through
    PostSolve;
  - otherwise collects the hole vars, then looks at every node that has a
    post-PostSolve type, pattern nodes included, except kernel references
    (`VarKernel`), and fails, listing every offending node, if any of those
    types mentions a hole var anywhere inside it.

A hole var at a string, character or float literal or unit is replaced by
PostSolve and so passes; one at any other synthetic expression, such as a
variable reference, is left in place and fails.

Among what is not tested: a placeholder that was left unconstrained inside a
larger pre-PostSolve type, one that is a definition's whole body, one whose
name collides with another variable's, and the types of kernel references.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Data.Map as DataMap
import Data.Set as EverySet exposing (EverySet)
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| One node whose post-PostSolve type mentions a hole var.

`exprKind` names the node's expression form, or is `"Unknown"` when the id is
not an expression's, as for a pattern node. `holeVarsFound` lists the hole
vars in sorted order, and `details` repeats them as a sentence.

-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , postType : Can.Type Name
    , holeVarsFound : List String
    , details : String
    }


{-| The POST\_003 suite: `expectNoSyntheticHoles` applied to every program in
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "POST_003: No Synthetic Holes"
        [ StandardTestSuites.expectSuite expectNoSyntheticHoles "no-synthetic-holes"
        ]


{-| Compiles `srcModule` through PostSolve and expects no node's post-PostSolve
type to mention a hole var.

It fails with the compiler's message when compilation fails, and otherwise with
every violation found. The ids of kernel references are not checked. Each node
id is the index of its type in the post-PostSolve array, so pattern nodes are
checked along with expressions.

-}
expectNoSyntheticHoles : Src.Module -> Expect.Expectation
expectNoSyntheticHoles srcModule =
    case Compile.compileToPostSolveDetailed srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                holeVarNames =
                    computeHoleVarNames artifacts

                kernelExprIds =
                    Helpers.collectKernelExprIds artifacts.canonical

                -- Used only to name each offending node's form in the message.
                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> DataMap.fromList identity

                -- The counter starts at 0 and counts array slots, so it is the node id.
                violations =
                    Array.foldl
                        (\maybePostType ( nodeId, acc ) ->
                            case maybePostType of
                                Nothing ->
                                    ( nodeId + 1, acc )

                                Just postType ->
                                    if EverySet.member identity nodeId kernelExprIds then
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


{-| Returns the hole var names of a compiled program, as
`PostSolveInvariantHelpers.orphanPlaceholderVars` finds them.
-}
computeHoleVarNames : Compile.DetailedArtifacts -> EverySet String String
computeHoleVarNames artifacts =
    Helpers.orphanPlaceholderVars artifacts.canonical artifacts.syntheticExprIds artifacts.nodeTypesPre
        |> List.map Tuple.second
        |> EverySet.fromList identity


{-| Returns a `Violation` for node `nodeId` when `postType` mentions any of
`holeVarNames` anywhere inside it, and `Nothing` when it mentions none.
`exprNodes` supplies the node's expression form for the report.
-}
checkNoHoleVars :
    Int
    -> Can.Type Name
    -> EverySet String String
    -> DataMap.Dict Int Int Helpers.ExprNode
    -> Maybe Violation
checkNoHoleVars nodeId postType holeVarNames exprNodes =
    let
        freeVars =
            Helpers.freeTypeVars postType

        foundHoles =
            freeVars
                |> EverySet.toList
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


{-| Returns the name of the expression form of node `nodeId` in `exprNodes`, or
`"Unknown"` when `exprNodes` has no entry for it.
-}
getExprKind : Int -> DataMap.Dict Int Int Helpers.ExprNode -> String
getExprKind nodeId exprNodes =
    case DataMap.get identity nodeId exprNodes of
        Just node ->
            exprKindToString node.node

        Nothing ->
            "Unknown"


{-| Returns the name of an expression form's constructor, such as `"VarLocal"`
or `"Call"`.
-}
exprKindToString : Can.Expr_ -> String
exprKindToString expr =
    case expr of
        Can.VarLocal _ ->
            "VarLocal"

        Can.VarTopLevel _ _ ->
            "VarTopLevel"

        Can.VarKernel _ _ _ ->
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


{-| Builds the failure message for `violations`: a line giving their count, then
each one as `formatViolation` lays it out, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_003 violations: "
                ++ String.fromInt (List.length violations)
                ++ " expression(s) contain unresolved synthetic hole vars\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


{-| Renders one violation as a line naming its node id and expression form,
followed by indented lines for its post-type, hole vars and details.
-}
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


{-| Renders a type on one line for a failure message.

The rendering is a summary, not the full type. A named type shows its name and
arguments but not its module, a record shows only its extension variable, if
any, and not its fields, and an alias shows only its name.

-}
typeToString : Can.Type Name -> String
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

        Can.TLambda _ a b ->
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
