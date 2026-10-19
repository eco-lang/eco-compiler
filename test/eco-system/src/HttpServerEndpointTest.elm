module HttpServerEndpointTest exposing (main)

{-| `Http.Server.endpoint` (plans/eco-system-api-refactor.md D8): the address
and port a server is bound to, for `listenOnHost` (a host name resolved by the
kernel) and for `listen` (an `Address`); port 0 gets a port picked by the
system.
-}

-- CHECK: listenOnHost: 127.0.0.1 picked True
-- CHECK: listen: 127.0.0.1 picked True
-- CHECK: distinct ports: True
-- EXIT: 0

import Http.Server as Server
import Socket.Address as Address exposing (Family(..))
import Stream
import System
import Task exposing (Task)


describe : String -> Server.Server -> String
describe label server =
    let
        endpoint =
            Server.endpoint server
    in
    label ++ ": " ++ Address.toString endpoint.address ++ " picked " ++ boolString (endpoint.port_ > 0)


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Task.map2 Tuple.pair
                (Server.listenOnHost "127.0.0.1" 0)
                (Server.listen (Server.defaultListenOptions (Address.loopback IPv4) 0))
                |> Task.andThen
                    (\( a, b ) ->
                        Task.map2 (\_ _ -> ())
                            (Server.close a)
                            (Server.close b)
                            |> Task.map
                                (\_ ->
                                    String.join "\n"
                                        [ describe "listenOnHost" a
                                        , describe "listen" b
                                        , "distinct ports: " ++ boolString ((Server.endpoint a).port_ /= (Server.endpoint b).port_)
                                        ]
                                )
                    )
                |> Task.onError (\err -> Task.succeed ("error: " ++ Server.errorToString err))
                |> Task.andThen (\text -> Stream.logLine text env.stdout)
        )
