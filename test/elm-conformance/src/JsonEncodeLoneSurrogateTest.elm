module JsonEncodeLoneSurrogateTest exposing (main)

{-| JSON-01 (plans/kernel-lib-bug-fixes.md): `Json.Encode.encode` of a String holding a lone
surrogate. Elm (JSON.stringify) writes a lone surrogate as a `\uXXXX` escape and leaves a valid
pair raw. eco's `Elm_Kernel_Json_encode` used nlohmann `json::dump`, which threw
`type_error.316` on the invalid UTF-8 that a lone surrogate becomes; the exception escaped the
`extern "C"` export, so `std::terminate` ran and nothing after the first case was logged. eco now
writes the text with its own `JSON.stringify`-like serializer (`writeJsJson`).
Expected values recorded from Elm on node. Kept in its own file so a crash hides no other
JSON CHECKs. The emoji is written as `Char.fromCode 0x1F600` to keep the source ASCII.

-}

-- CHECK: lone high: "\"\\ud83d\""
-- CHECK: lone low: "\"\\udc00\""
-- CHECK: lone key: "{\"\\ud83d\":1}"
-- CHECK: pair intact: "4"

import ConformanceHelp exposing (logAll, worker)
import Json.Encode as E


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


report : ()
report =
    logAll
        [ ( "lone high", E.encode 0 (E.string (String.left 1 emoji)) )
        , ( "lone low", E.encode 0 (E.string (String.fromChar (Char.fromCode 0xDC00))) )
        , ( "lone key", E.encode 0 (E.object [ ( String.left 1 emoji, E.int 1 ) ]) )
        , ( "pair intact", String.fromInt (String.length (E.encode 0 (E.string emoji))) )
        ]


main : Program () () ()
main =
    worker report
