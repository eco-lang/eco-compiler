module SocketTlsAlpnEmptyTest exposing (main)

{-| HEAP-01 (plans/kernel-lib-bug-fixes.md, group 10): a TLS client offering an empty ALPN name.

The literal `""` is the embedded empty-String constant (HEAP_014). `listToStringVector`
(eco-kernel-cpp/src/eco-kernel/KernelHelpers.hpp), which `tlsConnectBody` uses for the ALPN list,
passes each element to `Allocator::resolve`, which must never see an embedded constant: an
assertion abort (asserts on) or a wild read. Fixed, the name reaches `buildTlsClientConfig`,
which rejects an empty name with EINVAL (`SocketError InvalidInput`), as the JS backend
(Eco/Kernel/Tls.js) does.

-}

-- CHECK: empty alpn name: err SocketError InvalidInput
-- EXIT: 0

import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


cases : List ( String, Task String String )
cases =
    [ ( "empty alpn name", T.tryCase (T.server []) (T.trusted "localhost" [ "" ]) )
    ]


main : Platform.Program System.Environment () ()
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
