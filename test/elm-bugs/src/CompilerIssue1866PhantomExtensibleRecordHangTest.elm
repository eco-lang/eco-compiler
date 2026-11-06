module CompilerIssue1866PhantomExtensibleRecordHangTest exposing (main)

{-| A phantom type over extensible records, composed through a record of functions.

<https://github.com/elm/compiler/issues/1866>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

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
