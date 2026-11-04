module UrlPercentDecodeInvalidUtf8Test exposing (main)

{-| URL-03 (plans/kernel-lib-bug-fixes.md): `Url.percentDecode` gives `Nothing` when the decoded
bytes are not UTF-8 (a bad lead byte, a truncated sequence, an encoded surrogate, an overlong
form), as JS `decodeURIComponent` throws a URIError; a valid sequence still decodes. A `Just` is
shown as the code points of its String (ConformanceHelp.cps) to keep the output ASCII.

Natively this is `Elm_Kernel_Url_percentDecode` (elm-kernel-cpp/src/url/UrlExports.cpp), which
once built the result with the lenient `allocStringFromUTF8` and never returned `Nothing` for bad
UTF-8. Expectations recorded from Elm on node (run-js-e2e.js --record).
-}

-- CHECK: bad lead FF: "Nothing"
-- CHECK: truncated E282: "Nothing"
-- CHECK: surrogate EDA080: "Nothing"
-- CHECK: overlong C0AF: "Nothing"
-- CHECK: valid euro: "Just [20AC]"

import ConformanceHelp exposing (cps, logAll, worker)
import Url


decoded : String -> String
decoded s =
    case Url.percentDecode s of
        Just v ->
            "Just [" ++ cps v ++ "]"

        Nothing ->
            "Nothing"


report : ()
report =
    logAll
        [ ( "bad lead FF", decoded "%FF" )
        , ( "truncated E282", decoded "%E2%82" )
        , ( "surrogate EDA080", decoded "%ED%A0%80" )
        , ( "overlong C0AF", decoded "%C0%AF" )
        , ( "valid euro", decoded "%E2%82%AC" )
        ]


main : Program () () ()
main =
    worker report
