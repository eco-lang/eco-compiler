module ErrorNames exposing
    ( fileKind, fileError
    , socketKind, socketError
    , tlsProblem, tlsError
    , webSocketError
    , serverKind
    , startError
    , streamError
    )

{-| Prints the eco/system error types for test output, each as its constructor's name
followed by its arguments, so that CHECK lines name the kind of failure rather than a backend's
code: `ConnectionRefused`, `AddressPathFailed NoSuchFileOrDirectory`, `OtherSocketError EXYZ`,
`TlsError (CertificateRejected Expired)`.

It does not use `Debug.toString`, so the text is the same on every backend.

@docs fileKind, fileError
@docs socketKind, socketError
@docs tlsProblem, tlsError
@docs webSocketError
@docs serverKind
@docs startError
@docs streamError

-}

import ChildProcess
import FileSystem
import Http.Server
import Http.Stream
import Socket
import Socket.Tls
import Stream
import WebSocket


{-| A `FileSystem.ErrorKind`, as `NoSuchFileOrDirectory` or `OtherFileSystemError <code>`.
-}
fileKind : FileSystem.ErrorKind -> String
fileKind kind =
    case kind of
        FileSystem.NoSuchFileOrDirectory ->
            "NoSuchFileOrDirectory"

        FileSystem.FileExists ->
            "FileExists"

        FileSystem.DirectoryFound ->
            "DirectoryFound"

        FileSystem.DirectoryRemoveNotRecursive ->
            "DirectoryRemoveNotRecursive"

        FileSystem.NotADirectory ->
            "NotADirectory"

        FileSystem.DirectoryNotEmpty ->
            "DirectoryNotEmpty"

        FileSystem.PermissionDenied ->
            "PermissionDenied"

        FileSystem.NotPermitted ->
            "NotPermitted"

        FileSystem.TooManyOpenFiles ->
            "TooManyOpenFiles"

        FileSystem.LinkLoop ->
            "LinkLoop"

        FileSystem.PathTooLong ->
            "PathTooLong"

        FileSystem.InvalidInput ->
            "InvalidInput"

        FileSystem.IOError ->
            "IOError"

        FileSystem.NotSupported ->
            "NotSupported"

        FileSystem.CrossDevice ->
            "CrossDevice"

        FileSystem.HandleClosed ->
            "HandleClosed"

        FileSystem.NoSpace ->
            "NoSpace"

        FileSystem.ReadOnlyFileSystem ->
            "ReadOnlyFileSystem"

        FileSystem.OtherFileSystemError code ->
            "OtherFileSystemError " ++ code


{-| The kind of a `FileSystem.Error`.
-}
fileError : FileSystem.Error -> String
fileError e =
    fileKind (FileSystem.errorKind e)


{-| A `Socket.ErrorKind`, as `ConnectionRefused` or `AddressPathFailed NoSuchFileOrDirectory`.
-}
socketKind : Socket.ErrorKind -> String
socketKind kind =
    case kind of
        Socket.ConnectionRefused ->
            "ConnectionRefused"

        Socket.ConnectionReset ->
            "ConnectionReset"

        Socket.TimedOut ->
            "TimedOut"

        Socket.NetworkUnreachable ->
            "NetworkUnreachable"

        Socket.AddressInUse ->
            "AddressInUse"

        Socket.AddressNotAvailable ->
            "AddressNotAvailable"

        Socket.HostNotFound ->
            "HostNotFound"

        Socket.HostLookupTryAgain ->
            "HostLookupTryAgain"

        Socket.PermissionDenied ->
            "PermissionDenied"

        Socket.Cancelled ->
            "Cancelled"

        Socket.Busy ->
            "Busy"

        Socket.InvalidInput ->
            "InvalidInput"

        Socket.NotSupported ->
            "NotSupported"

        Socket.MessageTooLarge ->
            "MessageTooLarge"

        Socket.ListenQueueFull ->
            "ListenQueueFull"

        Socket.AddressPathFailed fileKind_ ->
            "AddressPathFailed " ++ fileKind fileKind_

        Socket.ConnectionTakenOver ->
            "ConnectionTakenOver"

        Socket.OtherSocketError code ->
            "OtherSocketError " ++ code


{-| The kind of a `Socket.Error`.
-}
socketError : Socket.Error -> String
socketError e =
    socketKind (Socket.errorKind e)


{-| A `Socket.Tls.Problem`, as `CertificateRejected Expired` or `HandshakeFailed <reason>`.
-}
tlsProblem : Socket.Tls.Problem -> String
tlsProblem problem =
    case problem of
        Socket.Tls.CertificateRejected certificate ->
            "CertificateRejected "
                ++ (case certificate of
                        Socket.Tls.Expired ->
                            "Expired"

                        Socket.Tls.NotYetValid ->
                            "NotYetValid"

                        Socket.Tls.Revoked ->
                            "Revoked"

                        Socket.Tls.SelfSigned ->
                            "SelfSigned"

                        Socket.Tls.SelfSignedInChain ->
                            "SelfSignedInChain"

                        Socket.Tls.IssuerNotTrusted ->
                            "IssuerNotTrusted"

                        Socket.Tls.LeafNotVerifiable ->
                            "LeafNotVerifiable"

                        Socket.Tls.NameMismatch ->
                            "NameMismatch"

                        Socket.Tls.VerificationFailed ->
                            "VerificationFailed"
                   )

        Socket.Tls.CertificateUnusable reason ->
            "CertificateUnusable " ++ reason

        Socket.Tls.HandshakeFailed reason ->
            "HandshakeFailed " ++ reason


{-| A `Socket.Tls.Error`: `SocketError <kind>` or `TlsError (<problem>)`.
-}
tlsError : Socket.Tls.Error -> String
tlsError error =
    case error of
        Socket.Tls.SocketError e ->
            "SocketError " ++ socketError e

        Socket.Tls.TlsError problem ->
            "TlsError (" ++ tlsProblem problem ++ ")"


{-| A `WebSocket.Error`: `SocketError <kind>`, `TlsError (<problem>)`, `HandshakeRefused <status>`,
`HandshakeFailed`, `HeartbeatTimedOut`, `MessageTooLarge` or `ProtocolViolation <details>`.
-}
webSocketError : WebSocket.Error -> String
webSocketError error =
    case error of
        WebSocket.SocketError e ->
            "SocketError " ++ socketError e

        WebSocket.TlsError problem ->
            "TlsError (" ++ tlsProblem problem ++ ")"

        WebSocket.HandshakeRefused status ->
            "HandshakeRefused " ++ String.fromInt status

        WebSocket.HandshakeFailed ->
            "HandshakeFailed"

        WebSocket.HeartbeatTimedOut ->
            "HeartbeatTimedOut"

        WebSocket.MessageTooLarge ->
            "MessageTooLarge"

        WebSocket.ProtocolViolation details ->
            "ProtocolViolation " ++ details


{-| An `Http.Server.ErrorKind`, as `AddressInUse` or `CertificateUnusable <reason>`.
-}
serverKind : Http.Server.ErrorKind -> String
serverKind kind =
    case kind of
        Http.Server.AddressInUse ->
            "AddressInUse"

        Http.Server.AddressNotAvailable ->
            "AddressNotAvailable"

        Http.Server.HostNotFound ->
            "HostNotFound"

        Http.Server.HostLookupTryAgain ->
            "HostLookupTryAgain"

        Http.Server.PermissionDenied ->
            "PermissionDenied"

        Http.Server.InvalidPort ->
            "InvalidPort"

        Http.Server.InvalidInput ->
            "InvalidInput"

        Http.Server.NotSupported ->
            "NotSupported"

        Http.Server.CertificateUnusable reason ->
            "CertificateUnusable " ++ reason

        Http.Server.OtherServerError code ->
            "OtherServerError " ++ code


{-| A `ChildProcess.StartError`, as `ProgramNotFound` or `OtherStartError <code>`.
-}
startError : ChildProcess.StartError -> String
startError error =
    case error of
        ChildProcess.ProgramNotFound ->
            "ProgramNotFound"

        ChildProcess.PermissionDenied ->
            "PermissionDenied"

        ChildProcess.NotExecutable ->
            "NotExecutable"

        ChildProcess.ArgumentsTooLong ->
            "ArgumentsTooLong"

        ChildProcess.ProcessLimitReached ->
            "ProcessLimitReached"

        ChildProcess.OtherStartError code ->
            "OtherStartError " ++ code


{-| A `Stream.Error`: `Closed`, `Locked`, `Cancelled <reason>`, or `Failed` followed by the kind the
implementing module reads from the failure (`Failed socket ConnectionReset`, `Failed file
IOError`, `Failed websocket HeartbeatTimedOut`, `Failed tls TlsError (...)`, `Failed http`), or by
`Stream.failureToString` when no module reads it (child pipes, codecs).
-}
streamError : Stream.Error -> String
streamError error =
    case error of
        Stream.Closed ->
            "Closed"

        Stream.Locked ->
            "Locked"

        Stream.Cancelled reason ->
            "Cancelled " ++ reason

        Stream.Failed failure ->
            "Failed "
                ++ (case WebSocket.fromStreamFailure failure of
                        Just (WebSocket.SocketError e) ->
                            -- a socket failure: WebSocket.fromStreamFailure reads those too
                            "socket " ++ socketError e

                        Just (WebSocket.TlsError problem) ->
                            "tls TlsError (" ++ tlsProblem problem ++ ")"

                        Just other ->
                            "websocket " ++ webSocketError other

                        Nothing ->
                            case FileSystem.fromStreamFailure failure of
                                Just e ->
                                    "file " ++ fileError e

                                Nothing ->
                                    case Http.Stream.fromStreamFailure failure of
                                        Just _ ->
                                            "http"

                                        Nothing ->
                                            Stream.failureToString failure
                   )
