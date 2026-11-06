module UrlPercentDecodePlusTest exposing (main)

{-| `Url.percentDecode` leaves a `+` as a `+`, so a query value `c++` reads back as `c++`.

The tests decode "a+b", decode "c%2B%2B", and parse the query parameter `q` of
`"http://x/?q=c++"` with `Url.Parser.Query.string`.

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
