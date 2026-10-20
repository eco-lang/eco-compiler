module Socket.Unix exposing
    ( connect, ListenOptions, defaultListenOptions, listen, peerCredentials )

{-| Programs on the same machine can connect to each other through a name in the file system
instead of a network address, and this module makes such connections and listeners.

A _Unix domain socket_ is a stream socket whose address is a path. A listener creates a _socket
file_ at the path, and a client connects by naming that path. The
[`Connection`](Socket#Connection) and [`Listener`](Socket#Listener) made here are the same types
as for TCP, and are used through [`Socket`](Socket); what is particular to this module is
making them and reading a connection's peer credentials.

A path is handed to the operating system as [`Path.toPosixString`](Path#toPosixString) prints
it. That text must be at most 107 bytes of UTF-8 on Linux and 103 on macOS; a longer one fails
with `ENAMETOOLONG`. On the native backend under Windows, connecting and listening fail with
`ENOTSUP`.

The socket file's path is the only name a connection has. On the side that connected it is the
remote endpoint, and on the side that accepted it is the local endpoint, in both cases as the path
[`Path.toPosixString`](Path#toPosixString) prints, parsed again; the other endpoint is the empty
path, [`Path.empty`](Path#empty).

A Unix domain connection can also tell who is at the other end: its _peer credentials_ are the
process id, user id and group id of the program on the other side, which
[`peerCredentials`](#peerCredentials) reads.


## Connecting

@docs connect


## Listening

@docs ListenOptions, defaultListenOptions, listen


## Peer credentials

@docs peerCredentials

-}

import Eco.Kernel.Socket
import Socket
import Socket.Internal as Internal
import Path exposing (Path)
import Task exposing (Task)


{-| Connects to the listener whose socket file is at `path`.

Fails with `ENOENT` when nothing exists at the path, with `ECONNREFUSED` when nobody listens on
it, and, on Linux, with `EAGAIN` when the operating system's queue of connections waiting on that
listener is full.

The connection's remote endpoint is `path`, printed and parsed again, and its local endpoint is
the empty path.

-}
connect : Path -> Task Socket.Error Socket.Connection
connect path =
    kUnixConnect (Path.toPosixString path)
        |> Task.map Internal.toConnection
        |> Task.mapError Internal.toError


{-| The options for [`listen`](#listen): where to create the socket file, whether a socket file
already there may be replaced, and the mode to give it.

`removeExisting` removes a socket file already at `path` before listening, whether or not a
program still listens on it. Any other kind of file there, a symbolic link included, still makes
`listen` fail with `EADDRINUSE`.

`permissions` is the socket file's mode as a number (`0o600` is `384`), of which only the
low twelve bits, `0o7777`, are used. On the native backend it is set before the socket starts
listening, so no client connects before it applies; on the JavaScript backend it is set once
listening has started, before the task succeeds. `Nothing`, or a negative number, leaves the mode
the process's umask gives. If the mode cannot be set, `listen` fails.

-}
type alias ListenOptions =
    { path : Path
    , removeExisting : Bool
    , permissions : Maybe Int
    }


{-| Returns the options for listening at `path` with which `listen` fails when anything already
exists there, and which leave the socket file's mode to the umask.
-}
defaultListenOptions : Path -> ListenOptions
defaultListenOptions path =
    { path = path
    , removeExisting = False
    , permissions = Nothing
    }


{-| Starts listening at `options.path`, creating the socket file there.

Fails with `EADDRINUSE` when something already exists at the path and `removeExisting` does not
allow it to be removed. A `listen` that fails after creating the socket file removes it again, and
so does [`Socket.closeListener`](Socket#closeListener).

Each connection the listener hands out has as its local endpoint the path printed and parsed
again, and the empty path as its remote endpoint.

-}
listen : ListenOptions -> Task Socket.Error Socket.Listener
listen options =
    let
        mode =
            case options.permissions of
                Just m ->
                    if m < 0 then
                        -1

                    else
                        m

                Nothing ->
                    -1
    in
    kUnixListen (Path.toPosixString options.path) ( options.removeExisting, mode )
        |> Task.map Internal.toListener
        |> Task.mapError Internal.toError


{-| Asks for the peer credentials of a Unix domain connection: the process id, user id and group
id of the program at the other end, as the operating system reported them when the connection was
made.

Fails with `EINVAL` for a connection that is not a Unix domain connection, and on the JavaScript
backend for one that has closed. Otherwise it fails with `ENOTSUP` where the credentials cannot be
read: on the JavaScript backend for every Unix domain connection, and on the native backend on
systems other than Linux and macOS.

-}
peerCredentials : Socket.Connection -> Task Socket.Error { pid : Int, uid : Int, gid : Int }
peerCredentials (Internal.Connection c) =
    kPeerCredentials c.id
        |> Task.map (\( pid, uid, gid ) -> { pid = pid, uid = uid, gid = gid })
        |> Task.mapError Internal.toError



-- KERNELS
-- The annotations fix the kernel ABI: the kernels rely on exactly these argument and result
-- shapes. A failure is an FErr, `( code, message )`. ConnT and ListenT are the tuples
-- `Socket.Internal` decodes.


{-| Asks the kernel to connect to the socket file at the given POSIX path, succeeding with a
ConnT.
-}
kUnixConnect : String -> Task ( String, String ) ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )
kUnixConnect =
    Eco.Kernel.Socket.unixConnect


{-| Asks the kernel to listen at the given POSIX path, given `( removeExisting, mode )` with a
mode of -1 for none, succeeding with a ListenT.
-}
kUnixListen : String -> ( Bool, Int ) -> Task ( String, String ) ( Int, ( Int, String, Int ) )
kUnixListen =
    Eco.Kernel.Socket.unixListen


{-| Asks the kernel for the `( pid, uid, gid )` of the peer of the connection with the given id.
-}
kPeerCredentials : Int -> Task ( String, String ) ( Int, Int, Int )
kPeerCredentials =
    Eco.Kernel.Socket.peerCredentials
