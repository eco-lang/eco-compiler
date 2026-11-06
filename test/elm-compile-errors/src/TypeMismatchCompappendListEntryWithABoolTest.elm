module TypeMismatchCompappendListEntryWithABoolTest exposing (..)

{-| A list holding a value used with both `++` and `<` alongside `True` is rejected with a TYPE MISMATCH, because `Bool` can be neither appended nor compared.

-}

-- COMPILE-ERROR: TYPE MISMATCH, compappend list entry with a Bool
-- CHECK: -- TYPE MISMATCH -

f a = [ (if a ++ a < a then a else a), True ]
