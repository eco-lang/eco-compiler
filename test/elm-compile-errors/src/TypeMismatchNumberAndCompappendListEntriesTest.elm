module TypeMismatchNumberAndCompappendListEntriesTest exposing (..)

{-| TYPE MISMATCH: number and compappend list entries.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, number and compappend list entries
-- CHECK: -- TYPE MISMATCH -

f a b =
    let
        c = b ++ b
    in
    if c < c then [ a + 1, c ] else []
