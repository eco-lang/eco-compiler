module TypeMismatchCompappendAgainstARigidVarTest exposing (..)

{-| A value used with both `++` and `<` cannot share a type with an annotation's type variable, and the program is rejected with a TYPE MISMATCH.

Inside `f : a -> Int`, the lambda's argument `b` is appended and compared, so its type must be
both appendable and comparable. Putting `x` and `b` in one list forces `b` to have the type
`a` of `f`'s argument, and `a`, being named in the annotation, stands for any type.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend against a rigid var
-- CHECK: -- TYPE MISMATCH -

f : a -> Int
f x = always 0 (\b -> if b ++ b < b then [ x, b ] else [])
