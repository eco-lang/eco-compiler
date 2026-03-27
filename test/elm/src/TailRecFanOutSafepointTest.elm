module TailRecFanOutSafepointTest exposing (main)

{-| Test tail-recursive function with case on a custom type with 3+
constructors, where multiple branches allocate (triggering safepoints).
This exercises TailRec.compileCaseFanOutStep — the code path that
generates multi-result eco.case inside scf.while.  Cross-sibling-region
safepoint references would cause an MLIR parse error in eco-boot-native.
-}

-- CHECK: result: "ab*"

import Html exposing (text)


type Doc
    = Empty
    | Text String Doc
    | Line Int Doc


{-| Tail-recursive flatten: each branch allocates a (::) cons cell,
so safepoints are emitted inside every eco.case alternative region.
With 3 constructors the compiler takes the fan-out path, not a chain.
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
