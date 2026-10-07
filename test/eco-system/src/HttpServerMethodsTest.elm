module HttpServerMethodsTest exposing (main)

{-| Request methods (plans/eco-system-library.md Phase 7 step 7.4, E.5): the
known ones map to their constructors, any other to `UNKNOWN name`, which
`requestInfo` shows as `UNKNOWN(name)`. A request without a body has an
empty one.
-}

-- CHECK: server: PUT /a body=data
-- CHECK: server: DELETE /b body=
-- CHECK: server: PATCH /c body=patch
-- CHECK: server: OPTIONS /d body= info=UNKNOWN(OPTIONS) http://127.0.0.1:
-- CHECK: server: GET /e body=
-- CHECK: client: 200 - PUT
-- CHECK: client: 200 - DELETE
-- CHECK: client: 200 - PATCH
-- CHECK: client: 200 - OPTIONS
-- CHECK: client: 200 - GET
-- EXIT: 0

import Http
import Http.Server as Server
import Http.Server.Response as Response
import HttpServerTestHelp as Help
import System
import Task


handler : Help.Handler
handler request response =
    let
        info =
            case request.method of
                Server.UNKNOWN _ ->
                    " info=" ++ Server.requestInfo request

                _ ->
                    ""
    in
    ( [ Server.methodToString request.method
            ++ " "
            ++ request.url.path
            ++ " body="
            ++ (Server.bodyAsString request |> Maybe.withDefault "<invalid>")
            ++ info
      ]
    , response |> Response.setBody (Server.methodToString request.method)
    )


call : String -> String -> Http.Body -> Task.Task Never String
call method url body =
    Help.send { method = method, headers = [], url = url, body = body, header = "x-none" }


client : String -> Task.Task Never (List String)
client base =
    [ call "PUT" (base ++ "/a") (Http.stringBody "text/plain" "data")
    , call "DELETE" (base ++ "/b") Http.emptyBody
    , call "PATCH" (base ++ "/c") (Http.stringBody "text/plain" "patch")
    , call "OPTIONS" (base ++ "/d") Http.emptyBody
    , call "GET" (base ++ "/e") Http.emptyBody
    ]
        |> Task.sequence


main : System.Program Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
