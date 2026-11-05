module BadMainTypeRecordMainTest exposing (..)

{-| BAD MAIN TYPE: record main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, record main
-- CHECK: -- BAD MAIN TYPE -

main : { a : Int, b : ( Int, Int, Int ) }
main = { a = 1, b = ( 1, 2, 3 ) }
