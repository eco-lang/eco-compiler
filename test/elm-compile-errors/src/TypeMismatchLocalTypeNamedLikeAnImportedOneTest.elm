module TypeMismatchLocalTypeNamedLikeAnImportedOneTest exposing (..)

{-| A local type named `Maybe` is a different type from the core `Maybe`, so mixing them is rejected with a TYPE MISMATCH.

The module declares its own `type Maybe a = Maybe a`, so the unqualified `Maybe`
in `x : Maybe Int` means the local type. The body builds `Maybe.Just 1`, which is
qualified and therefore the core library's `Maybe`. The two types share a name but
are unrelated.

-}

-- COMPILE-ERROR: TYPE MISMATCH, local type named like an imported one
-- CHECK: -- TYPE MISMATCH -

type Maybe a = Maybe a

x : Maybe Int
x = Basics.identity (Basics.always (Maybe.Just 1) 0)
