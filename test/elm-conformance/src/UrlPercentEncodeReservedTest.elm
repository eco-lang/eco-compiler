module UrlPercentEncodeReservedTest exposing (main)

{-| `Url.percentEncode` leaves the characters `!*'()` and `~` unescaped and escapes a space and
`&`; `Url.Builder` leaves `(`, `)` and `!` unescaped in a path segment and a query value.
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
