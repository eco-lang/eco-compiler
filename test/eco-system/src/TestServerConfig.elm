module TestServerConfig exposing (Server, server)

{-| Where the test runner's HTTP test server listens (test/TestHttpServer.hpp,
or the JS runner's own server).

The runner starts the server on ephemeral ports and passes its URLs to every
test program through the environment (`ECO_TEST_HTTP_URL`,
`ECO_TEST_HTTPS_URL`, test/TestServerConfig.hpp), so this module is ordinary
checked-in source: nothing is generated or recompiled per run.

-}

import Dict
import System
import Task exposing (Task)


type alias Server =
    { baseUrl : String
    , httpsBaseUrl : String
    }


{-| An unset variable gives a URL nothing listens on, so the test fails
visibly instead of reaching some other server.
-}
server : Task x Server
server =
    System.getEnvironmentVariables
        |> Task.map
            (\vars ->
                let
                    get name =
                        Dict.get name vars |> Maybe.withDefault ("http://127.0.0.1:9/" ++ name ++ "-unset")
                in
                Server (get "ECO_TEST_HTTP_URL") (get "ECO_TEST_HTTPS_URL")
            )
