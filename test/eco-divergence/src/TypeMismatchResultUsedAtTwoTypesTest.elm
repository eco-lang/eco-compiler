module TypeMismatchResultUsedAtTwoTypesTest exposing (..)

{-| TYPE MISMATCH: result used at two types.

From `SourceIR.TypeCheckFailsCases` (`testValue`), the elm-test catalogue of programs
the compiler must reject.

-}

-- DIVERGENCE: Elm 0.19.1 accepts this ill-typed program (a type checker bug in mutually recursive definitions); eco rejects it
-- COMPILE-ERROR: TYPE MISMATCH, result used at two types
-- CHECK: -- TYPE MISMATCH -
-- CHECK: This expression is being used in an unexpected way:

f b =
    g b


g b =
    if b then
        let
            n =
                f False
        in
        Just (n ++ "!")

    else
        Nothing


testValue =
    case f True of
        Just s ->
            s

        Nothing ->
            ""
