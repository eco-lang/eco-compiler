module TypeMismatchRigidExtensionWhereClosedTest exposing (..)

{-| TYPE MISMATCH: rigid extension where closed.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid extension where closed
-- CHECK: -- TYPE MISMATCH -
-- CHECK: { r | name : Int }

g : { r | name : Int } -> { name : Int }
g r = r
