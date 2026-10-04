module TestLogic.Type.PostSolve.GroupBTypes exposing (expectGroupBTypesValid)

{-| Checks that no node type left by PostSolve holds a type variable whose name
starts with a digit.

Constraint generation types some expressions, its _Group B_, through a
_synthetic placeholder_: a fresh type variable it allocates for an expression
with no result variable of its own, such as a string, character, float or unit
literal (`Compiler.Type.Constrain.Typed.Expression` makes the split).
`Compiler.Type.PostSolve` then rewrites the types of some of those expressions.

`expectGroupBTypesValid` runs the program to PostSolve and searches every
node type PostSolve returns, not only those of Group B expressions. This
module takes a placeholder to be a `TVar` whose name starts with a digit, and
fails on any such variable. The names the solver generates for type variables
start with a letter (`Compiler.Data.Name.fromTypeVariableScheme`), so no
variable the solver named can fail the check.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` compiles through PostSolve and no node type after
PostSolve holds a `TVar` whose name starts with a digit.

A canonicalization or type error fails with the pipeline's message. When
several variables are found, the failure names only one of them, with the id
of the node whose type holds it.

-}
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                checks =
                    collectGroupBTypeChecks result.nodeTypesPost
            in
            case checks of
                -- Expect.all fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- GROUP B TYPE VERIFICATION
-- ============================================================================


{-| Returns one failing check for each digit-named `TVar` in `nodeTypes`,
labelled with the id of the node whose type holds it.

The array index is the node id. Every node with a type is searched, whatever
its expression or pattern form.

-}
collectGroupBTypeChecks : Array.Array (Maybe (Can.Type Name)) -> List (() -> Expect.Expectation)
collectGroupBTypeChecks nodeTypes =
    Array.foldl
        (\maybeType ( nodeId, acc ) ->
            case maybeType of
                Nothing ->
                    ( nodeId + 1, acc )

                Just canType ->
                    ( nodeId + 1, checkTypeForSyntheticVars ("NodeId " ++ String.fromInt nodeId) canType ++ acc )
        )
        ( 0, [] )
        nodeTypes
        |> Tuple.second


{-| Returns one failing check, labelled with `context`, for each occurrence of
a digit-named `TVar` in `canType`.

The search goes through function types, the arguments of a named type,
record-field and tuple types, and through both an alias's arguments and its
body. A record's extension variable is not looked at.

-}
checkTypeForSyntheticVars : String -> Can.Type Name -> List (() -> Expect.Expectation)
checkTypeForSyntheticVars context canType =
    case canType of
        Can.TVar name ->
            if isSyntheticVarName name then
                [ \() -> Expect.fail (context ++ ": Found synthetic type variable '" ++ name ++ "'") ]

            else
                []

        Can.TLambda _ argType resultType ->
            checkTypeForSyntheticVars context argType
                ++ checkTypeForSyntheticVars context resultType

        Can.TType _ _ args ->
            List.concatMap (checkTypeForSyntheticVars context) args

        Can.TRecord fields _ ->
            Dict.foldl
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


{-| Returns the checks `checkTypeForSyntheticVars` gives for the body of an
alias, whether `Holey` or `Filled`.
-}
checkAliasedTypeForSyntheticVars : String -> Can.AliasType Name -> List (() -> Expect.Expectation)
checkAliasedTypeForSyntheticVars context aliasType =
    case aliasType of
        Can.Holey canType ->
            checkTypeForSyntheticVars context canType

        Can.Filled canType ->
            checkTypeForSyntheticVars context canType


{-| Tells whether `name` starts with a digit, which is what this module takes
to mark a solver placeholder. The empty name does not.
-}
isSyntheticVarName : String -> Bool
isSyntheticVarName name =
    case String.uncons name of
        Just ( first, _ ) ->
            Char.isDigit first

        Nothing ->
            False
