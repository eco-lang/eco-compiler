module TypeMismatchShaderUnderIntTest exposing (..)

{-| A GLSL shader literal annotated as `Int` is rejected with a TYPE MISMATCH.

`x : Int` is defined as `[glsl| void main () {} |]`, whose type is a `Shader`, not an `Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, shader under Int
-- CHECK: -- TYPE MISMATCH -

x : Int
x = [glsl| void main () {} |]
