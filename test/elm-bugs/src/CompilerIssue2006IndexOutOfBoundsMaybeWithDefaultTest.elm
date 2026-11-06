module CompilerIssue2006IndexOutOfBoundsMaybeWithDefaultTest exposing (..)

{-| Applying a `Subtype -> Subtype` function to the whole model crashes the compiler.

<https://github.com/elm/compiler/issues/2006>

`func model` passes a `Model` where a `Subtype` is expected. Elm 0.19.1 crashes ("index out of
bounds") instead of reporting the type mismatch.

-}

-- COMPILE-ERROR: Model is not Subtype
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: out of bounds

import Html
import Dict


type alias Subtype =
    { cog : Int }


type alias Model =
    { entry : Dict.Dict Int (Subtype -> Subtype) }


id : Subtype -> Subtype
id x =
    x


repro model key =
    let
        func =
            Maybe.withDefault id (Dict.get key model.entry)
    in
    let
        x =
            func model
    in
    0


main =
    Html.text ""
