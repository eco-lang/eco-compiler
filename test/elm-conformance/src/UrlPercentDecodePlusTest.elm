module UrlPercentDecodePlusTest exposing (main)

{-| URL-02 (plans/kernel-lib-bug-fixes.md): `Url.percentDecode` keeps a `+`, like JS
`decodeURIComponent`, so a query value `c++` reads back as `c++`.

Natively this is `Elm_Kernel_Url_percentDecode` (elm-kernel-cpp/src/url/UrlExports.cpp), which
once turned `+` into a space. Expectations recorded from Elm on node (run-js-e2e.js --record).
-}

-- CHECK: decode plus: "Just \"a+b\""
-- CHECK: decode encoded plus: "Just \"c++\""
-- CHECK: query plus: "Just (Just \"c++\")"

import ConformanceHelp exposing (logAll, worker)
import Url
import Url.Parser
import Url.Parser.Query


show : a -> String
show =
    Debug.toString


queryQ : Maybe (Maybe String)
queryQ =
    Url.fromString "http://x/?q=c++"
        |> Maybe.andThen
            (Url.Parser.parse (Url.Parser.query (Url.Parser.Query.string "q")))


report : ()
report =
    logAll
        [ ( "decode plus", show (Url.percentDecode "a+b") )
        , ( "decode encoded plus", show (Url.percentDecode "c%2B%2B") )
        , ( "query plus", show queryQ )
        ]


main : Program () () ()
main =
    worker report
