module TestLogic.Type.PostSolve.NoSyntheticVars exposing (expectNoSyntheticVars)

{-| Gives tests a check that no node type left after PostSolve contains a
type variable whose name looks generated rather than written.

A node is an expression or pattern of the canonical module that carries a
node id. PostSolve produces an array of node types indexed by id, with
`Nothing` for an id that has no type. The check runs the module under test to
PostSolve and walks every type in that array.

A _synthetic_ variable here is decided by its name alone, as
`isSyntheticVariable` does: a name that is empty, starts with a digit, or is
an underscore followed by at least one more character. A lone `_` is not
synthetic. The check sees only names, so a variable the solver invented under
an ordinary name passes. A record's extension variable is not looked at. A
module that fails to canonicalize or type check fails with the pipeline's
message.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through PostSolve and passes when no node type after
PostSolve contains a synthetic variable.

It fails with one line per synthetic variable found, labelled with its node
id, or with the pipeline's message when canonicalization or type checking
fails.

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


{-| Returns one message for each synthetic variable found in `nodeTypes`,
labelled with the array index of the type it was found in, which is the node
id. Record extension variables are not examined.
-}
collectSyntheticVarIssues : Array.Array (Maybe (Can.Type Name)) -> List String
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


{-| Returns one message, starting with `context`, for each type variable in
`canType` whose name `isSyntheticVariable` accepts.

An alias is checked through both its arguments and its body. A record's
extension variable is not examined.

-}
checkForSyntheticVars : String -> Can.Type Name -> List String
checkForSyntheticVars context canType =
    case canType of
        Can.TVar name ->
            if isSyntheticVariable name then
                [ context ++ ": Found unconstrained synthetic variable '" ++ name ++ "'" ]

            else
                []

        Can.TLambda _ argType resultType ->
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


{-| Tells whether a type variable name looks generated: it is empty, starts
with a digit, or is an underscore followed by at least one more character.
-}
isSyntheticVariable : String -> Bool
isSyntheticVariable name =
    case String.uncons name of
        Just ( first, rest ) ->
            Char.isDigit first || (first == '_' && not (String.isEmpty rest))

        Nothing ->
            True
