module SocketTlsTrustedCorruptBlockTest exposing (main)

{-| TLS-NEW-2 (follow-up of TLS-05, plans/kernel-lib-bug-fixes.md): `TrustedCertificates` with PEM
text in which a corrupt certificate block comes before a good one. Reading stops at the first
block that cannot be read, on both backends, as Node's own `ca` option and OpenSSL's PEM loop
(`PEM_read_bio_X509`) stop there, and as Socket/Tls.elm documents: the certificates after it are
not trusted. Text before the first block that is not PEM is skipped. The JS backend's
`_Tls_pemCertificates` used to skip the corrupt block and trust the ones after it, so
"corrupt then ca" and "leaf, corrupt, ca" connected there. With only the leaf trusted, OpenSSL
natively reports `IssuerNotTrusted` (X509 error 20) and Node `LeafNotVerifiable` (21); either is
the rejection this test is about.

-}

-- CHECK: ca: ok alpn none
-- CHECK: ca then corrupt: ok alpn none
-- CHECK: text then ca: ok alpn none
-- CHECK: leaf then ca: ok alpn none
-- CHECK: corrupt then ca: err TlsError (CertificateUnusable NO_CERTIFICATES)
-- CHECK: leaf, corrupt, ca: err TlsError (CertificateRejected {{IssuerNotTrusted|LeafNotVerifiable}})
-- EXIT: 0

import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)
import TlsFixtures as Fx


trustedPem : String -> Socket.Tls.ClientOptions
trustedPem pem =
    { serverName = "localhost", verification = Socket.Tls.TrustedCertificates pem, alpn = [] }


{-| A certificate block whose body is not a certificate.
-}
corrupt : String
corrupt =
    "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"


cases : List ( String, Task String String )
cases =
    [ ( "ca", T.tryCase (T.server []) (trustedPem Fx.caPem) )
    , ( "ca then corrupt", T.tryCase (T.server []) (trustedPem (Fx.caPem ++ "\n" ++ corrupt)) )
    , ( "text then ca", T.tryCase (T.server []) (trustedPem ("not a certificate\n" ++ Fx.caPem)) )
    , ( "leaf then ca", T.tryCase (T.server []) (trustedPem (Fx.serverCertPem ++ "\n" ++ Fx.caPem)) )
    , ( "corrupt then ca", T.tryCase (T.server []) (trustedPem (corrupt ++ Fx.caPem)) )
    , ( "leaf, corrupt, ca", T.tryCase (T.server []) (trustedPem (Fx.serverCertPem ++ "\n" ++ corrupt ++ Fx.caPem)) )
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
