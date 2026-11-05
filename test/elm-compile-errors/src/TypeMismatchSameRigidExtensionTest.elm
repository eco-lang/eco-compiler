module TypeMismatchSameRigidExtensionTest exposing (..)

{-| TYPE MISMATCH: same rigid extension.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, same rigid extension
-- CHECK: -- TYPE MISMATCH -
-- CHECK: { r | name : String }

g : { r | name : Int } -> { r | name : String }
g r = r
