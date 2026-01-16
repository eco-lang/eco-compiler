module Compiler.Type.PostSolve.GroupBTypes exposing
    ( expectGroupBTypesValid
    )

{-| Test logic for invariant POST_001: GroupB types are fully resolved.

After solving, verify that all GroupB (mutually recursive) definitions
have fully resolved types with no remaining unification variables.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| Verify that Group B expressions get structural types.
-}
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    case TOMono.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectGroupBTypeIssues result.nodeTypes
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- GROUP B TYPE VERIFICATION
-- ============================================================================


{-| Collect issues with Group B types.

Group B expressions (lists, tuples, records, units, lambdas) should have
fully structural types after PostSolve, with no unconstrained synthetic variables.

-}
collectGroupBTypeIssues : Dict.Dict Int Int Can.Type -> List String
collectGroupBTypeIssues nodeTypes =
    Dict.foldl compare
        (\nodeId canType acc ->
            checkTypeForSyntheticVars ("NodeId " ++ String.fromInt nodeId) canType ++ acc
        )
        []
        nodeTypes


{-| Check a type for unconstrained synthetic variables.

After PostSolve, types should be fully concrete with no synthetic variables
(represented as TVar with specific naming patterns).

-}
checkTypeForSyntheticVars : String -> Can.Type -> List String
checkTypeForSyntheticVars context canType =
    case canType of
        Can.TVar name ->
            -- Check if this looks like a synthetic variable
            -- Synthetic variables typically have numeric suffixes or special prefixes
            if isSyntheticVarName name then
                [ context ++ ": Found synthetic type variable '" ++ name ++ "'" ]

            else
                []

        Can.TLambda argType resultType ->
            checkTypeForSyntheticVars context argType
                ++ checkTypeForSyntheticVars context resultType

        Can.TType _ _ args ->
            List.concatMap (checkTypeForSyntheticVars context) args

        Can.TRecord fields _ ->
            Dict.foldl compare
                (\_ (Can.FieldType _ fieldType) acc ->
                    checkTypeForSyntheticVars context fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkTypeForSyntheticVars context a
                ++ checkTypeForSyntheticVars context b
                ++ List.concatMap (checkTypeForSyntheticVars context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkTypeForSyntheticVars context argType) args
                ++ checkAliasedTypeForSyntheticVars context aliasedType


{-| Check aliased type for synthetic variables.
-}
checkAliasedTypeForSyntheticVars : String -> Can.AliasType -> List String
checkAliasedTypeForSyntheticVars context aliasType =
    case aliasType of
        Can.Holey canType ->
            checkTypeForSyntheticVars context canType

        Can.Filled canType ->
            checkTypeForSyntheticVars context canType


{-| Check if a type variable name looks like a synthetic variable.

Synthetic variables from the solver typically have patterns like:
- Numeric names (e.g., "1", "23")
- Generated prefixes

User-declared type variables typically use lowercase letters.

-}
isSyntheticVarName : String -> Bool
isSyntheticVarName name =
    case String.uncons name of
        Just ( first, _ ) ->
            -- Synthetic vars often start with digits or are all-numeric
            Char.isDigit first

        Nothing ->
            False
