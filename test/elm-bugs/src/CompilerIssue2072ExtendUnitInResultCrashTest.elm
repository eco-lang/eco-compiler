module CompilerIssue2072ExtendUnitInResultCrashTest exposing (..)

{-| A result annotation that extends `()` as if it were a record must be rejected with an error
report, not crash the compiler.

<https://github.com/elm/compiler/issues/2072>

`subscribed` is annotated to return `Tagged ()`, and `Tagged a` is the extensible record
`{ a | tags : List String }`, so this extends the non-record `()`. Elm 0.19.1 crashes; it should
report an error.

-}

-- COMPILE-ERROR: extending a non-record
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: CallStack

import Html


type alias Tagged a =
    { a | tags : List String }


type alias Subscribed a =
    { a | subscriptions : List Int }


type alias Person =
    Tagged (Subscribed { name : String })


type alias Tag =
    Tagged {}


subscribed : Subscribed a -> Tagged ()
subscribed _ =
    let
        t : Tag
        t =
            { tags = [ "elm" ] }
    in
    t


main =
    let
        p : Person
        p =
            { name = "n", tags = [], subscriptions = [] }
    in
    Html.text (Debug.toString (subscribed p))
