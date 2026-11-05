module TypeMismatchShaderUnderIntTest exposing (..)

{-| TYPE MISMATCH: shader under Int.

From `SourceIR.TypeCheckFailsCases` (`categoryCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, shader under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = [glsl| void main () {} |]
