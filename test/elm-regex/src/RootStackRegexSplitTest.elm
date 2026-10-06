module RootStackRegexSplitTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `Regex.split` into a long list of parts.

`Elm_Kernel_Regex_splitAtMost` pushes one root record per part.
-}

-- CHECK: parts: 70000

import Html exposing (text)
import Regex


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


comma : Regex.Regex
comma =
    Maybe.withDefault Regex.never (Regex.fromString ",")


main =
    let
        _ =
            Debug.log "parts" (List.length (Regex.split comma (String.join "," strs)))

    in
    text "done"
