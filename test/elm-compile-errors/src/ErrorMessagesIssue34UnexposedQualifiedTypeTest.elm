module ErrorMessagesIssue34UnexposedQualifiedTypeTest exposing (..)

{-| NAMING ERROR: a qualified type that the module does not expose.

<https://github.com/elm/error-message-catalog/issues/34>

Elm 0.16 to 0.18 said "The qualifier `List` is not in scope", which is false: `List` is in
scope, it just has no `Bar` type. The report must say that the module does not expose it.

-}

-- COMPILE-ERROR: NAMING ERROR, a qualified type that the module does not expose
-- CHECK: -- NAMING ERROR -
-- CHECK: The `List` module does not expose a `Bar` type.
-- CHECK-NOT: not in scope


foo : List.Bar
foo =
    2
