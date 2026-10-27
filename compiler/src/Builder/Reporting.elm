module Builder.Reporting exposing
    ( Style, silent, json, terminal
    , Key, report, ignorer
    , trackDetails, DKey, DMsg(..)
    , trackBuild, BKey, BMsg(..)
    , attempt, attemptWithStyle
    , ask, reportGenerate
    , BResult
    )

{-| What the build tool prints while it works, and how a command that failed
ends.

Every command runs in one of three output styles, a `Style`. Only the terminal
style shows progress; the silent and JSON styles discard it and differ only in
how a failure is reported.

Progress is reported through a _key_, a send-only handle that a long-running
task is given and calls once per event. In the terminal style the key writes
each event to a channel, and a separate worker reads the channel and redraws a
progress line on standard output. The task doing the work never prints
progress itself.

The terminal style carries a lock, an `MVar ()`, so that progress and final
output do not interleave. A progress worker holds the lock while it runs and
gives it back after printing its final line. Printing a failure report or the
generated-files diagram first waits until the lock is free.

Most of the file is that machinery, twice over: once for verifying
dependencies (`trackDetails`) and once for compiling modules (`trackBuild`).
The rest is `attempt`, which turns a failed result into a report and a failing
exit, and `ask`, a yes/no prompt.


# Output Styles

@docs Style, silent, json, terminal


# Progress Tracking

@docs Key, report, ignorer
@docs trackDetails, DKey, DMsg
@docs trackBuild, BKey, BMsg


# Error Handling

@docs attempt, attemptWithStyle


# User Interaction

@docs ask, reportGenerate
@docs BResult

-}

import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Encode as Encode
import Compiler.Reporting.Doc as D
import System.Exit as Exit
import System.IO as IO exposing (MVar)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (Chan)



-- ====== STYLE ======


{-| How a command presents itself: what progress it shows and how it reports
a failure.

`Silent` shows no progress and exits on failure without printing anything.

`Json` shows no progress and writes a failure report to standard error as one
line of JSON.

`Terminal` shows progress on standard output and writes a failure report to
standard error, laid out for a terminal. Its `MVar ()` is the lock described in
the module docstring; it is made full by `terminal`.

-}
type Style
    = Silent
    | Json
    | Terminal (MVar ())


{-| The style that prints no progress and no failure report.
-}
silent : Style
silent =
    Silent


{-| The style that prints no progress and reports a failure as one line of
JSON on standard error.
-}
json : Style
json =
    Json


{-| Creates the terminal style, with its output lock initially free.
-}
terminal : Task Never Style
terminal =
    Task.map Terminal (Utils.newMVar (\_ -> BE.bool True) ())



-- ====== ATTEMPT ======


{-| Runs `work` and returns its `Ok` value. On `Err` it writes the error's
report to standard error, laid out for a terminal whatever style the command
uses, and exits with failure.
-}
attempt : (x -> Help.Report) -> Task Never (Result x a) -> Task Never a
attempt toReport work =
    work
        |> Task.andThen (handleAttemptResult toReport)


{-| Returns the `Ok` value of `result`, or reports the error to standard error
and exits with failure.
-}
handleAttemptResult : (x -> Help.Report) -> Result x a -> Task Never a
handleAttemptResult toReport result =
    case result of
        Ok a ->
            Task.succeed a

        Err x ->
            reportErrorAndExit (toReport x)


{-| Writes `helpReport` to standard error and exits with failure.
-}
reportErrorAndExit : Help.Report -> Task Never a
reportErrorAndExit helpReport =
    Exit.toStderr helpReport
        |> Task.andThen (\_ -> Exit.exitFailure)


{-| Runs `work` and returns its `Ok` value. On `Err` it exits with failure,
reporting the error as `style` dictates: nothing for `silent`, one line of JSON
on standard error for `json`, and the terminal layout on standard error for the
terminal style, printed once no progress worker holds the terminal lock.
-}
attemptWithStyle : Style -> (x -> Help.Report) -> Task Never (Result x a) -> Task Never a
attemptWithStyle style toReport work =
    work
        |> Task.andThen (handleStyledResult style toReport)


{-| Returns the `Ok` value of `result`, or reports the error in `style` and
exits with failure.
-}
handleStyledResult : Style -> (x -> Help.Report) -> Result x a -> Task Never a
handleStyledResult style toReport result =
    case result of
        Ok a ->
            Task.succeed a

        Err x ->
            exitWithError style (toReport x)


{-| Reports `helpReport` in `style` and exits with failure. The silent style
prints nothing.
-}
exitWithError : Style -> Help.Report -> Task Never a
exitWithError style helpReport =
    case style of
        Silent ->
            Exit.exitFailure

        Json ->
            exitWithJsonError helpReport

        Terminal mvar ->
            exitWithTerminalError mvar helpReport


{-| Writes `helpReport` to standard error as one line of JSON and exits with
failure.
-}
exitWithJsonError : Help.Report -> Task Never a
exitWithJsonError helpReport =
    Utils.builderHPutBuilder IO.stderr (Encode.encodeUgly (Exit.toJson helpReport))
        |> Task.andThen (\_ -> Exit.exitFailure)


{-| Waits until the terminal lock `mvar` is free, then writes `helpReport` to
standard error and exits with failure.
-}
exitWithTerminalError : MVar () -> Help.Report -> Task Never a
exitWithTerminalError mvar helpReport =
    Utils.readMVar (Bytes.Decode.map (\_ -> ()) BD.bool) mvar
        |> Task.andThen (\_ -> Exit.toStderr helpReport)
        |> Task.andThen (\_ -> Exit.exitFailure)



-- ====== MARKS ======


{-| The green mark printed before a package that downloaded successfully.
-}
goodMark : D.Doc
goodMark =
    D.green
        (if isWindows then
            D.fromChars "+"

         else
            D.fromChars "●"
        )


{-| The red mark printed before a package whose download failed.
-}
badMark : D.Doc
badMark =
    D.red
        (if isWindows then
            D.fromChars "X"

         else
            D.fromChars "✗"
        )


{-| Whether to draw marks and the generated-files diagram with plain ASCII
characters. It is always `False`: nothing detects the operating system, so the
Unicode characters are always used.
-}
isWindows : Bool
isWindows =
    -- TODO Info.os == "mingw32"
    False



-- ====== KEY ======


{-| A send-only handle for reporting progress events of type `msg`.

A key is obtained from `trackDetails` or `trackBuild`, or is `ignorer`. What
happens to a message depends on where the key came from; the sender cannot
tell whether it was printed.

-}
type Key msg
    = Key (msg -> Task Never ())


{-| Sends `msg` through `key`.
-}
report : Key msg -> msg -> Task Never ()
report (Key send) msg =
    send msg


{-| A key that discards every message.
-}
ignorer : Key msg
ignorer =
    Key (\_ -> Task.succeed ())



-- ====== ASK ======


{-| Prints `doc` to standard output and reads the answer to a yes/no question
from standard input.

An empty line, `y` or `Y` answers yes and `n` answers no. Anything else,
including `N`, prints a reminder and asks again.

-}
ask : D.Doc -> Task Never Bool
ask doc =
    Help.toStdout doc
        |> Task.andThen (\_ -> askHelp)


{-| Reads one line of input and returns the yes/no answer it gives, asking
again until the line is a valid answer.
-}
askHelp : Task Never Bool
askHelp =
    IO.flush
        |> Task.andThen (\_ -> IO.readLine |> IO.crashOnError)
        |> Task.andThen parseYesNoResponse


{-| Returns the answer `input` gives: yes for an empty line, `y` or `Y`, no for
`n`. Anything else asks again.
-}
parseYesNoResponse : String -> Task Never Bool
parseYesNoResponse input =
    case input of
        "" ->
            Task.succeed True

        "Y" ->
            Task.succeed True

        "y" ->
            Task.succeed True

        "n" ->
            Task.succeed False

        _ ->
            promptAndRetry


{-| Prints a reminder of the valid answers and asks again.
-}
promptAndRetry : Task Never Bool
promptAndRetry =
    IO.print "Must type 'y' for yes or 'n' for no: "
        |> Task.andThen (\_ -> askHelp)



-- ====== DETAILS ======


{-| A key for reporting progress while dependencies are downloaded and built.
-}
type alias DKey =
    Key DMsg


{-| Runs `callback` with a key for dependency progress, and returns its result.

In the terminal style a worker prints each download as it is reported and a
"Verifying dependencies (done/total)" line, which counts a package as done
once it is built, broken or failed to download. When `callback` finishes, the
worker prints "Dependencies ready!" if every package was built, and
"Dependency problem!" otherwise. A `DStart` message sets the total and resets
every count. In the other styles the key discards every message.

-}
trackDetails : Style -> (DKey -> Task Never a) -> Task Never a
trackDetails style callback =
    case style of
        Silent ->
            callback (Key (\_ -> Task.succeed ()))

        Json ->
            callback (Key (\_ -> Task.succeed ()))

        Terminal mvar ->
            Utils.newChan Utils.mVarEncoder
                |> Task.andThen (trackDetailsWithChan mvar callback)


{-| Starts the dependency progress worker reading `chan`, then runs `callback`
with a key that writes to `chan`.
-}
trackDetailsWithChan : MVar () -> (DKey -> Task Never a) -> Chan (Maybe DMsg) -> Task Never a
trackDetailsWithChan mvar callback chan =
    Utils.forkIO (runDetailsWorker mvar chan)
        |> Task.andThen (\_ -> runDetailsCallback chan callback)


{-| Takes the terminal lock `mvar`, prints dependency progress from `chan`
until the end-of-progress `Nothing`, then gives the lock back.
-}
runDetailsWorker : MVar () -> Chan (Maybe DMsg) -> Task Never ()
runDetailsWorker mvar chan =
    Utils.takeMVar (Bytes.Decode.succeed ()) mvar
        |> Task.andThen (\_ -> detailsLoop chan (DState { total = 0, cached = 0, requested = 0, received = 0, failed = 0, built = 0, broken = 0 }))
        |> Task.andThen (\_ -> Utils.putMVar (\_ -> BE.bool True) mvar ())


{-| Runs `callback` with a key that writes each message to `chan` as `Just`,
and returns its result after writing the end-of-progress `Nothing`.
-}
runDetailsCallback : Chan (Maybe DMsg) -> (DKey -> Task Never a) -> Task Never a
runDetailsCallback chan callback =
    let
        encoder : Maybe DMsg -> Bytes.Encode.Encoder
        encoder =
            BE.maybe dMsgEncoder
    in
    callback (Key (Utils.writeChan encoder chan << Just))
        |> Task.andThen (signalDetailsComplete encoder chan)


{-| Writes the end-of-progress `Nothing` to `chan` and returns `answer`.
-}
signalDetailsComplete : (Maybe DMsg -> Bytes.Encode.Encoder) -> Chan (Maybe DMsg) -> a -> Task Never a
signalDetailsComplete encoder chan answer =
    Utils.writeChan encoder chan Nothing
        |> Task.map (\_ -> answer)


{-| Reads messages from `chan`, printing progress for each, until the
end-of-progress `Nothing`, and then prints the final line.
-}
detailsLoop : Chan (Maybe DMsg) -> DState -> Task Never ()
detailsLoop chan ((DState ds) as state) =
    Utils.readChan (BD.maybe dMsgDecoder) chan
        |> Task.andThen (handleDetailsMessage chan state ds.total ds.built)


{-| Applies one message read from `chan` and continues the loop, or, for the
end-of-progress `Nothing`, prints the final line from `total` and `built`.
-}
handleDetailsMessage : Chan (Maybe DMsg) -> DState -> Int -> Int -> Maybe DMsg -> Task Never ()
handleDetailsMessage chan state total built msg =
    case msg of
        Just dmsg ->
            detailsStep dmsg state
                |> Task.andThen (detailsLoop chan)

        Nothing ->
            printFinalDetailsStatus total built


{-| Prints the final dependency line over the progress line: "Dependencies
ready!" when `built` equals `total`, and "Dependency problem!" otherwise.
-}
printFinalDetailsStatus : Int -> Int -> Task Never ()
printFinalDetailsStatus total built =
    IO.printLn
        (clear (toBuildProgress total total)
            (if built == total then
                "Dependencies ready!"

             else
                "Dependency problem!"
            )
        )


{-| The counts the dependency progress worker keeps: the `total` number of
packages, and how many have been reported in each way so far.
-}
type alias DStateData =
    { total : Int
    , cached : Int
    , requested : Int
    , received : Int
    , failed : Int
    , built : Int
    , broken : Int
    }


{-| The state of the dependency progress worker.
-}
type DState
    = DState DStateData


{-| An event in getting dependencies ready: each package is found in the
cache or downloaded, and then built.

`DStart` carries the number of packages to be made ready. It sets the total
and resets every count.

`DCached` reports a package found without downloading it, and `DRequested` a
download started. The first `DRequested` prints "Starting downloads...".

`DReceived` and `DFailed` report a download that succeeded or failed, and name
the package and version, which are printed with a mark.

`DBuilt` and `DBroken` report a package that was built or failed to build.

-}
type DMsg
    = DStart Int
    | DCached
    | DRequested
    | DReceived Pkg.Name V.Version
    | DFailed Pkg.Name V.Version
    | DBuilt
    | DBroken


{-| Applies `msg` to the counts in the state, printing what it reports, and
returns the new state.
-}
detailsStep : DMsg -> DState -> Task Never DState
detailsStep msg (DState ds) =
    case msg of
        DStart numDependencies ->
            Task.succeed (DState { total = numDependencies, cached = 0, requested = 0, received = 0, failed = 0, built = 0, broken = 0 })

        DCached ->
            putTransition (DState { ds | cached = ds.cached + 1 })

        DRequested ->
            (if ds.requested == 0 then
                IO.printLn "Starting downloads...\n"

             else
                Task.succeed ()
            )
                |> Task.map (\_ -> DState { ds | requested = ds.requested + 1 })

        DReceived pkg vsn ->
            putDownload goodMark pkg vsn
                |> Task.andThen (\_ -> putTransition (DState { ds | received = ds.received + 1 }))

        DFailed pkg vsn ->
            putDownload badMark pkg vsn
                |> Task.andThen (\_ -> putTransition (DState { ds | failed = ds.failed + 1 }))

        DBuilt ->
            putBuilt (DState { ds | built = ds.built + 1 })

        DBroken ->
            putBuilt (DState { ds | broken = ds.broken + 1 })


{-| Prints one indented download line: `mark`, the package and the version.
-}
putDownload : D.Doc -> Pkg.Name -> V.Version -> Task Never ()
putDownload mark pkg vsn =
    Help.toStdout
        (D.indent 2
            (mark
                |> D.plus (D.fromPackage pkg)
                |> D.plus (D.fromVersion vsn)
                |> D.a (D.fromChars "\n")
            )
        )


{-| Prints the "Verifying dependencies" line once every package has been found
in the cache or downloaded, or failed to download, and returns `state`
unchanged.

The line starts on a new line if any download was reported, successful or
failed, so it follows the download lines, and otherwise overwrites the current
line.

-}
putTransition : DState -> Task Never DState
putTransition ((DState ds) as state) =
    if ds.cached + ds.received + ds.failed < ds.total then
        Task.succeed state

    else
        let
            char : Char
            char =
                if ds.received + ds.failed == 0 then
                    '\u{000D}'

                else
                    '\n'
        in
        putStrFlush (String.cons char (toBuildProgress (ds.built + ds.broken + ds.failed) ds.total))
            |> Task.map (\_ -> state)


{-| Redraws the "Verifying dependencies" line with the new count of finished
packages, once every package has been found in the cache or downloaded, or
failed to download, and returns `state` unchanged.
-}
putBuilt : DState -> Task Never DState
putBuilt ((DState ds) as state) =
    let
        completed : Int
        completed =
            ds.built + ds.broken + ds.failed
    in
    (if ds.total == ds.cached + ds.received + ds.failed then
        putStrFlush (String.cons '\u{000D}' (toBuildProgress completed ds.total))

     else
        Task.succeed ()
    )
        |> Task.map (\_ -> state)


{-| Returns the dependency progress line for `built` packages done out of
`total`.
-}
toBuildProgress : Int -> Int -> String
toBuildProgress built total =
    "Verifying dependencies (" ++ String.fromInt built ++ "/" ++ String.fromInt total ++ ")"


{-| Returns text that blanks out a line as long as `before` and then writes
`after` from the start of the line.
-}
clear : String -> String -> String
clear before after =
    String.cons '\u{000D}'
        (String.repeat (String.length before) " "
            ++ String.cons '\u{000D}' after
        )



-- ====== BUILD ======


{-| A key for reporting progress while modules are compiled.
-}
type alias BKey =
    Key BMsg


{-| The result of building a project: a value, or the problem that stopped
the build.
-}
type alias BResult a =
    Result Exit.BuildProblem a


{-| Runs `callback` with a key for compile progress, and returns its result.

In the terminal style a worker prints "Compiling ..." and then a count of the
`BDone` messages received. When `callback` finishes, the worker replaces it
with a final line: "Success!", with the number of modules compiled when any
were, or how many modules have problems, or "Detected a problem." for a problem with the project
as a whole. In the other styles the key discards every message.

The worker is sent only whether the build succeeded and the problem if it did
not, never the successful value itself.

-}
trackBuild : Style -> (BKey -> Task Never (BResult a)) -> Task Never (BResult a)
trackBuild style callback =
    case style of
        Silent ->
            callback (Key (\_ -> Task.succeed ()))

        Json ->
            callback (Key (\_ -> Task.succeed ()))

        Terminal mvar ->
            Utils.newChan Utils.mVarEncoder
                |> Task.andThen (trackBuildWithChan mvar callback)


{-| Starts the compile progress worker reading `chan`, runs `callback` with a
key that writes to `chan`, and then sends the worker the outcome.
-}
trackBuildWithChan : MVar () -> (BKey -> Task Never (BResult a)) -> Chan (Result BMsg (BResult ())) -> Task Never (BResult a)
trackBuildWithChan mvar callback chan =
    Utils.forkIO (runBuildWorker mvar chan)
        |> Task.andThen (\_ -> callback (Key (Utils.writeChan buildChanEncoder chan << Err)))
        |> Task.andThen (signalBuildComplete chan)


{-| Encodes a message on the compile progress channel: `Err` carries a
progress message and `Ok` the outcome that ends the progress.
-}
buildChanEncoder : Result BMsg (BResult ()) -> Bytes.Encode.Encoder
buildChanEncoder =
    BE.result bMsgEncoder (bResultEncoder BE.unit)


{-| Takes the terminal lock `mvar`, prints compile progress from `chan` until
the outcome arrives, then gives the lock back.
-}
runBuildWorker : MVar () -> Chan (Result BMsg (BResult ())) -> Task Never ()
runBuildWorker mvar chan =
    Utils.takeMVar (Bytes.Decode.succeed ()) mvar
        |> Task.andThen (\_ -> putStrFlush "Compiling ...")
        |> Task.andThen (\_ -> buildLoop chan 0)
        |> Task.andThen (\_ -> Utils.putMVar (\_ -> BE.bool True) mvar ())


{-| Sends the outcome of `result`, without its successful value, on `chan`, and
returns `result`.
-}
signalBuildComplete : Chan (Result BMsg (BResult ())) -> BResult a -> Task Never (BResult a)
signalBuildComplete chan result =
    Utils.writeChan buildChanEncoder chan (Ok (Result.map (\_ -> ()) result))
        |> Task.map (\_ -> result)


{-| An event while compiling modules. `BDone` reports one module compiled.
-}
type BMsg
    = BDone


{-| Reads messages from `chan`, where `done` modules have been reported
compiled so far, until the outcome arrives.
-}
buildLoop : Chan (Result BMsg (BResult ())) -> Int -> Task Never ()
buildLoop chan done =
    Utils.readChan (BD.result bMsgDecoder (bResultDecoder BD.unit)) chan
        |> Task.andThen (handleBuildMessage chan done)


{-| Redraws the count for a `BDone` and continues the loop, or prints the final
line for an outcome.
-}
handleBuildMessage : Chan (Result BMsg (BResult ())) -> Int -> Result BMsg (BResult ()) -> Task Never ()
handleBuildMessage chan done msg =
    case msg of
        Err BDone ->
            updateBuildProgress chan (done + 1)

        Ok result ->
            printFinalBuildMessage done result


{-| Redraws the "Compiling (done)" line and continues the loop.
-}
updateBuildProgress : Chan (Result BMsg (BResult ())) -> Int -> Task Never ()
updateBuildProgress chan done =
    putStrFlush ("\u{000D}Compiling (" ++ String.fromInt done ++ ")")
        |> Task.andThen (\_ -> buildLoop chan done)


{-| Prints the final compile line over the progress line, blanking out any part
of the progress line it would not cover.
-}
printFinalBuildMessage : Int -> BResult a -> Task Never ()
printFinalBuildMessage done result =
    let
        message : String
        message =
            toFinalMessage done result

        width : Int
        width =
            12 + String.length (String.fromInt done)
    in
    IO.printLn
        (if String.length message < width then
            String.cons '\u{000D}' (String.repeat width " ")
                ++ String.cons '\u{000D}' message

         else
            String.cons '\u{000D}' message
        )


{-| Returns the final compile line for `done` modules compiled and the outcome
`result`.
-}
toFinalMessage : Int -> BResult a -> String
toFinalMessage done result =
    case result of
        Ok _ ->
            case done of
                0 ->
                    "Success!"

                1 ->
                    "Success! Compiled 1 module."

                n ->
                    "Success! Compiled " ++ String.fromInt n ++ " modules."

        Err problem ->
            case problem of
                Exit.BuildBadModules _ _ [] ->
                    "Detected problems in 1 module."

                Exit.BuildBadModules _ _ (_ :: ps) ->
                    "Detected problems in " ++ String.fromInt (2 + List.length ps) ++ " modules."

                Exit.BuildProjectProblem _ ->
                    "Detected a problem."



-- ====== GENERATE ======


{-| Prints a diagram of the modules in `names` pointing to the file `output`
they were generated into, in the terminal style once no progress worker holds
the terminal lock. The other styles print nothing.
-}
reportGenerate : Style -> NE.Nonempty ModuleName.Raw -> String -> Task Never ()
reportGenerate style names output =
    case style of
        Silent ->
            Task.succeed ()

        Json ->
            Task.succeed ()

        Terminal mvar ->
            Utils.readMVar (Bytes.Decode.map (\_ -> ()) BD.bool) mvar
                |> Task.andThen (\_ -> printGenerateDiagram names output)


{-| Prints the generated-files diagram for `names` and `output`, after a blank
line.
-}
printGenerateDiagram : NE.Nonempty ModuleName.Raw -> String -> Task Never ()
printGenerateDiagram names output =
    let
        cnames : NE.Nonempty String
        cnames =
            NE.map (Name.toChars >> String.fromList) names
    in
    IO.printLn (String.cons '\n' (toGenDiagram cnames output))


{-| Returns the generated-files diagram: one line for a single module, or one
line per module joined by a bracket into an arrow to `output`.
-}
toGenDiagram : NE.Nonempty String -> String -> String
toGenDiagram (NE.Nonempty name names) output =
    let
        width : Int
        width =
            3 + List.foldr (String.length >> max) (String.length name) names
    in
    case names of
        [] ->
            toGenLine width name (String.cons '>' (String.cons ' ' output ++ "\n"))

        _ :: _ ->
            Utils.unlines
                (toGenLine width name (String.cons vtop (String.cons hbar (String.cons hbar (String.cons '>' (String.cons ' ' output)))))
                    :: List.reverse (List.map2 (toGenLine width) (List.reverse names) (String.fromChar vbottom :: List.repeat (List.length names - 1) (String.fromChar vmiddle)))
                )


{-| Returns one diagram line: `name`, a horizontal rule padding it to `width`,
and `end`.
-}
toGenLine : Int -> String -> String -> String
toGenLine width name end =
    "    "
        ++ name
        ++ String.cons ' ' (String.repeat (width - String.length name) (String.fromChar hbar))
        ++ end


{-| The horizontal line character of the generated-files diagram.
-}
hbar : Char
hbar =
    if isWindows then
        '-'

    else
        '─'


{-| The diagram character joining the first module's line to the bracket.
-}
vtop : Char
vtop =
    if isWindows then
        '+'

    else
        '┬'


{-| The diagram character joining a middle module's line to the bracket.
-}
vmiddle : Char
vmiddle =
    if isWindows then
        '+'

    else
        '┤'


{-| The diagram character joining the last module's line to the bracket.
-}
vbottom : Char
vbottom =
    if isWindows then
        '+'

    else
        '┘'



--


{-| Writes `str` to standard output and flushes it.
-}
putStrFlush : String -> Task Never ()
putStrFlush str =
    IO.write IO.stdout str
        |> Task.andThen (\_ -> IO.flush)



-- ====== ENCODERS and DECODERS ======


{-| Encodes a dependency progress message for the channel.
-}
dMsgEncoder : DMsg -> Bytes.Encode.Encoder
dMsgEncoder dMsg =
    case dMsg of
        DStart numDependencies ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.int numDependencies
                ]

        DCached ->
            Bytes.Encode.unsignedInt8 1

        DRequested ->
            Bytes.Encode.unsignedInt8 2

        DReceived pkg vsn ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Pkg.nameEncoder pkg
                , V.versionEncoder vsn
                ]

        DFailed pkg vsn ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Pkg.nameEncoder pkg
                , V.versionEncoder vsn
                ]

        DBuilt ->
            Bytes.Encode.unsignedInt8 5

        DBroken ->
            Bytes.Encode.unsignedInt8 6


{-| A decoder for a dependency progress message, as `dMsgEncoder` writes it.
-}
dMsgDecoder : Bytes.Decode.Decoder DMsg
dMsgDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map DStart BD.int

                    1 ->
                        Bytes.Decode.succeed DCached

                    2 ->
                        Bytes.Decode.succeed DRequested

                    3 ->
                        Bytes.Decode.map2 DReceived
                            Pkg.nameDecoder
                            V.versionDecoder

                    4 ->
                        Bytes.Decode.map2 DFailed
                            Pkg.nameDecoder
                            V.versionDecoder

                    5 ->
                        Bytes.Decode.succeed DBuilt

                    6 ->
                        Bytes.Decode.succeed DBroken

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a compile progress message for the channel.
-}
bMsgEncoder : BMsg -> Bytes.Encode.Encoder
bMsgEncoder _ =
    Bytes.Encode.unsignedInt8 0


{-| A decoder for a compile progress message, as `bMsgEncoder` writes it.
-}
bMsgDecoder : Bytes.Decode.Decoder BMsg
bMsgDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed BDone

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a build outcome, using `encoder` for its successful value.
-}
bResultEncoder : (a -> Bytes.Encode.Encoder) -> BResult a -> Bytes.Encode.Encoder
bResultEncoder encoder bResult =
    BE.result Exit.buildProblemEncoder encoder bResult


{-| Produces a decoder for a build outcome, using `decoder` for its successful
value.
-}
bResultDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (BResult a)
bResultDecoder decoder =
    BD.result Exit.buildProblemDecoder decoder
