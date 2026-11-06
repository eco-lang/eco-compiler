module AliasProblemExtensibleRecordUnitTupleAndFunctionTest exposing (..)

{-| A type alias that refers to itself inside an extensible record is rejected with an ALIAS PROBLEM.

`A r` is an extensible record whose field `f` holds a tuple of a unit, an `A r`
(parenthesised around a block comment) and a function returning `A r`. A type alias
cannot be recursive, so the compiler must report the self-reference.

-}

-- COMPILE-ERROR: ALIAS PROBLEM, extensible record, unit, tuple and function
-- CHECK: -- ALIAS PROBLEM -

type alias A r = { r | f : ( (), ( {- A -} A r ), Int -> A r ) }
