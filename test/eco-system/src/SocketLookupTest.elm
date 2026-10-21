module SocketLookupTest exposing (main)

{-| `Socket.lookup` (plans/eco-system-sockets.md §3.3.6): `localhost` resolves to a list that
contains a loopback address; an address literal resolves to itself; `""` fails with `HostNotFound`
(`ENOTFOUND`, without asking the resolver).
-}

-- CHECK: localhost has loopback: True
-- CHECK: literal: 127.0.0.1
-- CHECK: empty: HostNotFound
-- EXIT: 0

import ErrorNames
import Socket
import Socket.Address as Address
import SocketTestHelp as H
import System
import Task


main : Platform.Program System.Environment () ()
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
                                                Task.succeed (ErrorNames.socketError e)
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
