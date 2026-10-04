module TestLogic.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)

{-| Code generation cannot lay out a number whose type is still undecided, so
monomorphization must leave behind no number variable: an `MVar` with the
`CNumber` constraint, which stands for an `Int` or a `Float` not yet chosen.
The `MonoType` and `Constraint` docstrings in `Compiler.AST.Monomorphized` own
that rule. This module walks the types of a monomorphized graph looking for
one.

`expectMonoTypesFullyElaborated` monomorphizes a program with
`TestLogic.TestPipeline.runToMono` and walks the types in the resulting graph:
each node's type, the types of expressions in its body, and the parameter
types of tail-recursive functions and closures. Despite the name, the only
type it rejects is a number variable. Every concrete type passes, and so does
an `MVar` with the `CEcoValue` constraint, a variable whose values are always
boxed.

The graph checked is the one `runToMono` returns, produced by the
substitution engine before any post-monomorphization inlining or global
optimization. The engine's final prune has already turned every number
variable it finds in the types of the nodes it keeps into `MInt`, and crashes
if one survives. Every type this module walks is one that prune reaches, so on
this graph the check passes whenever `runToMono` succeeds.

Among what is not checked:

  - the element types of a tuple type and the field types of a record type,
    which are accepted without being looked into;
  - the decision tree of a `case`, including any branch expression held inline
    in it, since only the branch bodies listed beside the tree are walked;
  - the destructor of a destructuring and the type of an accessor value.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that passes when no number variable is found in the
types walked in the monomorphized graph of `srcModule`. Tuple element and
record field types are not looked into.

It fails, with the pipeline's message, when `runToMono` fails. The engine has
already closed every number variable this walk can reach, so in practice that
is the only way it fails. A failure from the walk would list each number
variable found, one per line, labelled with the `SpecId` of its node.

-}
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                issues =
                    collectMonoTypeIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- MONO TYPE TRAVERSAL
-- ============================================================================


{-| Returns the issues found in every node of the graph. A node is labelled with
its position in the node array, which is its `SpecId`; empty slots are
skipped but still counted.
-}
collectMonoTypeIssues : Mono.MonoGraph -> List String
collectMonoTypeIssues (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, collectNodeTypeIssues specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the issues in one node, labelled with `specId`. Every node's own type
is checked. A definition or port also contributes its body, and a
tail-recursive function its body and parameter types.
-}
collectNodeTypeIssues : Int -> Mono.MonoNode -> List String
collectNodeTypeIssues specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) params
                ++ collectExprTypeIssues context expr

        Mono.MonoCtor _ monoType ->
            checkMonoType context monoType

        Mono.MonoEnum _ monoType ->
            checkMonoType context monoType

        Mono.MonoExtern monoType ->
            checkMonoType context monoType

        Mono.MonoManagerLeaf _ monoType ->
            checkMonoType context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context expr


{-| Returns the issues, labelled with `context`, in the type of `expr` and in the
types of its subexpressions, including a closure's parameter types and
captured expressions and a `let`'s definition.

Among what is not walked: a `case`'s decision tree, so a branch expression
held inline in the tree is skipped and only the branch bodies listed beside it
are visited; a destructuring's destructor; and `MonoUnit` and
`MonoAccessorValue`, which contribute nothing.

-}
collectExprTypeIssues : String -> Mono.MonoExpr -> List String
collectExprTypeIssues context expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarLocal _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarGlobal _ _ monoType ->
            checkMonoType context monoType

        Mono.MonoVarKernel _ _ _ _ monoType ->
            checkMonoType context monoType

        Mono.MonoList _ exprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (collectExprTypeIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) closureInfo.params
                ++ List.concatMap (\( _, captureExpr, _ ) -> collectExprTypeIssues context captureExpr) closureInfo.captures
                ++ collectExprTypeIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType _ ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context fnExpr
                ++ List.concatMap (collectExprTypeIssues context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, argExpr ) -> collectExprTypeIssues context argExpr) args

        Mono.MonoIf branches elseExpr monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( condExpr, thenExpr ) -> collectExprTypeIssues context condExpr ++ collectExprTypeIssues context thenExpr) branches
                ++ collectExprTypeIssues context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkMonoType context monoType
                ++ collectDefTypeIssues context def
                ++ collectExprTypeIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, branchExpr ) -> collectExprTypeIssues context branchExpr) branches

        Mono.MonoRecordCreate fieldExprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (\( _, e ) -> collectExprTypeIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            checkMonoType context monoType
                ++ collectExprTypeIssues context recordExpr
                ++ List.concatMap (\( _, updateExpr ) -> collectExprTypeIssues context updateExpr) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            checkMonoType context monoType
                ++ List.concatMap (collectExprTypeIssues context) elementExprs

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns the issues, labelled with `context`, in a local definition's body
and, for a tail-recursive definition, its parameter types.

The body's type is checked here and again by the walk of the body, so an
issue in it is usually reported twice.

-}
collectDefTypeIssues : String -> Mono.MonoDef -> List String
collectDefTypeIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            checkMonoType context (Mono.typeOf expr)
                ++ collectExprTypeIssues context expr

        Mono.MonoTailDef _ params expr ->
            checkMonoType context (Mono.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkMonoType context paramType) params
                ++ collectExprTypeIssues context expr


{-| Returns one issue, labelled with `context`, for each number variable in
`monoType`, looking through list element types, custom type arguments, and
function parameter and result types.

A `CEcoValue` variable passes. A tuple or record type passes without its
element or field types being looked at.

-}
checkMonoType : String -> Mono.MonoType -> List String
checkMonoType context monoType =
    case monoType of
        Mono.MInt ->
            []

        Mono.MFloat ->
            []

        Mono.MBool ->
            []

        Mono.MChar ->
            []

        Mono.MString ->
            []

        Mono.MUnit ->
            []

        Mono.MList _ elemType ->
            checkMonoType context elemType

        Mono.MTuple _ _ ->
            []

        Mono.MRecord _ _ ->
            []

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkMonoType context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkMonoType context) paramTypes
                ++ checkMonoType context returnType

        Mono.MVar mvarId constraint ->
            case constraint of
                Mono.CEcoValue ->
                    []

                Mono.CNumber ->
                    [ context ++ ": Found unresolved numeric type variable '" ++ String.fromInt (Id.toComparable mvarId) ++ "' with CNumber constraint" ]
