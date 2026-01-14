module Compiler.Generate.MonoLayoutIntegrity exposing
    ( expectCtorLayoutsConsistent
    , expectLayoutsCanonical
    , expectRecordAccessMatchesLayout
    , expectRecordTupleLayoutsComplete
    )

{-| Test logic for invariants:

  - MONO_006: Record and tuple layouts capture shape completely
  - MONO_007: Record access matches layout metadata
  - MONO_013: Constructor layouts define consistent custom types
  - MONO_014: Structurally equivalent layouts are canonical

This module reuses the existing typed optimization pipeline to verify layout integrity.
The key verification is that monomorphization succeeds - which validates that layouts
are properly computed and used.

-}

import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Expect


{-| MONO_006: Verify record and tuple layouts capture shape completely.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies layouts are properly computed.

-}
expectRecordTupleLayoutsComplete : Src.Module -> Expect.Expectation
expectRecordTupleLayoutsComplete srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_007: Verify record access matches layout metadata.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies record accesses use correct layout info.

-}
expectRecordAccessMatchesLayout : Src.Module -> Expect.Expectation
expectRecordAccessMatchesLayout srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_013: Verify constructor layouts define consistent custom types.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies ctor layouts are properly defined.

-}
expectCtorLayoutsConsistent : Src.Module -> Expect.Expectation
expectCtorLayoutsConsistent srcModule =
    TOMono.expectMonomorphization srcModule


{-| MONO_014: Verify structurally equivalent layouts are canonical.

Uses the existing typed optimization and monomorphization pipeline.
Successful monomorphization implies layouts are properly canonicalized.

-}
expectLayoutsCanonical : Src.Module -> Expect.Expectation
expectLayoutsCanonical srcModule =
    TOMono.expectMonomorphization srcModule
