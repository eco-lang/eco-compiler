module Socket.Tls exposing
    ( ClientOptions, Verification(..), defaultClientOptions, connect
    , ServerOptions, listen
    , Info, info
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

A certificate that fails verification makes `connect` fail with a verification code such as
`"CERT_HAS_EXPIRED"` or `"ERR_TLS_CERT_ALTNAME_INVALID"`, which
[`Socket.errorIsCertificateInvalid`](Socket#errorIsCertificateInvalid) recognises. Most other
TLS failures have codes starting with `"ERR_SSL_"`, and a server that closes the connection
during the handshake usually gives `"ECONNRESET"`. Once a connection has been made, failures to
read or write arrive on its streams, as for any connection.


## Clients

@docs ClientOptions, Verification, defaultClientOptions, connect


## Servers

@docs ServerOptions, listen


## Connection information

@docs Info, info

-}

import Eco.Kernel.Tls
import Socket
import Socket.Internal as Internal
import Socket.Tcp
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
bytes of UTF-8, or `connect` fails with `EINVAL`.

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
no certificate can be read from `pem`, `connect` fails with a code starting `"ERR_SSL_"` before it
contacts the server.

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

The TCP side is made from the same options as by `Socket.Tcp.connect`, and fails in the same ways.
Its `timeout` covers the handshake too: the task fails with `ETIMEDOUT` when connecting and the
handshake together take longer. The `alpn` names, and the certificates of `TrustedCertificates`,
are checked before anything connects, so a problem with them fails the task without contacting
the server. A rejected certificate fails it with a code that
[`Socket.errorIsCertificateInvalid`](Socket#errorIsCertificateInvalid) recognises.

-}
connect : ClientOptions -> Socket.Tcp.ConnectOptions -> Task Socket.Error Socket.Connection
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
        |> Task.mapError Internal.toError



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
the same ways.

The certificate, the key, and whether the two belong together are checked before anything
listens. When they cannot be used, the task fails, usually with a code starting `"ERR_SSL_"`. An
`alpn` name that is empty or longer than 255 bytes fails it with `EINVAL`.

A client whose handshake fails, or has not finished after 120 seconds, is closed without being
handed to the program. On the native backend at most 64 handshakes are under way at once on one
listener; further clients wait in the operating system's listen queue.

-}
listen : ServerOptions -> Socket.Tcp.ListenOptions -> Task Socket.Error Socket.Listener
listen server tcp =
    let
        ( target, settings ) =
            Internal.tcpListenArgs tcp
    in
    kListen target settings ( server.certificateChain, server.privateKey, server.alpn )
        |> Task.map Internal.toListener
        |> Task.mapError Internal.toError



-- CONNECTION INFORMATION


{-| What a connection's TLS handshake agreed on, in OpenSSL's names.

`protocol` is the TLS version, such as `"TLSv1.3"`, not the application protocol, which is
`alpn`. `alpn` is `Nothing` when no application protocol was agreed. `cipher` is the cipher
suite, such as `"TLS_AES_256_GCM_SHA384"`.

-}
type alias Info =
    { protocol : String
    , alpn : Maybe String
    , cipher : String
    }


{-| Returns what the handshake of a TLS connection agreed on.

Fails with `EINVAL` for a connection that is not a TLS connection. Once the connection has ended,
it may fail with `EINVAL` as well.

-}
info : Socket.Connection -> Task Socket.Error Info
info (Internal.Connection c) =
    kInfo c.id
        |> Task.map (\( protocol, alpn, cipher ) -> { protocol = protocol, alpn = alpn, cipher = cipher })
        |> Task.mapError Internal.toError



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
