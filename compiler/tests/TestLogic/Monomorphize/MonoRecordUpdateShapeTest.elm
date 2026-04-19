module TestLogic.Monomorphize.MonoRecordUpdateShapeTest exposing (suite)

{-| Test suite for the MonoRecordUpdate shape-subset invariant.

For every MonoRecordUpdate node in the MonoGraph, the set of fields on the
input record's type must be a subset of the fields on the update node's
result type. This guards against codegen emitting a construct.record with
too few fields and reading past the heap object in later projections.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoRecordUpdateShape exposing (expectMonoRecordUpdateShape)


suite : Test
suite =
    Test.describe "MonoRecordUpdate shape is >= source record shape"
        [ StandardTestSuites.expectSuite expectMonoRecordUpdateShape "record update result type preserves source fields"
        ]
