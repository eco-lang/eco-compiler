module BadMainRecursiveUnannotatedMainTest exposing (..)

{-| BAD MAIN: recursive unannotated main.

From `SourceIR.MainFailsCases` (`cycleCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN, recursive unannotated main
-- CHECK: -- BAD MAIN -

main x = f x

f x = main x
