module TypeMismatchFlexibleRecordWithAnExtraFieldWhereClosedTest exposing (..)

{-| TYPE MISMATCH: flexible record with an extra field where closed.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, flexible record with an extra field where closed
-- CHECK: -- TYPE MISMATCH -
-- CHECK: age

g : { name : Int } -> Int
g r = r.name

h a =
    let
        z = a.age
    in
    g a
