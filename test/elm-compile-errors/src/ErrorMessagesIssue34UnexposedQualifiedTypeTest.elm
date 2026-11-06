module ErrorMessagesIssue34UnexposedQualifiedTypeTest exposing (..)

{-| A qualified type that its module does not expose is reported as a NAMING ERROR naming the module.

<https://github.com/elm/error-message-catalog/issues/34>

`foo` is annotated `List.Bar`. `List` is in scope but has no `Bar` type, so the report must say
"The `List` module does not expose a `Bar` type." and must not say the qualifier is not in scope.

-}

-- COMPILE-ERROR: NAMING ERROR, a qualified type that the module does not expose
-- CHECK: -- NAMING ERROR -
-- CHECK: The `List` module does not expose a `Bar` type.
-- CHECK-NOT: not in scope


foo : List.Bar
foo =
    2
