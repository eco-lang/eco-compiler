module Socket.Unix exposing
    ( connect, ListenOptions, defaultListenOptions, listen, peerCredentials )

{-| Unix domain stream sockets: connections between programs on the same machine, named by a
path in the file system.

Connections and listeners are the same [`Connection`](Socket#Connection) and
[`Listener`](Socket#Listener) as for TCP. The path of a socket must be shorter than the system's
limit (107 bytes of UTF-8 on Linux, 103 on macOS); a longer one fails with `ENAMETOOLONG`.

@docs connect, ListenOptions, defaultListenOptions, listen, peerCredentials

-}

import Eco.Kernel.Socket
import Socket
import Socket.Internal as Internal
import System.File.Path as Path exposing (Path)
import Task exposing (Task)


{-| Connect to the Unix domain socket at a path. Fails with `ENOENT` when there is no socket there,
`ECONNREFUSED` when nobody listens on it, and `EAGAIN` when its listener's queue is full.

The connection's remote endpoint is the path; its local endpoint is the empty path.

-}
connect : Path -> Task Socket.Error Socket.Connection
connect path =
    kUnixConnect (Path.toPosixString path)
        |> Task.map Internal.toConnection
        |> Task.mapError Internal.toError


{-| How to listen.

  - `path`: where to create the socket.
  - `removeExisting`: if a socket file already exists at the path (left behind by an earlier
    program, for example), remove it first. Only a socket is removed; any other existing file makes
    `listen` fail with `EADDRINUSE`.
  - `permissions`: set the socket file's mode, as a number (`0o600` is `384`), before any client
    can connect. `Nothing` keeps the mode the process's umask gives.

-}
type alias ListenOptions =
    { path : Path
    , removeExisting : Bool
    , permissions : Maybe Int
    }


{-| Listen on a path, failing if it exists, with the default permissions.
-}
defaultListenOptions : Path -> ListenOptions
defaultListenOptions path =
    { path = path
    , removeExisting = False
    , permissions = Nothing
    }


{-| Start listening on a Unix domain socket. Fails with `EADDRINUSE` when the path exists (see
`removeExisting`). [`Socket.closeListener`](Socket#closeListener) removes the socket file again.

Accepted connections have the path as their local endpoint and the empty path as their remote
endpoint.

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


{-| The process id, user id and group id of the program at the other end of a Unix domain
connection, as they were when the connection was made. Fails with `EINVAL` for a connection that
is not a Unix domain connection.
-}
peerCredentials : Socket.Connection -> Task Socket.Error { pid : Int, uid : Int, gid : Int }
peerCredentials (Internal.Connection c) =
    kPeerCredentials c.id
        |> Task.map (\( pid, uid, gid ) -> { pid = pid, uid = uid, gid = gid })
        |> Task.mapError Internal.toError



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-sockets.md Appendix B.1).


kUnixConnect : String -> Task ( String, String ) ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )
kUnixConnect =
    Eco.Kernel.Socket.unixConnect


kUnixListen : String -> ( Bool, Int ) -> Task ( String, String ) ( Int, ( Int, String, Int ) )
kUnixListen =
    Eco.Kernel.Socket.unixListen


kPeerCredentials : Int -> Task ( String, String ) ( Int, Int, Int )
kPeerCredentials =
    Eco.Kernel.Socket.peerCredentials
