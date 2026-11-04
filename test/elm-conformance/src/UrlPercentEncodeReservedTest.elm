module UrlPercentEncodeReservedTest exposing (main)

{-| URL-01 (plans/kernel-lib-bug-fixes.md): `Url.percentEncode` keeps `!*'()` as they are, like
JS `encodeURIComponent`, and so does `Url.Builder`.

Natively this is `shouldEncode` (elm-kernel-cpp/src/url/UrlExports.cpp), which once left only
`A-Za-z0-9-_.~` unescaped. Expectations recorded from Elm on node (run-js-e2e.js --record).
-}

-- CHECK: encode reserved: "a(b)!*'~"
-- CHECK: builder: "/x(y)?k=v!"
-- CHECK: encode space: "a%20b%26c"

import ConformanceHelp exposing (logAll, worker)
import Url
import Url.Builder


report : ()
report =
    logAll
        [ ( "encode reserved", Url.percentEncode "a(b)!*'~" )
        , ( "builder", Url.Builder.absolute [ "x(y)" ] [ Url.Builder.string "k" "v!" ] )
        , ( "encode space", Url.percentEncode "a b&c" )
        ]


main : Program () () ()
main =
    worker report
