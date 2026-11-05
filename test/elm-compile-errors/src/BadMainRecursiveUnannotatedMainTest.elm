module BadMainRecursiveUnannotatedMainTest exposing (..)

{-| BAD MAIN: recursive unannotated main.

From `SourceIR.MainFailsCases` (`cycleCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN, recursive unannotated main
-- CHECK: -- BAD MAIN -
-- CHECK: it is involved in
-- CHECK-NEXT: this cycle of definitions

main x = f x

f x = main x
