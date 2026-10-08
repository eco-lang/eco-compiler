module SocketLookupTest exposing (main)

{-| `Socket.lookup` (plans/eco-system-sockets.md §3.3.6): `localhost` resolves to a list that
contains a loopback address; an address literal resolves to itself; `""` fails with `ENOTFOUND`
(without asking the resolver).
-}

-- CHECK: localhost has loopback: True
-- CHECK: literal: 127.0.0.1
-- CHECK: empty: ENOTFOUND host not found True
-- EXIT: 0

import Socket
import Socket.Address as Address
import SocketTestHelp as H
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr (Socket.lookup "localhost")
                |> Task.andThen
                    (\local ->
                        H.socketErr (Socket.lookup "127.0.0.1")
                            |> Task.andThen
                                (\literal ->
                                    Socket.lookup ""
                                        |> Task.map (\_ -> "resolved?!")
                                        |> Task.onError
                                            (\e ->
                                                Task.succeed
                                                    (Socket.errorCode e ++ " host not found " ++ H.boolString (Socket.errorIsHostNotFound e))
                                            )
                                        |> Task.map
                                            (\empty ->
                                                [ "localhost has loopback: " ++ H.boolString (List.any Address.isLoopback local)
                                                , "literal: " ++ String.join "," (List.map Address.toString literal)
                                                , "empty: " ++ empty
                                                ]
                                            )
                                )
                    )
        )
