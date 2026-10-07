module PackageLinksTest exposing (main)

{-| Phase 1 smoke test for eco/system (plans/eco-system-library.md Phase 1
step 8j): the package compiles natively and the program links.

Every public module is imported, and one value of each is referenced from the
`ref*` functions below so the package API is type-checked against this
program. The package modules are still Phase 0 stubs (`Debug.todo` bodies), so
nothing from them may run: the `ref*` functions take an argument (no top-level
value is evaluated) and are not reachable from `main`.

-}

-- CHECK: links: 1
-- CHECK-NOT: Debug.todo
-- EXIT: 0

import Bytes exposing (Bytes)
import Http.Server
import Http.Server.Response
import Http.Stream
import Platform
import Stream
import Stream.Log
import System
import System.File
import System.File.FileHandle
import System.File.Path
import System.Process
import System.Terminal
import Task exposing (Task)


refSystem : Int -> Cmd msg
refSystem code =
    System.exitWithCode code


refStream : Stream.Error -> String
refStream err =
    Stream.errorToString err


refStreamLog : Stream.Writable Bytes -> String -> Task x ()
refStreamLog out text =
    Stream.Log.line out text


refFile : System.File.Error -> String
refFile err =
    System.File.errorToString err


refFileHandle : System.File.FileHandle.FileHandle a b -> Task System.File.Error ()
refFileHandle handle =
    System.File.FileHandle.close handle


refPath : String -> String
refPath text =
    System.File.Path.toPosixString (System.File.Path.fromPosixString text)


refProcess : String -> List String -> System.Process.SpawnOptions msg -> Cmd msg
refProcess program args options =
    System.Process.spawn program args options


refTerminal : String -> Task x ()
refTerminal title =
    System.Terminal.setProcessTitle title


refHttpServer : Http.Server.Method -> String
refHttpServer method =
    Http.Server.methodToString method


refHttpResponse : Http.Server.Response.Response -> Http.Server.Response.Response
refHttpResponse response =
    Http.Server.Response.setStatus 200 response


refHttpStream : () -> Http.Stream.Body
refHttpStream _ =
    Http.Stream.emptyBody


init : () -> ( (), Cmd () )
init _ =
    let
        _ =
            Debug.log "links" 1
    in
    ( (), Cmd.none )


main : Program () () ()
main =
    Platform.worker
        { init = init
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
