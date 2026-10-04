module TestLogic.Type.PostSolve.PostSolveLambdaContextVarsTest exposing (suite)

{-| Tests that `Compiler.Type.PostSolve` gives no lambda a type naming a type
variable that the solver did not already have for it. A lambda whose type
gained such a variable would be polymorphic in a variable that no solver
constraint governs. This is invariant POST\_008.

A node's _pre-type_ and _post-type_ are its entries in the node types before and
after PostSolve, as `TestLogic.Type.PostSolve.CompileThroughPostSolve` returns
them. A lambda's _context variables_ are the type variable names of its
pre-type or, when it has none, the variables quantified by the annotation that
the solver's annotations hold under the name of the definition the lambda sits
in, as `TestLogic.Type.PostSolve.PostSolveInvariantHelpers.walkExprs` tags it.
POST\_008 requires every type variable name in a lambda's post-type to be a
context variable. Names are read with `PostSolveInvariantHelpers.freeTypeVars`,
which includes record extension variables and, for an alias with a `Holey`
body, the alias's own parameter names, and they are compared by name only.

The programs are those of `SourceIR.Suite.StandardTestSuites.expectSuite`, under
the description `"lambda-context-vars"`.

The tests establish:

  - For each program, `expectLambdaContextVars` fails if the program does not
    compile through PostSolve, and otherwise fails if any lambda with a
    post-type names a type variable that is not a context variable. The failure
    message lists each such lambda with its pre-type, post-type and the names
    that are not context variables.

Among what is not tested:

  - A lambda with no post-type is skipped.
    `TestLogic.Type.PostSolve.PostSolveLambdaStructuralTypesTest` (POST\_007)
    reports it.
  - Anything about a post-type other than the names of its type variables. A
    post-type with a different shape, or with fewer variables, passes.
  - The enclosing definition's annotation, for a lambda that has a pre-type; only
    the pre-type is used.
  - A lambda with no pre-type inside a let-bound definition against the
    annotation around it. Its context comes from an annotation under the
    let-bound name, so it is empty unless the solver's annotations hold one,
    and then any type variable in its post-type fails.
  - Nodes other than lambdas.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Type.PostSolve as PostSolve
import Data.Set as EverySet exposing (EverySet)
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| One lambda that fails POST\_008, as the failure message reports it.

`preType` is `Nothing` when the lambda had no pre-type and its context
variables came from the enclosing annotation. `newVars` are the post-type's
type variable names that are not context variables, in ascending order.

-}
type alias Violation =
    { nodeId : Int
    , preType : Maybe (Can.Type Name)
    , postType : Can.Type Name
    , newVars : List String
    , details : String
    }


{-| The POST\_008 test: every program of the standard `SourceIR` catalogue
compiled through PostSolve, failing for any lambda whose post-type names a type
variable that is not among those of its pre-type, or, when it has none, among
those quantified by its enclosing definition's annotation.
-}
suite : Test
suite =
    Test.describe "POST_008: Lambda Context Vars"
        [ StandardTestSuites.expectSuite expectLambdaContextVars "lambda-context-vars"
        ]


{-| Compiles `srcModule` through PostSolve and passes if no lambda's post-type
names a type variable outside its context variables. A compilation error fails
with the compiler's message; otherwise the failure lists every lambda that
breaks the rule.
-}
expectLambdaContextVars : Src.Module -> Expect.Expectation
expectLambdaContextVars srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
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


{-| Returns whether an expression form is a `Lambda`.
-}
isLambda : Can.Expr_ -> Bool
isLambda node =
    case node of
        Can.Lambda _ _ ->
            True

        _ ->
            False


{-| Returns the violation for the node `exprNode`, or `Nothing` if its type in
`nodeTypesPost` names only context variables or it has no type there.

The context variables are the type variable names of its type in
`nodeTypesPre` if it has one, and otherwise the variables quantified by the
annotation `annotations` holds under its `enclosingDef`. With neither, the
context is empty, so the node fails if its post-type names any type variable.

-}
checkLambdaContextVars :
    Helpers.ExprNode
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> Dict.Dict String (Can.Annotation Name)
    -> Maybe Violation
checkLambdaContextVars exprNode nodeTypesPre nodeTypesPost annotations =
    case Array.get exprNode.id nodeTypesPost |> Maybe.andThen identity of
        Nothing ->
            Nothing

        Just postType ->
            let
                postVars =
                    Helpers.freeTypeVars postType

                ( contextVars, preTypeForReport ) =
                    case Array.get exprNode.id nodeTypesPre |> Maybe.andThen identity of
                        Just preType ->
                            ( computeContextVars preType, Just preType )

                        Nothing ->
                            ( Helpers.enclosingAnnotationVars
                                exprNode.enclosingDef
                                annotations
                            , Nothing
                            )

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


{-| Returns the type variable names of a pre-type, as
`PostSolveInvariantHelpers.freeTypeVars` reads them. The bare `TVar` case gives
the same one-name set that `freeTypeVars` would.
-}
computeContextVars : Can.Type Name -> EverySet String String
computeContextVars preType =
    case preType of
        Can.TVar name ->
            EverySet.insert identity name EverySet.empty

        _ ->
            Helpers.freeTypeVars preType



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Returns the failure message for `violations`: a line counting them, then
each one as `formatViolation` renders it, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_008 violations: "
                ++ String.fromInt (List.length violations)
                ++ " lambda(s) with new unconstrained type variables\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


{-| Returns a multi-line description of one violation: its node id, pre-type,
post-type, the names that are not context variables, and its details line.
-}
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


{-| Returns the type as `typeToString` renders it, or `(none)` for `Nothing`.
-}
maybeTypeToString : Maybe (Can.Type Name) -> String
maybeTypeToString mt =
    case mt of
        Just t ->
            typeToString t

        Nothing ->
            "(none)"


{-| Returns a one-line rendering of a type for a failure message, naming the
constructor of each part. A record shows only its extension variable, if it
has one, and not its fields, and an alias shows only its name.
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
