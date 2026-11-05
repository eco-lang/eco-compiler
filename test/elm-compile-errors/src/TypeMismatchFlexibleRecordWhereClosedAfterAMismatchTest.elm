module TypeMismatchFlexibleRecordWhereClosedAfterAMismatchTest exposing (..)

{-| TYPE MISMATCH: flexible record where closed after a mismatch.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, flexible record where closed after a mismatch
-- CHECK: -- TYPE MISMATCH -
-- CHECK: name : String

g : ( Int, { name : Int } ) -> Int
g p = 0

h a =
    let
        z = a.name ++ "s"
    in
    g ( "s", a )
