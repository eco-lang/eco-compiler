module BadMainTypeTypeVariableMainTest exposing (..)

{-| An unannotated `main` whose inferred type contains a type variable is rejected with a BAD MAIN TYPE error.

`main = []` has type `List a`.

-}

-- COMPILE-ERROR: BAD MAIN TYPE, type variable main
-- CHECK: -- BAD MAIN TYPE -

main = []
