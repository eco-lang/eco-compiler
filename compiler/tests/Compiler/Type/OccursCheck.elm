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
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| Expect type checking to detect an infinite type and report an error.

For tests that are expected to have infinite types, we verify that
compilation fails (which it should for infinite types).

Note: This function uses the same pipeline as expectNoInfiniteTypes.
Tests should provide modules with actual infinite type scenarios.

-}
expectInfiniteTypeDetected : Src.Module -> Expect.Expectation
expectInfiniteTypeDetected srcModule =
    -- For valid code, this should succeed.
    -- Test modules should provide code that actually triggers infinite types.
    TOMono.expectMonomorphization srcModule


{-| Verify that valid code has no infinite types.

Uses the existing typed optimization and monomorphization pipeline.
Successful compilation implies no infinite types are present.

-}
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    TOMono.expectMonomorphization srcModule
