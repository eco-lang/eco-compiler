module BoolShortCircuitParserIdiomTest exposing (main)

{-| Mirrors the parser idiom that crashed Stage 7 of the self-host bootstrap:

        if pos < end && unsafeIndex src pos == w then ...

    When `pos == end`, the bounds check is False and `unsafeIndex` must never
    run. Under a strict lowering of `&&`, `unsafeIndex` is called at the
    past-end position and its `Nothing` branch crashes — exactly the bootstrap
    failure observed at `/work/compiler/src/Terminal/Main.elm` end-of-file.

-}

-- CHECK: peek at past-end: none
-- CHECK: peek at first: H

import Html exposing (text)


{-| Non-tail-recursive stack bomb. The pending `1 +` prevents TCO, so every
    call consumes stack — guaranteed overflow if ever invoked.
-}
stackBomb : Int -> Int
stackBomb n =
    1 + stackBomb (n + 1)


{-| Crashes on out-of-bounds access, just like
    `Compiler.Parse.Primitives.unsafeIndex`. The Nothing branch recurses into
    `stackBomb` so the native runtime stack-overflows rather than looping
    silently.
-}
unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            -- Unreachable under correct short-circuit semantics.
            Char.fromCode (stackBomb 0)


{-| Bounds-checked peek. Returns Nothing when idx is past end, else Just the
    character. Short-circuit on `&&` is what keeps `unsafeIndex` in-bounds.
-}
peek : String -> Int -> Maybe Char
peek src idx =
    if idx < String.length src && unsafeIndex src idx /= '\u{0000}' then
        Just (unsafeIndex src idx)

    else
        Nothing


main =
    let
        pastEnd : String
        pastEnd =
            case peek "Hi" 2 of
                Just c ->
                    "CHAR:" ++ String.fromChar c

                Nothing ->
                    "none"

        first : String
        first =
            case peek "Hi" 0 of
                Just c ->
                    String.fromChar c

                Nothing ->
                    "none"

        _ =
            Debug.log "peek at past-end" pastEnd

        _ =
            Debug.log "peek at first" first
    in
    text "done"
