module BadMainTypeFunctionMainTest exposing (..)

{-| BAD MAIN TYPE: function main.

From `SourceIR.MainFailsCases` (`typeCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, function main
-- CHECK: -- BAD MAIN TYPE -

main : Int -> Int -> Int
main a b = a
