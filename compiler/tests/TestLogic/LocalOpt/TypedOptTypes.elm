module TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)

{-| A check that every expression the typed optimizer produces carries a type,
which in practice passes for any program that reaches typed optimization:
the walk visits the expressions, but the test it applies to each type reports
nothing.

The subject is the _typed local graph_, the `TOpt.LocalGraph` that
`TestLogic.TestPipeline.runToTypedOpt` builds for one test program: a map
from global to node, in which the nodes for its definitions hold
`Compiler.AST.TypedOptimized` expressions. Every such expression carries its
type in its `Meta`, as a `Can.Type` rather than a `Maybe`, so a missing type
cannot be built at all. What a check could still find is a malformed type,
and nothing here tests a type's shape.

`expectAllExprsHaveTypes` runs the program to typed optimization and walks the
graph. For each expression it reaches it takes `TOpt.typeOf` and hands it,
labelled with the node it came from, to `checkTypeNotEmpty`, which returns no
issues for any type. So the expectation fails only when `runToTypedOpt`
returns `Err`.

Among what is not walked, should the per-type test ever report anything:

  - the value expressions of a `Cycle` node (only its definitions are walked);
  - `Ctor`, `Enum`, `Box`, `Link`, `Manager` and `Kernel` nodes;
  - branch bodies inlined into a `case`'s decision tree (only the bodies its
    jumps target are walked);
  - the graph's `main`, and the types a `Destruct` stores in its destructor.

The second half of the file, from `checkDefTypeWellFormedness` on, is a second
walk, starting from one definition, that follows the same expressions as the
first and also recurses into each type it reaches. Nothing outside that walk
calls it, and it too reports no issues for any input.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and passes if no expression in its
typed local graph is reported for its type.

No expression ever is, so this passes exactly when
`TestLogic.TestPipeline.runToTypedOpt` gives `Ok`, and otherwise fails with
that function's message. The program must define `testValue`, as
`TestLogic.TestPipeline` describes.

-}
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectExprTypeIssues result.localGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- EXPRESSION TYPE VERIFICATION
-- ============================================================================


{-| Returns the issues reported for the nodes of a typed local graph, each node
labelled by its global as `Module.name`. The list is always empty.
-}
collectExprTypeIssues : TOpt.LocalGraph Name -> List String
collectExprTypeIssues (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeExprsHaveTypes context node ++ acc
        )
        []
        data.nodes


{-| Returns a global as `Module.name`, leaving out the package.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Returns the issues for the expressions of one node: the body of a `Define`,
`TrackedDefine`, `PortIncoming` or `PortOutgoing` node with the expressions
nested in it that `collectExprNestedTypeIssues` follows, or the definitions of
a `Cycle`. A `Cycle`'s value expressions and every other kind of node give no
issues without being looked at.
-}
checkNodeExprsHaveTypes : String -> TOpt.Node Name -> List String
checkNodeExprsHaveTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            checkTypeNotEmpty
                ++ collectExprNestedTypeIssues context expr

        TOpt.TrackedDefine _ expr _ _ ->
            checkTypeNotEmpty
                ++ collectExprNestedTypeIssues context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefExprsHaveTypes context def) defs

        TOpt.PortIncoming expr _ _ ->
            checkTypeNotEmpty
                ++ collectExprNestedTypeIssues context expr

        TOpt.PortOutgoing expr _ _ ->
            checkTypeNotEmpty
                ++ collectExprNestedTypeIssues context expr

        _ ->
            []


{-| Returns the issues for one local or cycle definition: the type of its body,
the types of a `TailDef`'s parameters, and the expressions in the body that
`collectExprNestedTypeIssues` follows.
-}
checkDefExprsHaveTypes : String -> TOpt.Def Name -> List String
checkDefExprsHaveTypes context def =
    case def of
        TOpt.Def _ _ expr _ ->
            checkTypeNotEmpty
                ++ collectExprNestedTypeIssues context expr

        TOpt.TailDef _ _ params expr _ _ ->
            checkTypeNotEmpty
                ++ List.concatMap (\_ -> checkTypeNotEmpty) params
                ++ collectExprNestedTypeIssues context expr


{-| Returns the issues for the type of `expr` and of every expression nested in
it, and for the parameter types of any function inside it.

A `case` is followed only into the branch bodies its jumps target, not into
bodies inlined in its decision tree, and a `Destruct` only into its body.

-}
collectExprNestedTypeIssues : String -> TOpt.Expr Name -> List String
collectExprNestedTypeIssues context expr =
    let
        typeIssue =
            checkTypeNotEmpty
    in
    typeIssue
        ++ (case expr of
                TOpt.Function _ params bodyExpr _ ->
                    List.concatMap (\_ -> checkTypeNotEmpty) params
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.TrackedFunction _ params bodyExpr _ ->
                    List.concatMap (\_ -> checkTypeNotEmpty) params
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.Call _ fnExpr argExprs _ ->
                    collectExprNestedTypeIssues context fnExpr
                        ++ List.concatMap (collectExprNestedTypeIssues context) argExprs

                TOpt.TailCall _ args _ ->
                    List.concatMap (\( _, argExpr ) -> collectExprNestedTypeIssues context argExpr) args

                TOpt.If branches elseExpr _ ->
                    List.concatMap (\( c, t ) -> collectExprNestedTypeIssues context c ++ collectExprNestedTypeIssues context t) branches
                        ++ collectExprNestedTypeIssues context elseExpr

                TOpt.Let def bodyExpr _ ->
                    checkDefExprsHaveTypes context def
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.Destruct _ valueExpr _ ->
                    collectExprNestedTypeIssues context valueExpr

                TOpt.Case _ _ _ branches _ ->
                    List.concatMap (\( _, branchExpr ) -> collectExprNestedTypeIssues context branchExpr) branches

                TOpt.List _ exprs _ ->
                    List.concatMap (collectExprNestedTypeIssues context) exprs

                TOpt.Access recordExpr _ _ _ ->
                    collectExprNestedTypeIssues context recordExpr

                TOpt.Update _ recordExpr updates _ ->
                    collectExprNestedTypeIssues context recordExpr
                        ++ Data.Map.foldl (\_ updateExpr acc -> collectExprNestedTypeIssues context updateExpr ++ acc) [] updates

                TOpt.Record fieldExprs _ ->
                    Dict.foldl (\_ fieldExpr acc -> collectExprNestedTypeIssues context fieldExpr ++ acc) [] fieldExprs

                TOpt.TrackedRecord _ fieldExprs _ ->
                    Data.Map.foldl (\_ fieldExpr acc -> collectExprNestedTypeIssues context fieldExpr ++ acc) [] fieldExprs

                TOpt.Tuple _ e1 e2 rest _ ->
                    collectExprNestedTypeIssues context e1
                        ++ collectExprNestedTypeIssues context e2
                        ++ List.concatMap (collectExprNestedTypeIssues context) rest

                _ ->
                    []
           )


{-| Returns no issues for any type: both the context label and the type are
ignored.
-}
checkTypeNotEmpty : List String
checkTypeNotEmpty =
    []



-- ============================================================================
-- TYPE WELL-FORMEDNESS VERIFICATION
-- ============================================================================


{-| Returns the well-formedness issues for one definition: its declared type,
the types of a `TailDef`'s parameters, and the expressions in its body that
`collectExprTypeWellFormedness` follows. The result is always empty.
-}
checkDefTypeWellFormedness : String -> TOpt.Def Name -> List String
checkDefTypeWellFormedness context def =
    case def of
        TOpt.Def _ name expr canType ->
            checkTypeWellFormed (context ++ " Def " ++ name) canType
                ++ collectExprTypeWellFormedness context expr

        TOpt.TailDef _ name params expr canType _ ->
            checkTypeWellFormed (context ++ " TailDef " ++ name) canType
                ++ List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " param") paramType) params
                ++ collectExprTypeWellFormedness context expr


{-| Returns the well-formedness issues for the type of `expr` and of the
nested expressions it follows, and for the parameter types of the functions
among them. A `case` is followed only into the branch bodies its jumps target,
not into bodies inlined in its decision tree, and a `Destruct` only into its
body. It follows the same parts of an expression as
`collectExprNestedTypeIssues`, and is always empty.
-}
collectExprTypeWellFormedness : String -> TOpt.Expr Name -> List String
collectExprTypeWellFormedness context expr =
    let
        exprType =
            TOpt.typeOf expr

        typeIssue =
            checkTypeWellFormed context exprType
    in
    typeIssue
        ++ (case expr of
                TOpt.Function _ params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " Function param") paramType) params
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.TrackedFunction _ params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " TrackedFunction param") paramType) params
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.Call _ fnExpr argExprs _ ->
                    collectExprTypeWellFormedness context fnExpr
                        ++ List.concatMap (collectExprTypeWellFormedness context) argExprs

                TOpt.TailCall _ args _ ->
                    List.concatMap (\( _, argExpr ) -> collectExprTypeWellFormedness context argExpr) args

                TOpt.If branches elseExpr _ ->
                    List.concatMap (\( c, t ) -> collectExprTypeWellFormedness context c ++ collectExprTypeWellFormedness context t) branches
                        ++ collectExprTypeWellFormedness context elseExpr

                TOpt.Let def bodyExpr _ ->
                    checkDefTypeWellFormedness context def
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.Destruct _ valueExpr _ ->
                    collectExprTypeWellFormedness context valueExpr

                TOpt.Case _ _ _ branches _ ->
                    List.concatMap (\( _, branchExpr ) -> collectExprTypeWellFormedness context branchExpr) branches

                TOpt.List _ exprs _ ->
                    List.concatMap (collectExprTypeWellFormedness context) exprs

                TOpt.Access recordExpr _ _ _ ->
                    collectExprTypeWellFormedness context recordExpr

                TOpt.Update _ recordExpr updates _ ->
                    collectExprTypeWellFormedness context recordExpr
                        ++ Data.Map.foldl (\_ updateExpr acc -> collectExprTypeWellFormedness context updateExpr ++ acc) [] updates

                TOpt.Record fieldExprs _ ->
                    Dict.foldl (\_ fieldExpr acc -> collectExprTypeWellFormedness context fieldExpr ++ acc) [] fieldExprs

                TOpt.TrackedRecord _ fieldExprs _ ->
                    Data.Map.foldl (\_ fieldExpr acc -> collectExprTypeWellFormedness context fieldExpr ++ acc) [] fieldExprs

                TOpt.Tuple _ e1 e2 rest _ ->
                    collectExprTypeWellFormedness context e1
                        ++ collectExprTypeWellFormedness context e2
                        ++ List.concatMap (collectExprTypeWellFormedness context) rest

                _ ->
                    []
           )


{-| Returns the well-formedness issues for a type and every type inside it:
function argument and result, type arguments, record field types, tuple
elements, and an alias's arguments and body.

Every leaf gives no issues, so the result is always empty. Nothing checks
that a type variable is bound, that a type constructor exists or that it has
the right number of arguments. A record's extension variable is not looked at.

-}
checkTypeWellFormed : String -> Can.Type Name -> List String
checkTypeWellFormed context canType =
    case canType of
        Can.TLambda _ argType resultType ->
            checkTypeWellFormed context argType
                ++ checkTypeWellFormed context resultType

        Can.TVar _ ->
            []

        Can.TType _ _ args ->
            List.concatMap (checkTypeWellFormed context) args

        Can.TRecord fields _ ->
            Dict.foldl (\_ fieldType acc -> checkFieldTypeWellFormed context fieldType ++ acc) [] fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkTypeWellFormed context a
                ++ checkTypeWellFormed context b
                ++ List.concatMap (checkTypeWellFormed context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkTypeWellFormed context argType) args
                ++ checkAliasedTypeWellFormed context aliasedType


{-| Returns the well-formedness issues for an alias's body, `Holey` or
`Filled` alike.
-}
checkAliasedTypeWellFormed : String -> Can.AliasType Name -> List String
checkAliasedTypeWellFormed context aliasType =
    case aliasType of
        Can.Holey canType ->
            checkTypeWellFormed context canType

        Can.Filled canType ->
            checkTypeWellFormed context canType


{-| Returns the well-formedness issues for a record field's type, ignoring the
field's index.
-}
checkFieldTypeWellFormed : String -> Can.FieldType Name -> List String
checkFieldTypeWellFormed context (Can.FieldType _ canType) =
    checkTypeWellFormed context canType
