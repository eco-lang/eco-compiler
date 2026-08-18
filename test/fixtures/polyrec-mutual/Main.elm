module Main exposing (main)

{-| MONO_030 watchdog repro fixture
(`plans/lss-fidelity-1-watchdogs-budget-accounting.md` §1.1).

Polymorphic recursion through an ANNOTATED, MUTUALLY RECURSIVE cycle —
legal Elm (each cycle member sees the other's annotation as a generalized
scheme; only self-recursion is rejected). The JS target compiles and runs
this; the native pipeline's monomorphizer chases the demand chain
`Nested Int → Nested (List Int) → Nested (List (List Int)) → …`.

Pre-watchdog behavior (verified 2026-08-18, default config): the front end
prints `Success! Compiled 1 module.` and the compile then never terminates
(killed by timeout; RSS monotonically climbing).

Post-watchdog: a clean `specialization budget exceeded` error naming
`depth`/`helper` and `ECO_SPEC_BREADTH_LIMIT`.

Manual check (do NOT add this file to any compiled suite — under a
watchdog-less compiler it hangs the build; `test/elm/src/` in particular
compiles everything expecting success):

    cd $(mktemp -d) && <eco> init   # or any scratch project
    cp this file into src/Main.elm
    ECO_SPEC_BREADTH_LIMIT=50 timeout 120 <eco> make src/Main.elm --output=main.mlir
    # expect: clean watchdog error, NOT exit 124

-}


type Nested a
    = Nil
    | Deeper a (Nested (List a))


depth : Nested a -> Int
depth n =
    case n of
        Nil ->
            0

        Deeper _ rest ->
            1 + helper rest


helper : Nested (List a) -> Int
helper n =
    depth n


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Debug.log "depth" (String.fromInt (depth (Deeper 1 Nil))) |> always Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
