module AliasProblemExtensibleRecordUnitTupleAndFunctionTest exposing (..)

{-| ALIAS PROBLEM: extensible record, unit, tuple and function.

From `SourceIR.CanonicalizeFailsCases` (`aliasCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: ALIAS PROBLEM, extensible record, unit, tuple and function
-- CHECK: -- ALIAS PROBLEM -

type alias A r = { r | f : ( (), ( {- A -} A r ), Int -> A r ) }
