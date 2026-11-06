module BoolShortCircuitParserIdiomTest exposing (main)

{-| A bounds check guarding an indexing call with `&&` (`idx < String.length src && unsafeIndex src idx /= ...`) stops the call from running past the end of the string.

`&&` must not evaluate its right operand when the left is `False`. Here the
right operand would reach a branch that recurses without end, so a past-end
peek must print `"none"`, and an in-bounds peek prints the character.
-}

-- CHECK: peek at past-end: "none"
-- CHECK: peek at first: "H"

import Html exposing (text)


{-| Recurses without end; never called when the program is correct.
-}
stackBomb : Int -> Int
stackBomb n =
    1 + stackBomb (n + 1)


{-| Returns the character at `index`, or calls `stackBomb` when `index` is past the end.
-}
unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            -- Unreachable under correct short-circuit semantics.
            Char.fromCode (stackBomb 0)


{-| Returns the character at `idx`, or `Nothing` when `idx` is past the end.
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
