module Compiler.Type.OccursCheck exposing
    ( expectInfiniteTypeDetected
    , expectNoInfiniteTypes
    )

{-| Test logic for invariant TYPE_004: Occurs check forbids infinite types.

Force scenarios where a type variable must unify with a structure containing itself
(e.g., `a ~ List a` or recursive record types). Assert `Compiler.Type.Occurs`
triggers and the solver records a type error. Verify that no infinite type is
present in NodeTypes or final schemes.

This module provides tests for the occurs check invariant.

-}

import Compiler.AST.Source as Src
import Expect


{-| Expect type checking to detect an infinite type and report an error.
-}
expectInfiniteTypeDetected : Src.Module -> Expect.Expectation
expectInfiniteTypeDetected srcModule =
    -- TODO_TEST_LOGIC
    -- Force scenarios where a type variable must unify with a structure containing itself
    -- (e.g., `a ~ List a` or recursive record types).
    -- Assert Compiler.Type.Occurs triggers and the solver records a type error.
    -- Oracle: Infinite-type attempts always yield a type error.
    Debug.todo "Occurs check detects infinite type"


{-| Verify that valid code has no infinite types in NodeTypes or final schemes.
-}
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    -- TODO_TEST_LOGIC
    -- After type checking, verify that no infinite type is present in NodeTypes or final schemes.
    -- Traverse all types in NodeTypes and type schemes, checking for cyclic structures.
    -- Oracle: Inspector utilities never see cyclic type structures.
    Debug.todo "No infinite types in NodeTypes or final schemes"
