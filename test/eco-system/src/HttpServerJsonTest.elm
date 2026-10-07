module HttpServerJsonTest exposing (main)

{-| `Http.Server.bodyFromJson` and byte bodies (plans/eco-system-library.md
Phase 7 step 7.4). The client posts JSON with elm/http; the server decodes it
with `bodyFromJson` (a body that does not decode gives an `Err`) and answers
with `setBodyAsBytes` and its own Content-Type.
-}

-- CHECK: server: json eco 42
-- CHECK: server: json error True
-- CHECK: client: 200 application/octet-stream n=42
-- CHECK: client: 200 application/octet-stream bad
-- EXIT: 0

import Bytes.Encode
import Http
import Http.Server as Server
import Http.Server.Response as Response
import HttpServerTestHelp as Help
import Json.Decode as D
import Json.Encode as E
import System
import Task


decoder : D.Decoder ( String, Int )
decoder =
    D.map2 Tuple.pair (D.field "name" D.string) (D.field "n" D.int)


handler : Help.Handler
handler request response =
    let
        ( line, reply ) =
            case Server.bodyFromJson decoder request of
                Ok ( name, n ) ->
                    ( "json " ++ name ++ " " ++ String.fromInt n, "n=" ++ String.fromInt n )

                Err _ ->
                    ( "json error True", "bad" )
    in
    ( [ line ]
    , response
        |> Response.setHeader "Content-Type" "application/octet-stream"
        |> Response.setBodyAsBytes (Bytes.Encode.encode (Bytes.Encode.string reply))
    )


post : String -> Http.Body -> Task.Task Never String
post url body =
    Help.send { method = "POST", headers = [], url = url, body = body, header = "content-type" }


client : String -> Task.Task Never (List String)
client base =
    post (base ++ "/json") (Http.jsonBody (E.object [ ( "name", E.string "eco" ), ( "n", E.int 42 ) ]))
        |> Task.andThen
            (\first ->
                post (base ++ "/json") (Http.stringBody "application/json" "{ not json")
                    |> Task.map (\second -> [ first, second ])
            )


main : System.Program Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
