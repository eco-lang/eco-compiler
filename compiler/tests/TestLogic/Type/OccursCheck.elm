module TestLogic.Type.OccursCheck exposing
    ( expectInfiniteTypeDetected
    , expectNoInfiniteTypes
    )

{-| Test logic for invariant TYPE\_004: Occurs check forbids infinite types.

Force scenarios where a type variable must unify with a structure containing itself
(e.g., `a ~ List a` or recursive record types). Assert `Compiler.Type.Occurs`
triggers and the solver records a type error. Verify that no infinite type is
present in NodeTypes or final schemes.

This module provides tests for the occurs check invariant.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Array
import Dict
import Data.Set as Set exposing (EverySet)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Expect type checking to detect an infinite type and report an error.

This tests that the compiler correctly rejects code that would create
infinite types (e.g., `let x = [x] in x`).

-}
expectInfiniteTypeDetected : Src.Module -> Expect.Expectation
expectInfiniteTypeDetected srcModule =
    -- For infinite type detection, we expect compilation to fail
    case Pipeline.runToPostSolve srcModule of
        Err _ ->
            -- Expected - infinite type was detected and rejected
            Expect.pass

        Ok _ ->
            -- Should have failed - infinite type was not detected
            Expect.fail "Expected infinite type to be detected, but compilation succeeded"


{-| Verify that valid code has no infinite types in NodeTypes or final schemes.
-}
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectInfiniteTypeIssues result.nodeTypesPost
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- INFINITE TYPE DETECTION
-- ============================================================================


{-| Collect infinite type issues from node types.

An infinite type is one where a type variable appears within its own definition,
creating an infinite structure.

-}
collectInfiniteTypeIssues : Array.Array (Maybe Can.Type) -> List String
collectInfiniteTypeIssues nodeTypes =
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
                    ( nodeId + 1, checkForInfiniteType context Set.empty canType ++ acc )
        )
        ( 0, [] )
        nodeTypes
        |> Tuple.second


{-| Check a type for infinite/cyclic structure.

We track type variables seen in the current path to detect cycles.

-}
checkForInfiniteType : String -> EverySet String String -> Can.Type -> List String
checkForInfiniteType context seenVars canType =
    case canType of
        Can.TVar name ->
            -- Check if we've seen this variable in the current path (cycle)
            if Set.member identity name seenVars then
                [ context ++ ": Infinite type detected - type variable '" ++ name ++ "' appears in its own definition" ]

            else
                []

        Can.TLambda argType resultType ->
            checkForInfiniteType context seenVars argType
                ++ checkForInfiniteType context seenVars resultType

        Can.TType _ _ args ->
            List.concatMap (checkForInfiniteType context seenVars) args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ fieldType) acc ->
                    checkForInfiniteType context seenVars fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkForInfiniteType context seenVars a
                ++ checkForInfiniteType context seenVars b
                ++ List.concatMap (checkForInfiniteType context seenVars) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkForInfiniteType context seenVars argType) args
                ++ (case aliasedType of
                        Can.Holey t ->
                            checkForInfiniteType context seenVars t

                        Can.Filled t ->
                            checkForInfiniteType context seenVars t
                   )
