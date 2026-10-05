module TestLogic.Type.PostSolve.PostSolvePlaceholderVarsTest exposing (suite)

{-| Catches a `Compiler.Type.PostSolve` that writes a type variable of its own
into a function type, one taken neither from the solver's result nor from an
annotation. Such a variable is called a _placeholder_ here, and the rule that
no node other than a kernel reference may have one is invariant POST\_009.

The solver records an optional type for each node id of a module, expressions
and patterns alike, and PostSolve rewrites some of those entries, as the
`Compiler.Type.PostSolve` docstring describes. A node's _pre-type_ is its entry
before PostSolve and its _post-type_ the entry after. A type variable is in
_function position_ when it occurs anywhere inside a `Can.TLambda`: in the
argument or the result, at any depth. A bare variable, or one inside type
constructor arguments, record fields or tuple elements with no function type
around it, is not.

A variable is _legitimate_ for a node when it occurs anywhere in the node's
pre-type. For a node with no pre-type, the legitimate variables are those
in scope from the annotations around it, as
`PostSolveInvariantHelpers.enclosingAnnotationVars` gives them: the scheme of
its top-level definition and the annotations of the definitions around it. A
pattern with no pre-type has none. POST\_009 holds when,
for every node with a post-type except a kernel reference (a `Can.VarKernel`),
every variable in function position in its post-type is legitimate.

Every variable in function position in a type also occurs in that type, so a
node with a pre-type that PostSolve leaves unchanged cannot break POST\_009. The
non-kernel nodes PostSolve changes are string, character and float literals and
unit, and the types it gives them contain no variables. Against the present
PostSolve, then, a program fails here only if it fails to compile.

The fixture is the standard catalogue of test programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` supplies, each compiled as far
as PostSolve by `CompileThroughPostSolve.compileToPostSolve`.

  - `suite` checks, for each program, that it compiles through PostSolve and
    that POST\_009 holds for it. A failure lists each offending node with its
    id, expression form, post-type and placeholder variables.

Among what is not tested:

  - A variable PostSolve invents outside function position, such as a whole
    node type that is a new variable.
  - The types of kernel references.
  - Where a legitimate variable appears: one that occurs anywhere in the
    pre-type is accepted anywhere in the function types of the post-type.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
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


{-| One node that breaks POST\_009, with what the failure message reports about
it.

`kind` is the name of the node's expression form, or `"Unknown"` for an id that
is not an expression, such as a pattern's. `placeholderVars` are the variables
that are not legitimate for the node, in ascending order, and `details` is a
sentence that lists them again.

-}
type alias Violation =
    { nodeId : Int
    , kind : String
    , postType : Can.Type Name
    , placeholderVars : List String
    , details : String
    }


{-| The test group that checks POST\_009 for each program of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "POST_009: No Placeholder Vars in Function Positions"
        [ StandardTestSuites.expectSuite expectNoPlaceholderVars "no-placeholder-vars"
        ]


{-| Compiles `srcModule` through PostSolve and passes when POST\_009 holds for
it.

A compilation failure fails with the test pipeline's error message. Otherwise
each node with a post-type, except a kernel reference, is checked by
`checkNoPlaceholdersInFuncPositions`, and the failure message lists the
violations, highest node id first.

-}
expectNoPlaceholderVars : Src.Module -> Expect.Expectation
expectNoPlaceholderVars srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                nodeKinds =
                    Invariants.collectNodeKinds artifacts.canonical

                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> Data.Map.fromList identity

                violations =
                    Array.foldl
                        (\maybePostType ( nodeId, acc ) ->
                            case maybePostType of
                                Nothing ->
                                    ( nodeId + 1, acc )

                                Just postType ->
                                    case Data.Map.get identity nodeId nodeKinds of
                                        Just Invariants.KVarKernel ->
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


{-| Returns a violation for node `nodeId` when `postType`, its post-type, has a
variable in function position that is not legitimate for it, and `Nothing`
otherwise.

The legitimate variables are every variable name in the node's entry in
`nodeTypesPre`, as `PostSolveInvariantHelpers.freeTypeVars` counts them. When
that entry is missing, they are the variables in scope at the node from the
annotations around it (`PostSolveInvariantHelpers.enclosingAnnotationVars`),
and none when `exprNodes` has no entry for `nodeId`.

-}
checkNoPlaceholdersInFuncPositions :
    Int
    -> Can.Type Name
    -> PostSolve.NodeTypes
    -> Data.Map.Dict Int Int Helpers.ExprNode
    -> Dict.Dict String (Can.Annotation Name)
    -> Maybe Violation
checkNoPlaceholdersInFuncPositions nodeId postType nodeTypesPre exprNodes annotations =
    let
        funcPositionVars =
            collectFuncPositionVars postType

        legitimateVars =
            case Array.get nodeId nodeTypesPre |> Maybe.andThen identity of
                Just preType ->
                    Helpers.freeTypeVars preType

                Nothing ->
                    case Data.Map.get identity nodeId exprNodes of
                        Just exprNode ->
                            Helpers.enclosingAnnotationVars
                                exprNode
                                annotations

                        Nothing ->
                            EverySet.empty

        placeholders =
            funcPositionVars
                |> EverySet.toList
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


{-| Returns the names of the type variables in function position in `tipe`.

Inside a `TLambda`, every variable name counts, as
`PostSolveInvariantHelpers.freeTypeVars` counts them, record extension variables
and alias arguments included. A `TLambda` is found among type constructor
arguments, record fields and tuple elements, in a `Filled` alias's body, and in
a `Holey` alias's arguments, which its body's parameters stand for.

-}
collectFuncPositionVars : Can.Type Name -> EverySet String String
collectFuncPositionVars tipe =
    case tipe of
        Can.TLambda _ arg result ->
            EverySet.union
                (Helpers.freeTypeVars arg)
                (Helpers.freeTypeVars result)

        Can.TType _ _ args ->
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

        Can.TAlias _ _ args aliasType ->
            case aliasType of
                Can.Holey _ ->
                    List.foldl
                        (\( _, t ) acc -> EverySet.union acc (collectFuncPositionVars t))
                        EverySet.empty
                        args

                Can.Filled t ->
                    collectFuncPositionVars t

        Can.TVar _ ->
            EverySet.empty

        Can.TUnit ->
            EverySet.empty


{-| Returns the name of the expression form of node `nodeId`, or `"Unknown"`
when `exprNodes` has no expression with that id, as for a pattern.
-}
getExprKind : Int -> Data.Map.Dict Int Int Helpers.ExprNode -> String
getExprKind nodeId exprNodes =
    case Data.Map.get identity nodeId exprNodes of
        Just node ->
            exprKindToString node.node

        Nothing ->
            "Unknown"


{-| Returns the name of an expression form's constructor.
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


{-| Builds the failure message for `violations`: a header with their count,
then each violation as `formatViolation` renders it, in the order given,
separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_009 violations: "
                ++ String.fromInt (List.length violations)
                ++ " expression(s) with placeholder TVars in function positions\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


{-| Renders one violation as a line naming its node id and expression form,
followed by indented lines for its post-type, its placeholder variables and its
details.
-}
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


{-| Renders a type for a failure message, naming the `Can.Type` constructors.

The rendering is abbreviated. A type constructor shows its name without its
home module, a record shows only its extension variable, if any, and an alias
shows only its name.

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
