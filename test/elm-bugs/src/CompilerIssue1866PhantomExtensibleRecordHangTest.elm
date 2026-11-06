module CompilerIssue1866PhantomExtensibleRecordHangTest exposing (main)

{-| Composing two functions on phantom types over different extensible records, taken from one record argument, is rejected with a type error.

<https://github.com/elm/compiler/issues/1866>

Elm 0.19.1 hangs on it, its memory growing without bound, instead of reporting the error.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html exposing (Html)


type Phantom s
    = Phantom


bug :
    ({ f1 : Phantom { r | a1 : () } -> Phantom { r | a1 : () }
     , f2 : Phantom { r | a2 : () } -> Phantom { r | a2 : () }
     }
     -> Html msg
    )
    -> Html msg
bug configure =
    ()


main : Html msg
main =
    bug (\with -> Phantom |> with.f1 |> with.f2)
