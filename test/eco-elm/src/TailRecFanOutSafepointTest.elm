module TailRecFanOutSafepointTest exposing (main)

{-| A self tail-recursive function matching on a custom type with three constructors, where
two branches build a new list cell before the tail call, gives the right result.

`flatten` walks a `Doc`, pushing each `Text` string, and `"*"` for each `Line`, onto the
front of an accumulator, so the result is in reverse order. For
`Text "a" (Text "b" (Line 0 Empty))` it builds `[ "*", "b", "a" ]`, which `join`
concatenates to `"*ba"`.

## eco

Exercises `compileCaseFanOutStep` in compiler/src/Compiler/GenerateMlir/TailRec.elm,
which emits a multi-result `eco.case` inside `scf.while` when a tail-recursive
function cases on a type with three or more constructors. Each branch allocates
a cons cell, so every case region gets a safepoint; a safepoint referring to a
value from a sibling region used to make the generated MLIR fail to parse.

-}

-- CHECK: result: "*ba"

import Html exposing (text)


type Doc
    = Empty
    | Text String Doc
    | Line Int Doc


{-| Returns the strings of `doc`, with `"*"` for each `Line`, in reverse order,
followed by `acc`.
-}
flatten : Doc -> List String -> List String
flatten doc acc =
    case doc of
        Empty ->
            acc

        Text s rest ->
            flatten rest (s :: acc)

        Line _ rest ->
            flatten rest ("*" :: acc)


join : List String -> String
join parts =
    joinHelp parts ""


joinHelp : List String -> String -> String
joinHelp parts acc =
    case parts of
        [] ->
            acc

        p :: rest ->
            joinHelp rest (acc ++ p)


main =
    let
        doc =
            Text "a" (Text "b" (Line 0 Empty))

        parts =
            flatten doc []

        _ = Debug.log "result" (join parts)
    in
    text "done"
