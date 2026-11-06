module ErrorMessagesIssue188TypeAnnotationJuxtapositionTest exposing (..)

{-| A type annotation `() String Float` is a syntax error.

<https://github.com/elm/error-message-catalog/issues/188>

Elm 0.18 parsed `foo : () String Float` and then reported a TYPE MISMATCH between
`( String, Float )` and `( String, Float )`. The annotation must be rejected when it is
parsed.

-}

-- COMPILE-ERROR: a type annotation that does not parse
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: TYPE MISMATCH


foo : () String Float
foo =
    ( "foo", 3.2 )
