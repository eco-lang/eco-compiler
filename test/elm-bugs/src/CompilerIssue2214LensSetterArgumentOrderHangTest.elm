module CompilerIssue2214LensSetterArgumentOrderHangTest exposing (main)

{-| The compiler rejects, with a type error, a lens record whose setter takes its arguments in the wrong order.

<https://github.com/elm/compiler/issues/2214>

`Lens Foo Int` needs a setter of type `Int -> Foo -> Foo`, but `fooN` supplies
`\foo n -> { foo | n = n }`, which takes the `Foo` first. Elm 0.19.1 does not report this: it
hangs with memory growing without bound, or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type alias Lens a b =
    { get : a -> b
    , set : b -> a -> a
    }

type alias Foo =
    { n : Int }

fooN : Lens Foo Int
fooN =
    Lens .n (\foo n -> { foo | n = n })


main =
    Html.text ""
