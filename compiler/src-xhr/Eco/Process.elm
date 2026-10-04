module Eco.Process exposing
    ( ExitCode(..), ProcessHandle(..), StdStream(..)
    , exit, spawn, spawnProcess, wait
    )

{-| The compiler ends its own process and runs other programs through this
module, and in the stock-Elm build this is where those requests leave the
program.

A program running on stock Elm cannot end itself or start another program, so
each operation here is sent to eco-io as an op, as `Eco.XHR` describes. The
native build compiles a twin of this module with the same exposed names and
signatures in its place.

A program started this way is a _child_. Starting one gives a
`ProcessHandle`, a number eco-io uses to name the child, and `wait` takes that
handle and gives the child's `ExitCode`. A child that exits with a non-zero
code is not an error here: `wait` reports it as `ExitFailure`.

The operations divide by how they treat a failed request. `spawn` and
`spawnProcess` fail with a `ProcessError`, which `Eco.Process.Error.ofKernelTuple`
makes from the failure tuple and the command being started; a failure to reach
eco-io at all is a `SpawnIOError`. `exit` and `wait` cannot fail: a failed
request crashes the program, through `Eco.XHR.orCrash`.


# Types

@docs ExitCode, ProcessHandle, StdStream


# Operations

@docs exit, spawn, spawnProcess, wait

-}

import Eco.Process.Error as ProcErr exposing (ProcessError)
import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| How a process ended, as its exit code.

`ExitSuccess` is code 0. `ExitFailure` carries the code, which is non-zero
when `wait` makes it. Nothing stops a caller making `ExitFailure 0`, and `exit`
sends it as code 0, the same as `ExitSuccess`.

-}
type ExitCode
    = ExitSuccess
    | ExitFailure Int


{-| A child process started by `spawn` or `spawnProcess`, named by the number
eco-io gave it, for passing to `wait`.

The constructor is exposed, so any `Int` can be made into a `ProcessHandle`,
and nothing in this module checks that the number names a child.

-}
type ProcessHandle
    = ProcessHandle Int


{-| What `spawnProcess` asks for one of a child's standard streams: standard
input, standard output or standard error.

`Inherit` asks for the child to share this process's stream. `CreatePipe` asks
for a new pipe in its place. `spawnProcess` hands back a handle for standard
input only, so nothing in this module gives a way to read a piped standard
output or standard error.

-}
type StdStream
    = Inherit
    | CreatePipe


{-| Asks eco-io to end the current process with `code`, sent as 0 for
`ExitSuccess` and as `n` for `ExitFailure n`.

The eco-io handler ends the process without replying; if eco-io answers with a
2xx reply, the task succeeds with `()`. A failed request crashes the program.

-}
exit : ExitCode -> Task Never ()
exit code =
    Eco.XHR.unitTask "Process.exit"
        (Encode.object
            [ ( "code", Encode.int (exitCodeToInt code) ) ]
        )
        |> Eco.XHR.orCrash


{-| Asks eco-io to start `cmd` with the arguments `args`, and returns the
handle of the child.

The request carries no stream settings; `spawnProcess` is the form that takes
them. A failed request fails with the `ProcessError` that
`Eco.Process.Error.ofKernelTuple` gives for it and `cmd`. A 2xx reply whose
`value` cannot be read as an integer crashes the program.

-}
spawn : String -> List String -> Task ProcessError ProcessHandle
spawn cmd args =
    Eco.XHR.jsonTask "Process.spawn"
        (Encode.object
            [ ( "cmd", Encode.string cmd )
            , ( "args", Encode.list Encode.string args )
            ]
        )
        Decode.int
        |> Task.mapError (ProcErr.ofKernelTuple cmd)
        |> Task.map ProcessHandle


{-| Asks eco-io to start `config.cmd` with the arguments `config.args` and the
given setting for each standard stream, and returns the handle of the child
together with `stdinHandle`.

`stdinHandle` is the number eco-io replies with for the child's standard input,
or `Nothing` when it replies `null`. This module does not check it against
`config.stdin`. Under the eco-io handler in `bin/eco-io-handler.js` it is a
number only when standard input is `CreatePipe`, and that number, made into an
`Eco.Console.Handle` or an `Eco.File.Handle`, is accepted by `Eco.Console.write`
and `Eco.File.close`. No handle is returned for standard output or standard
error.

A failed request fails with the `ProcessError` that
`Eco.Process.Error.ofKernelTuple` gives for it and `config.cmd`. A 2xx reply
whose `value` cannot be read as these two handles crashes the program.

-}
spawnProcess :
    { cmd : String
    , args : List String
    , stdin : StdStream
    , stdout : StdStream
    , stderr : StdStream
    }
    -> Task ProcessError { stdinHandle : Maybe Int, processHandle : ProcessHandle }
spawnProcess config =
    Eco.XHR.jsonTask "Process.spawnProcess"
        (Encode.object
            [ ( "cmd", Encode.string config.cmd )
            , ( "args", Encode.list Encode.string config.args )
            , ( "stdin", encodeStdStream config.stdin )
            , ( "stdout", encodeStdStream config.stdout )
            , ( "stderr", encodeStdStream config.stderr )
            ]
        )
        (Decode.map2
            (\stdinHandle ph ->
                { stdinHandle = stdinHandle
                , processHandle = ProcessHandle ph
                }
            )
            (Decode.field "stdinHandle" (Decode.nullable Decode.int))
            (Decode.field "processHandle" Decode.int)
        )
        |> Task.mapError (ProcErr.ofKernelTuple config.cmd)


{-| Asks eco-io to wait for the child named by the handle to end, and returns its
exit code: `ExitSuccess` for 0 and `ExitFailure` for any other number.

The code is the number eco-io replies with. The eco-io handler in
`bin/eco-io-handler.js` replies 0 for a handle it does not know and for a child
killed by a signal, so both give `ExitSuccess`. That handler starts listening
for the child's exit only when asked, so for a child that ended before it was
first waited for, it never replies and the task never completes. Once a `wait`
has replied, the handler forgets the handle, so a later `wait` on it gives
`ExitSuccess`. A failed request crashes the program.

-}
wait : ProcessHandle -> Task Never ExitCode
wait (ProcessHandle ph) =
    Eco.XHR.jsonTask "Process.wait"
        (Encode.object [ ( "handle", Encode.int ph ) ])
        Decode.int
        |> Eco.XHR.orCrash
        |> Task.map intToExitCode


{-| Returns the number `code` stands for: 0 for `ExitSuccess` and `n` for
`ExitFailure n`.
-}
exitCodeToInt : ExitCode -> Int
exitCodeToInt code =
    case code of
        ExitSuccess ->
            0

        ExitFailure n ->
            n


{-| Returns `ExitSuccess` for 0 and `ExitFailure code` for any other `code`.
-}
intToExitCode : Int -> ExitCode
intToExitCode code =
    if code == 0 then
        ExitSuccess

    else
        ExitFailure code


{-| Returns the JSON string a stream setting is sent as: `"inherit"` or
`"pipe"`.
-}
encodeStdStream : StdStream -> Encode.Value
encodeStdStream stream =
    case stream of
        Inherit ->
            Encode.string "inherit"

        CreatePipe ->
            Encode.string "pipe"
