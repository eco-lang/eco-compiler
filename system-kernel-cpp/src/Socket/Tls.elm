module Socket.Tls exposing
    ( ClientOptions, Verification(..), defaultClientOptions, connect
    , ServerOptions, listen
    , Info, TlsVersion(..), info
    , Error(..), Problem(..), CertificateProblem(..), errorToString, fromStreamFailure
    )

{-| TLS (Transport Layer Security) encrypts a TCP connection and lets a client check that it is
talking to the server it meant, and this module makes TLS connections and listeners. Once made,
a TLS connection is an ordinary [`Socket.Connection`](Socket#Connection) whose streams carry the
plaintext. The encryption happens underneath, and the program uses the connection through
[`Socket`](Socket) and its streams as it would any other.

A TLS connection starts with a _handshake_, in which the two ends agree on a TLS version and a
cipher, and the client, unless told not to, verifies the server's certificate. _Verification_
checks that the certificate was signed by an authority the client trusts and that it names the
server the client meant. [`Verification`](#Verification) says which authorities are trusted, and the
`serverName` of [`ClientOptions`](#ClientOptions) says which name the certificate must hold.

Two further things travel in the handshake. _SNI_ (Server Name Indication) is the client telling
the server the host name it wants, so that a server with several certificates can choose one.
_ALPN_ (Application-Layer Protocol Negotiation) is the client offering a list of application
protocols, such as `"h2"` and `"http/1.1"`, from which the server chooses one.

[`connect`](#connect) takes an address, not a host name, so resolving the name is the caller's
job, for example with [`Socket.lookup`](Socket#lookup). The server name is used only for TLS,
never to find the server. For example:

    Socket.lookup "example.com"
        |> Task.andThen
            (\addresses ->
                case addresses of
                    address :: _ ->
                        Socket.Tls.connect
                            (Socket.Tls.defaultClientOptions "example.com")
                            (Socket.Tcp.defaultConnectOptions address 443)

                    [] ->
                        Task.fail ...
            )

A server [`listen`](#listen)s and gets its connections from [`Socket.accept`](Socket#accept) or
[`Socket.onConnection`](Socket#onConnection), by the rule the `Socket` module describes. A
connection reaches that rule only once its handshake has succeeded, so a client whose handshake
is slow can be overtaken by clients that connected after it.

TLS is a protocol layered on a TCP connection, so this module has its own
[`Error`](#Error), which says in which layer a failure happened. A failure of the TCP connection
underneath is a `SocketError` holding a [`Socket.Error`](Socket#Error), as `Socket.Tcp` would
report it; a failure of TLS itself is a `TlsError` holding a [`Problem`](#Problem). A certificate
that fails verification makes `connect` fail with
`TlsError (CertificateRejected problem)`, where the
[`CertificateProblem`](#CertificateProblem) says what was wrong with it. A server that closes the
connection during the handshake is a failure of the connection, not of TLS: a `SocketError`
whose kind is [`Socket.ConnectionReset`](Socket#ErrorKind).

Once a connection has been made, failures to read or write arrive on its streams, as for any
connection, and [`fromStreamFailure`](#fromStreamFailure) reads them back as an `Error`.


## Clients

@docs ClientOptions, Verification, defaultClientOptions, connect


## Servers

@docs ServerOptions, listen


## Connection information

@docs Info, TlsVersion, info


## Errors

@docs Error, Problem, CertificateProblem, errorToString, fromStreamFailure

-}

import Eco.Kernel.Tls
import Socket
import Socket.Internal as Internal
import Socket.Tcp
import Stream
import Stream.Internal
import Task exposing (Task)



-- CLIENTS


{-| How a client secures a connection: the name the server's certificate must hold, the
authorities it trusts, and the application protocols it offers.

`serverName` is used only for TLS, never to find the server. A DNS name is sent as SNI and must
match the certificate. An IP address literal, such as `"192.0.2.1"`, is not sent and must match
one of the certificate's IP addresses. On the native backend an IPv6 literal with a zone, such as
`"fe80::1%eth0"`, counts as a DNS name. The empty string sends no name, and the certificate is
then checked against the trusted authorities but not against any name. With `NoVerification`
nothing is checked, though a DNS name is still sent.

`alpn` is the list of protocols to offer, such as `[ "h2", "http/1.1" ]`, and `[]` offers none.
The server chooses which one is used, and [`info`](#info) reports it. Each name must be 1 to 255
bytes of UTF-8, or `connect` fails with a `SocketError` whose kind is
[`Socket.InvalidInput`](Socket#ErrorKind).

-}
type alias ClientOptions =
    { serverName : String
    , verification : Verification
    , alpn : List String
    }


{-| Which authorities a client trusts to vouch for a server's certificate.

`SystemCertificates` trusts the operating system's certificate authorities. On the native
backend a non-empty `SSL_CERT_FILE` environment variable replaces them with the certificates in
the file it names, and a non-empty `SSL_CERT_DIR` replaces them with a directory of certificates
under OpenSSL's hashed file names (as `openssl rehash` makes them), together with the file when
both are set. On the JavaScript backend a non-empty `SSL_CERT_FILE` likewise replaces them with
the certificates in the file it names, and a non-empty `SSL_CERT_DIR` set as well adds back the
authorities Node reports as the system's. The variables and the system's authorities are read
when a connection first needs them, not for every connection.

`TrustedCertificates pem` trusts only the PEM-encoded certificates in `pem`, which may hold one
or more; the system's authorities are not consulted. On the native backend, reading stops at the
first certificate block that cannot be read, and the certificates after it are not trusted. When
no certificate can be read from `pem`, `connect` fails with
`TlsError (CertificateUnusable reason)` before it contacts the server.

`NoVerification` accepts any certificate and checks no name. The connection is encrypted, but
the server is not authenticated, so anyone able to intercept the connection can pose as it. It
is meant for testing.

-}
type Verification
    = SystemCertificates
    | TrustedCertificates String
    | NoVerification


{-| Returns options for a server named `serverName`, trusting the system's certificate
authorities (`SystemCertificates`) and offering no application protocols.
-}
defaultClientOptions : String -> ClientOptions
defaultClientOptions serverName =
    { serverName = serverName
    , verification = SystemCertificates
    , alpn = []
    }


{-| Opens a TCP connection and secures it with TLS, succeeding once the handshake has finished
and, unless verification is off, the server's certificate has been accepted.

The TCP side is made from the same options as by `Socket.Tcp.connect`, and fails in the same
ways, as a `SocketError`. Its `timeout` covers the handshake too: the task fails with a
`SocketError` whose kind is [`Socket.TimedOut`](Socket#ErrorKind) when connecting and the
handshake together take longer. The `alpn` names, and the certificates of `TrustedCertificates`,
are checked before anything connects, so a problem with them fails the task without contacting
the server.

A failure of TLS itself is a `TlsError`: `CertificateRejected` when the server's certificate is
rejected, and `HandshakeFailed` when the handshake fails for another reason, for example when the
two ends share no TLS version or cipher. A server that closes the connection during the handshake
is a `SocketError` with the kind [`Socket.ConnectionReset`](Socket#ErrorKind).

-}
connect : ClientOptions -> Socket.Tcp.ConnectOptions -> Task Error Socket.Connection
connect client tcp =
    let
        ( target, settings ) =
            Internal.tcpConnectArgs tcp

        verification =
            case client.verification of
                SystemCertificates ->
                    ( 0, "" )

                TrustedCertificates pem ->
                    ( 1, pem )

                NoVerification ->
                    ( 2, "" )
    in
    kConnect target settings ( client.serverName, verification, client.alpn )
        |> Task.map Internal.toConnection
        |> Task.mapError (Internal.toError >> classify False)



-- SERVERS


{-| What a TLS listener presents to its clients: its certificate and private key, and the
application protocols it supports.

`certificateChain` is PEM text holding the server's own certificate first, followed by any
intermediate certificates that link it to an authority. `privateKey` is the PEM-encoded key that
belongs to that certificate.

`alpn` is the list of protocols the server supports, in its order of preference. Of the
protocols a client offers, the server chooses the first in its own list, and when the client
offers none of them the handshake fails. A client that offers no protocols is served without
one, and `[]` ignores what clients offer. `Http.Server` does not use this field; it chooses its
protocols itself.

-}
type alias ServerOptions =
    { certificateChain : String
    , privateKey : String
    , alpn : List String
    }


{-| Starts listening for TLS connections, succeeding with the listener once it is bound and
listening. The TCP side is set up from the same options as by `Socket.Tcp.listen`, and fails in
the same ways, as a `SocketError`.

The certificate, the key, and whether the two belong together are checked before anything
listens. When they cannot be used, the task fails with `TlsError (CertificateUnusable reason)`.
An `alpn` name that is empty or longer than 255 bytes fails it with a `SocketError` whose kind
is [`Socket.InvalidInput`](Socket#ErrorKind).

A client whose handshake fails, or has not finished after 120 seconds, is closed without being
handed to the program. On the native backend at most 64 handshakes are under way at once on one
listener; further clients wait in the operating system's listen queue.

-}
listen : ServerOptions -> Socket.Tcp.ListenOptions -> Task Error Socket.Listener
listen server tcp =
    let
        ( target, settings ) =
            Internal.tcpListenArgs tcp
    in
    kListen target settings ( server.certificateChain, server.privateKey, server.alpn )
        |> Task.map Internal.toListener
        |> Task.mapError (Internal.toError >> classify True)



-- CONNECTION INFORMATION


{-| What a connection's TLS handshake agreed on.

`version` is the TLS version, a [`TlsVersion`](#TlsVersion). `alpn` is the application
protocol agreed, such as `Just "h2"`, and `Nothing` when none was agreed. `cipher` is the cipher
suite, in OpenSSL's name, such as `"TLS_AES_256_GCM_SHA384"`.

-}
type alias Info =
    { version : TlsVersion
    , alpn : Maybe String
    , cipher : String
    }


{-| A TLS version, as the handshake agreed on it.

The backends report the version by its OpenSSL name, and the names map to the cases as follows:

  - `Tls1_0`: `"TLSv1"`;
  - `Tls1_1`: `"TLSv1.1"`;
  - `Tls1_2`: `"TLSv1.2"`;
  - `Tls1_3`: `"TLSv1.3"`;
  - `UnknownTlsVersion name`: any other name, as it was reported.

-}
type TlsVersion
    = Tls1_0
    | Tls1_1
    | Tls1_2
    | Tls1_3
    | UnknownTlsVersion String


{-| The `TlsVersion` for OpenSSL's name of a protocol version.
-}
toTlsVersion : String -> TlsVersion
toTlsVersion name =
    case name of
        "TLSv1" ->
            Tls1_0

        "TLSv1.1" ->
            Tls1_1

        "TLSv1.2" ->
            Tls1_2

        "TLSv1.3" ->
            Tls1_3

        _ ->
            UnknownTlsVersion name


{-| A failed TLS operation, by the layer it failed in.

  - `SocketError error`: the TCP connection under TLS failed, or an argument of the TCP side
    could not be used; `error` is a [`Socket.Error`](Socket#Error), whose
    [`Socket.errorKind`](Socket#errorKind) says what went wrong, as for `Socket.Tcp`. A peer
    that drops the connection during the handshake is a `SocketError` with the kind
    [`Socket.ConnectionReset`](Socket#ErrorKind).
  - `TlsError problem`: TLS itself failed; the [`Problem`](#Problem) says how.

Only failures produced by TLS itself, such as a certificate check or an error that the TLS
library reports, are a `TlsError`.

-}
type Error
    = SocketError Socket.Error
    | TlsError Problem


{-| How TLS itself failed.

  - `CertificateRejected problem`: `connect` rejected the server's certificate; the
    [`CertificateProblem`](#CertificateProblem) says why.
  - `CertificateUnusable reason`: certificates or a key given to this module cannot be used: the
    `certificateChain` or `privateKey` of [`listen`](#listen), the two not belonging together, or
    the certificates of `TrustedCertificates` for `connect`. `reason` is the TLS library's reason
    in upper case with underscores, such as `"NO_CERTIFICATES"`; the backend reports it as the
    code `ERR_SSL_<reason>`.
  - `HandshakeFailed reason`: the handshake, or the TLS layer of an open connection, failed for
    another reason, such as the two ends sharing no TLS version or cipher. `reason` is the TLS
    library's reason as for `CertificateUnusable`, or `"UNKNOWN"` when the library gave none.

The reasons stay text because the TLS library has hundreds of them.

-}
type Problem
    = CertificateRejected CertificateProblem
    | CertificateUnusable String
    | HandshakeFailed String


{-| Why a client rejected a server's certificate. The code each case stands for, as the backends
report it, is in parentheses.

  - `Expired`: the certificate has expired (CERT_HAS_EXPIRED).
  - `NotYetValid`: the certificate is not valid yet (CERT_NOT_YET_VALID).
  - `Revoked`: the certificate was revoked (CERT_REVOKED).
  - `SelfSigned`: the certificate is self-signed and not trusted
    (DEPTH_ZERO_SELF_SIGNED_CERT).
  - `SelfSignedInChain`: the chain ends in a self-signed certificate that is not trusted
    (SELF_SIGNED_CERT_IN_CHAIN).
  - `IssuerNotTrusted`: the certificate of the authority that signed it is not available or not
    trusted (UNABLE_TO_GET_ISSUER_CERT_LOCALLY).
  - `LeafNotVerifiable`: the server's own certificate cannot be verified, usually because the
    server did not send the intermediate certificates (UNABLE_TO_VERIFY_LEAF_SIGNATURE).
  - `NameMismatch`: the certificate does not name the `serverName` connected to, as a DNS name
    or an IP address (ERR_TLS_CERT_ALTNAME_INVALID).
  - `VerificationFailed`: verification failed for another reason (CERT_VERIFY_FAILED on the
    native backend; on the JavaScript backend, any other verification code Node reports).

-}
type CertificateProblem
    = Expired
    | NotYetValid
    | Revoked
    | SelfSigned
    | SelfSignedInChain
    | IssuerNotTrusted
    | LeafNotVerifiable
    | NameMismatch
    | VerificationFailed


{-| Returns a description of the error for people to read. For a `SocketError` it is that of
[`Socket.errorToString`](Socket#errorToString). For a `TlsError` it is the code the backend
reports for the problem, `": "`, and a description of it, as in
`"CERT_HAS_EXPIRED: the certificate has expired"` or
`"ERR_SSL_NO_CERTIFICATES: the certificates cannot be used"`.
-}
errorToString : Error -> String
errorToString error =
    case error of
        SocketError e ->
            Socket.errorToString e

        TlsError problem ->
            let
                ( code, description ) =
                    describeProblem problem
            in
            code ++ ": " ++ description


{-| Reads the failure of a TLS connection's stream back as an [`Error`](#Error), or returns
`Nothing` for a failure that some other kind of stream made.

A read or write on the streams of a TLS connection that fails because of the connection fails
with `Stream.Failed`. This gives a `TlsError` when TLS itself failed, for example with
`HandshakeFailed` when the peer sent data TLS cannot accept, and a `SocketError` when the
connection under TLS failed, with the same [`Socket.Error`](Socket#Error) that
[`Socket.fromStreamFailure`](Socket#fromStreamFailure) gives. One call covers both, so a
program reading a TLS connection needs only this one.

-}
fromStreamFailure : Stream.Failure -> Maybe Error
fromStreamFailure (Stream.Internal.Failure f) =
    if f.origin == "tls" then
        Just (classify False (Internal.error f.code f.message))

    else if f.origin == "socket" then
        Just (SocketError (Internal.error f.code f.message))

    else
        Nothing


{-| Sorts a failure the kernel reported for a TLS operation into the TLS layer's own problems and
the connection's. `listening` tells `listen` apart: there every `ERR_SSL_` code means its
certificate chain or key cannot be used. On `connect`, the kernels report trusted certificates
that cannot be read with a message starting `"trusted certificates"`, before contacting the
server; any other `ERR_SSL_` code is a failed handshake.
-}
classify : Bool -> Socket.Error -> Error
classify listening ((Internal.Error e) as socketError) =
    case certificateProblem e.code of
        Just problem ->
            TlsError (CertificateRejected problem)

        Nothing ->
            if String.startsWith "ERR_SSL_" e.code then
                let
                    reason =
                        String.dropLeft 8 e.code
                in
                if listening || String.startsWith "trusted certificates" e.message then
                    TlsError (CertificateUnusable reason)

                else
                    TlsError (HandshakeFailed reason)

            else
                SocketError socketError


{-| The `CertificateProblem` a verification code names. Node reports more verification codes than
the native backend, which reports any other as `CERT_VERIFY_FAILED`; they become
`VerificationFailed` too.
-}
certificateProblem : String -> Maybe CertificateProblem
certificateProblem code =
    case code of
        "CERT_HAS_EXPIRED" ->
            Just Expired

        "CERT_NOT_YET_VALID" ->
            Just NotYetValid

        "CERT_REVOKED" ->
            Just Revoked

        "DEPTH_ZERO_SELF_SIGNED_CERT" ->
            Just SelfSigned

        "SELF_SIGNED_CERT_IN_CHAIN" ->
            Just SelfSignedInChain

        "UNABLE_TO_GET_ISSUER_CERT_LOCALLY" ->
            Just IssuerNotTrusted

        "UNABLE_TO_VERIFY_LEAF_SIGNATURE" ->
            Just LeafNotVerifiable

        "ERR_TLS_CERT_ALTNAME_INVALID" ->
            Just NameMismatch

        "CERT_VERIFY_FAILED" ->
            Just VerificationFailed

        _ ->
            if
                String.startsWith "CERT_" code
                    || String.contains "_CERT" code
                    || List.member code [ "HOSTNAME_MISMATCH", "INVALID_CA", "PATH_LENGTH_EXCEEDED", "INVALID_PURPOSE" ]
            then
                Just VerificationFailed

            else
                Nothing


{-| The code a backend reports for a problem, and a description of it, for `errorToString`.
-}
describeProblem : Problem -> ( String, String )
describeProblem problem =
    case problem of
        CertificateRejected certificate ->
            describeCertificateProblem certificate

        CertificateUnusable reason ->
            ( "ERR_SSL_" ++ reason, "the certificates cannot be used" )

        HandshakeFailed reason ->
            ( "ERR_SSL_" ++ reason, "the TLS handshake failed" )


{-| The verification code and a description of a certificate problem, for `errorToString`.
-}
describeCertificateProblem : CertificateProblem -> ( String, String )
describeCertificateProblem certificate =
    case certificate of
        Expired ->
            ( "CERT_HAS_EXPIRED", "the certificate has expired" )

        NotYetValid ->
            ( "CERT_NOT_YET_VALID", "the certificate is not yet valid" )

        Revoked ->
            ( "CERT_REVOKED", "the certificate has been revoked" )

        SelfSigned ->
            ( "DEPTH_ZERO_SELF_SIGNED_CERT", "the certificate is self-signed" )

        SelfSignedInChain ->
            ( "SELF_SIGNED_CERT_IN_CHAIN", "the certificate chain holds a self-signed certificate" )

        IssuerNotTrusted ->
            ( "UNABLE_TO_GET_ISSUER_CERT_LOCALLY", "the certificate's issuer is not trusted" )

        LeafNotVerifiable ->
            ( "UNABLE_TO_VERIFY_LEAF_SIGNATURE", "the certificate's signature cannot be verified" )

        NameMismatch ->
            ( "ERR_TLS_CERT_ALTNAME_INVALID", "the certificate does not match the server name" )

        VerificationFailed ->
            ( "CERT_VERIFY_FAILED", "the certificate failed verification" )


{-| Returns what the handshake of a TLS connection agreed on.

Fails with a `SocketError` whose kind is [`Socket.InvalidInput`](Socket#ErrorKind) for a
connection that is not a TLS connection. Once the connection has ended, it may fail in the same
way.

-}
info : Socket.Connection -> Task Error Info
info (Internal.Connection c) =
    kInfo c.id
        |> Task.map (\( version, alpn, cipher ) -> { version = toTlsVersion version, alpn = alpn, cipher = cipher })
        |> Task.mapError (Internal.toError >> classify False)



-- KERNELS
-- The annotations fix the kernel ABI: the kernels rely on exactly these argument and result
-- shapes.


{-| The kernel's TLS connect. It takes `( address text, port, timeout in milliseconds )` and
`( noDelay, keep-alive idle time in whole seconds )`, as for a TCP connect, and
`( serverName, ( verification, pem ), alpn )`, where verification 0 trusts the system's
authorities, 1 the certificates in `pem`, and 2 turns verification off. It succeeds with
`( id, ( readableId, writableId ), ( local, remote ) )`, each endpoint being
`( kind, text, port )`. A failure is `( code, message )`.
-}
kConnect :
    ( String, Int, Int )
    -> ( Bool, Int )
    -> ( String, ( Int, String ), List String )
    -> Task ( String, String ) ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )
kConnect =
    Eco.Kernel.Tls.connect


{-| The kernel's TLS listen. It takes `( address text, port )` and `( backlog, ipv6Only )`, as for
a TCP listen, and `( certificateChain, privateKey, alpn )`, and succeeds with `( id, endpoint )`,
the endpoint being `( kind, text, port )`. A failure is `( code, message )`.
-}
kListen :
    ( String, Int )
    -> ( Int, Bool )
    -> ( String, String, List String )
    -> Task ( String, String ) ( Int, ( Int, String, Int ) )
kListen =
    Eco.Kernel.Tls.listen


{-| The kernel's report on a connection's handshake, taking a connection id and succeeding with
`( protocol, alpn, cipher )`. A failure is `( code, message )`.
-}
kInfo : Int -> Task ( String, String ) ( String, Maybe String, String )
kInfo =
    Eco.Kernel.Tls.info
