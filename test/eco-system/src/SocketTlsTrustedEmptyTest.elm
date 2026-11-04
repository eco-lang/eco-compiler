module SocketTlsTrustedEmptyTest exposing (main)

{-| TLS-05 (plans/kernel-lib-bug-fixes.md, group 10): `TrustedCertificates` with PEM text that holds
no usable certificate (empty, not PEM, or a corrupt certificate block) fails with the code
ERR_SSL_NO_CERTIFICATES, as the docs (Socket/Tls.elm) and the JS backend (Eco/Kernel/Tls.js) say,
and `Socket.Tls` sorts it as `CertificateUnusable "NO_CERTIFICATES"` (decision D20). Native used to
report the PEM parser's code (`NO_START_LINE`), and the Elm classifier took any code containing
"_CERT" for a verification code (`CertificateRejected VerificationFailed`).

-}

-- CHECK: empty: err TlsError (CertificateUnusable NO_CERTIFICATES)
-- CHECK: garbage: err TlsError (CertificateUnusable NO_CERTIFICATES)
-- CHECK: corrupt: err TlsError (CertificateUnusable NO_CERTIFICATES)
-- EXIT: 0

import Socket.Tls
import SocketTestHelp as H
import SocketTlsHelp as T
import System
import Task exposing (Task)


trustedPem : String -> Socket.Tls.ClientOptions
trustedPem pem =
    { serverName = "localhost", verification = Socket.Tls.TrustedCertificates pem, alpn = [] }


cases : List ( String, Task String String )
cases =
    [ ( "empty", T.tryCase (T.server []) (trustedPem "") )
    , ( "garbage", T.tryCase (T.server []) (trustedPem "not a certificate") )
    , ( "corrupt", T.tryCase (T.server []) (trustedPem "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n") )
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
