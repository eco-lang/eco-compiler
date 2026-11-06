module ErrorMessagesIssue188TypeAnnotationJuxtapositionTest exposing (..)

{-| The type annotation `foo : () String Float` is rejected, and not as a TYPE MISMATCH.

<https://github.com/elm/error-message-catalog/issues/188>

The annotation places the unit type `()` before `String` and `Float` with no separator. The
test accepts any error heading except TYPE MISMATCH, which would compare the body
`( "foo", 3.2 )` against the malformed annotation.

-}

-- COMPILE-ERROR: a type annotation that does not parse
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: TYPE MISMATCH


foo : () String Float
foo =
    ( "foo", 3.2 )
