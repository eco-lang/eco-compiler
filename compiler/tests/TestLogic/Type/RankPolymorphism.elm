module TestLogic.Type.RankPolymorphism exposing
    ( expectInferredType
    , expectRejected
    )

{-| Expectations for tests of let-polymorphism (TYPE\_005): which definitions
the type checker generalizes, and the types it infers for them.

Elm's polymorphism is rank-1 with let-generalization. A let-bound definition is
generalized over the type variables that belong to it alone, so it can be used
at several types in the body of the `let`; a variable that also belongs to an
enclosing scope, such as the type of a lambda-bound argument, stays
monomorphic. A function argument is never polymorphic.

  - `expectInferredType name expected` runs the module through type checking
    (`TestLogic.TestPipeline.runToTypeCheck`) and passes when the top-level
    definition `name` gets a type that prints as `expected`, as `typeToString`
    prints it: type names unqualified, `->` between function parts, tuples as
    `( a, b )`, and type variables by the names the solver gives them.
  - `expectRejected` passes when the module canonicalizes and the solver
    rejects it with a type mismatch (`BadExpr` or `BadPattern`), and fails when
    it type checks, fails to canonicalize, or is rejected only for an infinite
    type.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Error.Type as TypeError
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.TypeCheckErrors as TypeCheckErrors


{-| Passes when `srcModule` type checks and the top-level definition `name` is
given a type that prints as `expected`.
-}
expectInferredType : Name -> String -> Src.Module -> Expect.Expectation
expectInferredType name expected srcModule =
    case Pipeline.runToTypeCheck srcModule of
        Err msg ->
            Expect.fail (msg ++ ": " ++ TypeCheckErrors.describeOutcome (TypeCheckErrors.typeCheck srcModule))

        Ok result ->
            case Dict.get name result.annotations of
                Just (Can.Forall _ tipe) ->
                    Expect.equal expected (typeToString tipe)

                Nothing ->
                    Expect.fail ("No annotation was inferred for " ++ name)


{-| Passes when `srcModule` canonicalizes and the solver rejects it with a type
mismatch.
-}
expectRejected : Src.Module -> Expect.Expectation
expectRejected srcModule =
    TypeCheckErrors.expectTypeErrorWhere "a type mismatch"
        (\error ->
            case error of
                TypeError.InfiniteType _ _ _ ->
                    False

                _ ->
                    True
        )
        srcModule


{-| Prints a type as Elm source, with type names unqualified. A function
argument that is itself a function is parenthesized.
-}
typeToString : Can.Type Name -> String
typeToString tipe =
    case tipe of
        Can.TLambda _ arg result ->
            let
                argString =
                    case arg of
                        Can.TLambda _ _ _ ->
                            "(" ++ typeToString arg ++ ")"

                        _ ->
                            typeToString arg
            in
            argString ++ " -> " ++ typeToString result

        Can.TVar name ->
            name

        Can.TType _ name [] ->
            name

        Can.TType _ name args ->
            name ++ " " ++ String.join " " (List.map argToString args)

        Can.TRecord fields ext ->
            "{ "
                ++ (case ext of
                        Just e ->
                            e ++ " | "

                        Nothing ->
                            ""
                   )
                ++ String.join ", " (List.map (\( f, Can.FieldType _ t ) -> f ++ " : " ++ typeToString t) (Dict.toList fields))
                ++ " }"

        Can.TUnit ->
            "()"

        Can.TTuple a b cs ->
            "( " ++ String.join ", " (List.map typeToString (a :: b :: cs)) ++ " )"

        Can.TAlias _ name [] _ ->
            name

        Can.TAlias _ name args _ ->
            name ++ " " ++ String.join " " (List.map (Tuple.second >> argToString) args)


{-| Prints a type argument, parenthesizing it when it has spaces of its own and
is not already bracketed.
-}
argToString : Can.Type Name -> String
argToString tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            "(" ++ typeToString tipe ++ ")"

        Can.TType _ _ (_ :: _) ->
            "(" ++ typeToString tipe ++ ")"

        Can.TAlias _ _ (_ :: _) _ ->
            "(" ++ typeToString tipe ++ ")"

        _ ->
            typeToString tipe
