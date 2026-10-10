module TestServerConfig exposing (Server, server)

{-| Where the test runner's HTTP test server listens (test/TestHttpServer.hpp).

The runner starts the server on ephemeral ports and passes its URLs to every
test program through the environment (`ECO_TEST_HTTP_URL`,
`ECO_TEST_HTTPS_URL`, test/TestServerConfig.hpp), so this module is ordinary
checked-in source: nothing is generated or recompiled per run.

-}

import Eco.Env
import Task exposing (Task)


type alias Server =
    { baseUrl : String
    , httpsBaseUrl : String
    }


{-| An unset variable gives a URL nothing listens on, so the test fails
visibly instead of reaching some other server.
-}
lookup : String -> Task x String
lookup name =
    Eco.Env.lookup name
        |> Task.mapError never
        |> Task.map (Maybe.withDefault ("http://127.0.0.1:9/" ++ name ++ "-unset"))


server : Task x Server
server =
    Task.map2 Server (lookup "ECO_TEST_HTTP_URL") (lookup "ECO_TEST_HTTPS_URL")
