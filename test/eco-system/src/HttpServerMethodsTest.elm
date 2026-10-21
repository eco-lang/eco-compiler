module HttpServerMethodsTest exposing (main)

{-| Request methods (plans/eco-system-library.md Phase 7 step 7.4, E.5;
plans/eco-system-typed-api.md A1): the known ones map to their `Http.Method`
constructors, `OPTIONS` included (it was `UNKNOWN "OPTIONS"` before it had a
constructor of its own), and any other to `UNKNOWN name`, which `requestToString`
shows as `UNKNOWN(name)`. A request without a body has an empty one.
-}

-- CHECK: server: PUT /a body=data
-- CHECK: server: DELETE /b body=
-- CHECK: server: PATCH /c body=patch
-- CHECK: server: OPTIONS /d body= constructor=OPTIONS
-- CHECK: server: GET /e body=
-- CHECK: client: 200 - PUT
-- CHECK: client: 200 - DELETE
-- CHECK: client: 200 - PATCH
-- CHECK: client: 200 - OPTIONS
-- CHECK: client: 200 - GET
-- EXIT: 0

import Http
import Http.Method
import Http.Server as Server
import HttpServerTestHelp as Help
import System
import Task


handler : Help.Handler
handler request response =
    let
        info =
            case request.method of
                Http.Method.UNKNOWN _ ->
                    " info=" ++ Server.requestToString request

                Http.Method.OPTIONS ->
                    " constructor=OPTIONS"

                _ ->
                    ""
    in
    ( [ Http.Method.toString request.method
            ++ " "
            ++ request.url.path
            ++ " body="
            ++ (Server.bodyAsString request |> Maybe.withDefault "<invalid>")
            ++ info
      ]
    , response |> Server.setBody (Http.Method.toString request.method)
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


main : Platform.Program System.Environment Help.Model Help.Msg
main =
    Help.program { handler = handler, client = client }
