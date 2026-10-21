module SocketTlsVerifyTest exposing (main)

{-| TLS certificate verification (plans/eco-system-sockets.md §4 S5, §D.5). Each case is one
handshake against a fresh listener:

  - an expired certificate (signed by the trusted CA) → `Expired` (`CERT_HAS_EXPIRED`);
  - a self-signed certificate → `SelfSigned` (`DEPTH_ZERO_SELF_SIGNED_CERT`);
  - a valid certificate for the wrong name (`example.com`) → `NameMismatch`
    (`ERR_TLS_CERT_ALTNAME_INVALID`);
  - the server name `127.0.0.1` matches the certificate's IP address (no SNI);
  - `NoVerification` accepts the self-signed certificate;
  - the system certificate store does not know the test CA.

Every rejection is `TlsError (CertificateRejected _)`.

-}

-- CHECK: expired: err TlsError (CertificateRejected Expired)
-- CHECK: self-signed: err TlsError (CertificateRejected SelfSigned)
-- CHECK: wrong name: err TlsError (CertificateRejected NameMismatch)
-- CHECK: ip literal: ok alpn none
-- CHECK: no verification: ok alpn none
-- CHECK: system store: err TlsError (CertificateRejected {{(IssuerNotTrusted|LeafNotVerifiable)}})
-- EXIT: 0

import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)
import TlsFixtures as Fx


cases : List ( String, Task String String )
cases =
    [ ( "expired"
      , T.tryCase { certificateChain = Fx.expiredCertPem, privateKey = Fx.expiredKeyPem, alpn = [] } (T.trusted "localhost" [])
      )
    , ( "self-signed"
      , T.tryCase { certificateChain = Fx.selfSignedCertPem, privateKey = Fx.selfSignedKeyPem, alpn = [] } (T.trusted "localhost" [])
      )
    , ( "wrong name", T.tryCase (T.server []) (T.trusted "example.com" []) )
    , ( "ip literal", T.tryCase (T.server []) (T.trusted "127.0.0.1" []) )
    , ( "no verification"
      , T.tryCase { certificateChain = Fx.selfSignedCertPem, privateKey = Fx.selfSignedKeyPem, alpn = [] }
            { serverName = "localhost", verification = Socket.Tls.NoVerification, alpn = [] }
      )
    , ( "system store", T.tryCase (T.server []) (Socket.Tls.defaultClientOptions "localhost") )
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
