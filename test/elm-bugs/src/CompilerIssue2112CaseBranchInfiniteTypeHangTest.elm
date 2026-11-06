module CompilerIssue2112CaseBranchInfiniteTypeHangTest exposing (main)

{-| `case` branches whose types differ by an infinite type.

<https://github.com/elm/compiler/issues/2112>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

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
