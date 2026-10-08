module SocketTlsAlpnTest exposing (main)

{-| TLS application protocol negotiation (plans/eco-system-sockets.md §3.6, §4 S5): the server
picks the first of its protocols that the client offers; when they share none the server sends a
fatal `no_application_protocol` alert and the client fails with
`ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL` (Node's code); a client offering nothing, or a server
supporting nothing, negotiates no protocol.
-}

-- CHECK: server preference: ok alpn http/1.1
-- CHECK: no overlap: err {{ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL}} certificate-invalid False
-- CHECK: client offers none: ok alpn none
-- CHECK: server supports none: ok alpn none
-- EXIT: 0

import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


cases : List ( String, Task String String )
cases =
    [ ( "server preference", T.tryCase (T.server [ "http/1.1", "h2" ]) (T.trusted "localhost" [ "h2", "http/1.1" ]) )
    , ( "no overlap", T.tryCase (T.server [ "http/1.1" ]) (T.trusted "localhost" [ "h2" ]) )
    , ( "client offers none", T.tryCase (T.server [ "http/1.1" ]) (T.trusted "localhost" []) )
    , ( "server supports none", T.tryCase (T.server []) (T.trusted "localhost" [ "h2" ]) )
    ]


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            List.foldl
                (\( name, run ) acc ->
                    acc |> Task.andThen (\lines -> run |> Task.map (\line -> lines ++ [ name ++ ": " ++ line ]))
                )
                (Task.succeed [])
                cases
        )
