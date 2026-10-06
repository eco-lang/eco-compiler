module RootStackRegexFindTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `Regex.find` returning a long list of matches.

`Elm_Kernel_Regex_findAtMost` pushes one root record per match.
-}

-- CHECK: matches: 70000

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


digits : Regex.Regex
digits =
    Maybe.withDefault Regex.never (Regex.fromString "[0-9]+")


main =
    let
        _ =
            Debug.log "matches" (List.length (Regex.find digits (String.join "," strs)))

    in
    text "done"
