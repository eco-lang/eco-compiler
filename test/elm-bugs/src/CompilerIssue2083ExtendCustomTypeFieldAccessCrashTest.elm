module CompilerIssue2083ExtendCustomTypeFieldAccessCrashTest exposing (..)

{-| Extending a custom type as if it were a record must be rejected with an error report, not
crash the compiler.

<https://github.com/elm/compiler/issues/2083>

`Article a` is the extensible record `{ a | title : String, tags : List String }`, so `Article
Preview` extends the custom type `Preview`, and `id` then reads `p.id` from it. Elm 0.19.1 crashes
("Used toErrorType on a type that is not well-formed"); it should report an error.

-}

-- COMPILE-ERROR: extending a non-record
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: not well-formed

import Html


type alias Article a =
    { a | title : String, tags : List String }


type Preview
    = Article { id : Int }


id : Article Preview -> Int
id p =
    p.id


main =
    Html.text ""
