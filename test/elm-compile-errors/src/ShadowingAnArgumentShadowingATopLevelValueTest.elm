module ShadowingAnArgumentShadowingATopLevelValueTest exposing (..)

{-| A function argument with the same name as a top-level value is rejected with a SHADOWING error.

The argument of `double` is named `scale`, which is also a top-level definition in the
module; Elm does not allow a local name to shadow one already in scope.

-}

-- COMPILE-ERROR: SHADOWING, an argument shadowing a top-level value
-- CHECK: -- SHADOWING -

scale =
    2


double scale =
    scale * 2


testValue =
    double 3
