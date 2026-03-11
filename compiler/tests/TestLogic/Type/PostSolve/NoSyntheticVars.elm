module TestLogic.Type.PostSolve.NoSyntheticVars exposing (expectNoSyntheticVars)

{-| Test logic for invariant POST\_003: No synthetic type variables remain.

After solving, verify that no synthetic (unification) type variables
remain in the final types. All type variables should be either:

  - User-declared type variables in annotations
  - Generalized type variables from let-polymorphism

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Verify that no unconstrained synthetic variables remain after PostSolve.
-}
expectNoSyntheticVars : Src.Module -> Expect.Expectation
expectNoSyntheticVars srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectSyntheticVarIssues result.nodeTypesPost
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- SYNTHETIC VARIABLE VERIFICATION
-- ============================================================================


{-| Collect synthetic variable issues from node types.
-}
collectSyntheticVarIssues : Array.Array (Maybe Can.Type) -> List String
collectSyntheticVarIssues nodeTypes =
    Array.foldl
        (\maybeType ( nodeId, acc ) ->
            case maybeType of
                Nothing ->
                    ( nodeId + 1, acc )

                Just canType ->
                    let
                        context =
                            "NodeId " ++ String.fromInt nodeId
                    in
                    ( nodeId + 1, checkForSyntheticVars context canType ++ acc )
        )
        ( 0, [] )
        nodeTypes
        |> Tuple.second


{-| Check a type for synthetic variables.

Synthetic variables are unification variables that should be resolved
by PostSolve. They typically have:

  - Numeric names
  - Special prefixes from the solver

-}
checkForSyntheticVars : String -> Can.Type -> List String
checkForSyntheticVars context canType =
    case canType of
        Can.TVar name ->
            if isSyntheticVariable name then
                [ context ++ ": Found unconstrained synthetic variable '" ++ name ++ "'" ]

            else
                []

        Can.TLambda argType resultType ->
            checkForSyntheticVars context argType
                ++ checkForSyntheticVars context resultType

        Can.TType _ _ args ->
            List.concatMap (checkForSyntheticVars context) args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ fieldType) acc ->
                    checkForSyntheticVars context fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkForSyntheticVars context a
                ++ checkForSyntheticVars context b
                ++ List.concatMap (checkForSyntheticVars context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkForSyntheticVars context argType) args
                ++ (case aliasedType of
                        Can.Holey t ->
                            checkForSyntheticVars context t

                        Can.Filled t ->
                            checkForSyntheticVars context t
                   )


{-| Check if a type variable name indicates a synthetic variable.

Synthetic variables from unification typically:

  - Have purely numeric names (e.g., "0", "1", "23")
  - Have special prefixes like "\_" or internal markers

User-declared type variables use lowercase letters (a, b, msg, etc.)

-}
isSyntheticVariable : String -> Bool
isSyntheticVariable name =
    case String.uncons name of
        Just ( first, rest ) ->
            -- Synthetic variables often:
            -- 1. Start with digits
            -- 2. Are purely numeric
            -- 3. Start with underscore (internal)
            Char.isDigit first || (first == '_' && not (String.isEmpty rest))

        Nothing ->
            -- Empty name is suspicious
            True
