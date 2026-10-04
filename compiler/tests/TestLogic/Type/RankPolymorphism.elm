module TestLogic.Type.RankPolymorphism exposing (expectRankPolymorphismValid)

{-| An expectation for tests of let-polymorphism to apply to a source module
they build. Without one, a module whose polymorphic definitions should type
check could be rejected unnoticed.

Elm's polymorphism is rank-1: a polymorphic type quantifies its type
variables once, at the outside of the whole type, so no argument of a function
can itself be required to be polymorphic. A type whose argument is polymorphic
in that sense is _higher-rank_. In the canonical AST the quantifier is the
`Can.Forall` around an annotation, and `Can.Type` has no constructor for one,
so a canonical type cannot express a higher-rank type at all.

The expectation runs a module through PostSolve with
`TestLogic.TestPipeline.runToPostSolve`, which fails only when canonicalizing or
type checking fails, and then walks the type of each top-level annotation the
type checker returned. Let-bound definitions have no entry there. The walk
reports nothing for any type: a type variable gives no issue, and the
higher-rank check made on each function argument type gives none in every
case. So the expectation's outcome is decided by the pipeline alone.

What `expectRankPolymorphismValid` establishes:

  - A module that fails to canonicalize or type check fails, with the
    pipeline's message, which gives only the number of errors.
  - A module that type checks passes.

Among what is not tested: the rank at which any type variable is generalized,
whether a let-bound definition is generalized, monomorphization, and the
rejection of higher-rank types.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through PostSolve and passes if it gets there.

A failure to canonicalize or type check fails with the pipeline's message. The
walk over the module's top-level annotations finds no issue in any type, so a
module that type checks always passes.

-}
expectRankPolymorphismValid : Src.Module -> Expect.Expectation
expectRankPolymorphismValid srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectRankIssues result.annotations
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- ANNOTATION WALK
-- ============================================================================


{-| Returns the issues `checkAnnotationRank` finds in each of `annotations`,
keyed by name, joined into one list. It is always empty.
-}
collectRankIssues : Dict.Dict String (Can.Annotation Name) -> List String
collectRankIssues annotations =
    Dict.foldl
        (\name annotation acc ->
            checkAnnotationRank name annotation ++ acc
        )
        []
        annotations


{-| Returns the issues `checkTypeForRankIssues` finds in the type of
`annotation`, given `name` as its context. The annotation's quantified
variables are not looked at. The result is always empty.
-}
checkAnnotationRank : String -> Can.Annotation Name -> List String
checkAnnotationRank name annotation =
    case annotation of
        Can.Forall _ canType ->
            checkTypeForRankIssues name canType


{-| Returns the issues found in `canType` and every type inside it. The only
source of an issue is `checkForHigherRank`, made on the argument type of each
function type, and that never finds one, so the result is always empty.

For an alias the walk covers both the alias's arguments and the type it stands
for. `context` is passed on unchanged.

-}
checkTypeForRankIssues : String -> Can.Type Name -> List String
checkTypeForRankIssues context canType =
    case canType of
        Can.TVar _ ->
            []

        Can.TLambda _ argType resultType ->
            checkForHigherRank context argType
                ++ checkTypeForRankIssues context argType
                ++ checkTypeForRankIssues context resultType

        Can.TType _ _ args ->
            List.concatMap (checkTypeForRankIssues context) args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ fieldType) acc ->
                    checkTypeForRankIssues context fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkTypeForRankIssues context a
                ++ checkTypeForRankIssues context b
                ++ List.concatMap (checkTypeForRankIssues context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkTypeForRankIssues context argType) args
                ++ (case aliasedType of
                        Can.Holey t ->
                            checkTypeForRankIssues context t

                        Can.Filled t ->
                            checkTypeForRankIssues context t
                   )


{-| Returns the higher-rank issues in a function's argument type `canType`,
which are always none, whatever the type and the context.

A higher-rank type would need a quantifier inside the argument type, and
`Can.Type` has no constructor for one.

-}
checkForHigherRank : String -> Can.Type Name -> List String
checkForHigherRank _ canType =
    case canType of
        Can.TLambda _ _ _ ->
            []

        _ ->
            []
