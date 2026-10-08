module SocketSmokeTest exposing (main)

{-| Smoke test of the socket modules (plans/eco-system-sockets.md §4 S0 step 5): every public
`Socket.*` module compiles and links on both backends, `Socket.Address` parses and prints (pure
Elm), and the kernels are reachable through both paths of `connectToHost` (address literal:
`connect`, refused on the harness's free `ECO_TEST_PORT`; name: `lookup`, where `""` fails with
`ENOTFOUND` without asking the resolver).
-}

-- CHECK: ipv6: 2001:db8::1:0:0:1%eth0
-- CHECK: mapped: ::ffff:127.0.0.1 -> 127.0.0.1 loopback True
-- CHECK: defaults: backlog 511 keepAlive Nothing reuse False alpn 0
-- CHECK: lookup: ENOTFOUND
-- CHECK: connectToHost literal: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:{{[0-9]+}}
-- CHECK: connectToHost name: ENOTFOUND
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Socket.Tls
import Socket.Udp
import Socket.Unix
import Dict
import Stream.Log
import System
import System.File.Path as Path
import Task exposing (Task)


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


addressLines : List String
addressLines =
    let
        show text =
            Address.fromString text
                |> Maybe.map Address.toString
                |> Maybe.withDefault ("invalid " ++ text)

        mapped =
            Address.fromString "::FFFF:127.0.0.1"
                |> Maybe.withDefault (Address.any IPv6)
    in
    [ "ipv6: " ++ show "2001:DB8:0:0:1:0:0:1%eth0"
    , "mapped: "
        ++ Address.toString mapped
        ++ " -> "
        ++ Address.toString (Address.unmapIPv4 mapped)
        ++ " loopback "
        ++ boolString (Address.isLoopback mapped)
    ]


defaultsLine : String
defaultsLine =
    let
        listen =
            Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 0

        connect =
            Socket.Tcp.defaultConnectOptions (Address.loopback IPv6) 1

        bind =
            Socket.Udp.defaultBindOptions (Address.any IPv4) 0

        tls =
            Socket.Tls.defaultClientOptions "localhost"

        unix =
            Socket.Unix.defaultListenOptions (Path.fromPosixString "/tmp/eco.sock")

        keepAlive =
            case connect.keepAlive of
                Just _ ->
                    "Just"

                Nothing ->
                    "Nothing"
    in
    "defaults: backlog "
        ++ String.fromInt listen.backlog
        ++ " keepAlive "
        ++ keepAlive
        ++ " reuse "
        ++ boolString (bind.reuseAddress || unix.removeExisting)
        ++ " alpn "
        ++ String.fromInt (List.length tls.alpn)


testPort : Task x Int
testPort =
    System.getEnvironmentVariables
        |> Task.map (Dict.get "ECO_TEST_PORT" >> Maybe.andThen String.toInt >> Maybe.withDefault 9)


outcome : String -> Task Socket.Error a -> Task Never String
outcome label task =
    task
        |> Task.map (\_ -> label ++ ": ok")
        |> Task.onError (\e -> Task.succeed (label ++ ": " ++ Socket.errorCode e))


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (testPort
                    |> Task.andThen
                        (\freePort ->
                            Task.map3 (\a b c -> [ a, b, c ])
                                (outcome "lookup" (Socket.lookup ""))
                                (Socket.Tcp.connectToHost "127.0.0.1" freePort
                                    |> Task.map (\_ -> "connectToHost literal: ok")
                                    |> Task.onError (\e -> Task.succeed ("connectToHost literal: " ++ Socket.errorToString e))
                                )
                                (outcome "connectToHost name" (Socket.Tcp.connectToHost "" freePort))
                        )
                    |> Task.andThen
                        (\lines ->
                            Stream.Log.line env.stdout
                                (String.join "\n" (addressLines ++ defaultsLine :: lines))
                        )
                )
        )
