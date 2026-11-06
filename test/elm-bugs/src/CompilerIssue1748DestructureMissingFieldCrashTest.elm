module CompilerIssue1748DestructureMissingFieldCrashTest exposing (..)

{-| Destructuring a record field that does not exist, in an unannotated function, crashes the compiler.

<https://github.com/elm/compiler/issues/1748>

Elm 0.19.1 crashes ("index out of bounds") on this program. It should report a type error.

-}

-- COMPILE-ERROR: field iDontExist does not exist
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: out of bounds

import Browser
import Html


main : Program () { window : Int } msg
main =
    Browser.sandbox
        { init = { window = 1 }
        , view = view
        , update = \_ model -> model
        }


foo : Float
foo =
    0


bar : { window : Int } -> Float
bar model =
    1


view ({ iDontExist } as model) =
    let
        _ =
            foo iDontExist <| bar model
    in
    Html.text ""
