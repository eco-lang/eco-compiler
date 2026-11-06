module UrlPercentDecodeInvalidUtf8Test exposing (main)

{-| `Url.percentDecode` returns `Nothing` when the decoded bytes are not valid UTF-8, and decodes a
valid sequence.

The invalid inputs are a bad lead byte (`%FF`), a truncated sequence (`%E2%82`), an encoded
surrogate (`%ED%A0%80`) and an overlong form (`%C0%AF`); the valid one is the euro sign. A `Just`
is shown as the code points of its string (`ConformanceHelp.cps`).

-}

-- CHECK: bad lead FF: "Nothing"
-- CHECK: truncated E282: "Nothing"
-- CHECK: surrogate EDA080: "Nothing"
-- CHECK: overlong C0AF: "Nothing"
-- CHECK: valid euro: "Just [20AC]"

import ConformanceHelp exposing (cps, logAll, worker)
import Url


{-| Percent-decodes `s` and shows the result in ASCII.
-}
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
