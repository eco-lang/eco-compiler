module CompilerIssue2112CaseBranchInfiniteTypeHangTest exposing (main)

{-| `case` branches that could only agree through an infinite type must be rejected with a type
error, not hang the compiler.

<https://github.com/elm/compiler/issues/2112>

In `helper`, the `InputA` branch builds lists of `Maybe (Maybe a)` and the `InputB` branch lists
of `Maybe a`, so the branches agree only if `a` were `Maybe a`. Elm 0.19.1 instead hangs while its
memory grows without bound, or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type Input a
    = InputA (List (Maybe a))
    | InputB (List (List a)) (List (List a))


fn : List a -> List a -> Int
fn _ _ =
    0


helper lines =
    case lines of
        InputA source ->
            ( List.map (\part -> [ Just part ]) source
            , []
            )

        InputB source target ->
            ( List.map (List.map Just) source
            , List.map (List.map Just) target
            )


diff : Int -> Int
diff _ =
    let
        ( source, target ) =
            helper (InputA [])
    in
    fn source target


main =
    Html.text ""
