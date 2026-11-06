module CyclicDefinitionATopLevelValueDefinedByItselfTest exposing (..)

{-| A top-level value defined in terms of itself is rejected with a CYCLIC DEFINITION error.

`loop` is defined as `loop + 1`. It takes no arguments, so evaluating it would never finish.

-}

-- COMPILE-ERROR: CYCLIC DEFINITION, a top-level value defined by itself
-- CHECK: -- CYCLIC DEFINITION -

loop =
    loop + 1


testValue =
    loop
