module Builder.Reporting exposing
    ( BKey
    , BMsg(..)
    , DKey
    , DMsg(..)
    , Key
    , Style
    , ask
    , attempt
    , attemptWithStyle
    , ignorer
    , json
    , report
    , reportGenerate
    , silent
    , terminal
    , trackBuild
    , trackDetails
    )

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
import System.IO as IO
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (Chan, MVar)
import Utils.Task.Extra as Task



-- STYLE


type Style
    = Silent
    | Json
    | Terminal (MVar ())


silent : Style
silent =
    Silent


json : Style
json =
    Json


terminal : Task Never Style
terminal =
    Task.map Terminal (Utils.newMVar (\_ -> BE.bool True) ())



-- ATTEMPT


attempt : (x -> Help.Report) -> Task Never (Result x a) -> Task Never a
attempt toReport work =
    work
        -- |> IO.catch reportExceptionsNicely
        |> Task.andThen (handleAttemptResult toReport)


handleAttemptResult : (x -> Help.Report) -> Result x a -> Task Never a
handleAttemptResult toReport result =
    case result of
        Ok a ->
            Task.succeed a

        Err x ->
            reportErrorAndExit (toReport x)


reportErrorAndExit : Help.Report -> Task Never a
reportErrorAndExit helpReport =
    Exit.toStderr helpReport
        |> Task.andThen (\_ -> Exit.exitFailure)


attemptWithStyle : Style -> (x -> Help.Report) -> Task Never (Result x a) -> Task Never a
attemptWithStyle style toReport work =
    work
        -- |> IO.catch reportExceptionsNicely
        |> Task.andThen (handleStyledResult style toReport)


handleStyledResult : Style -> (x -> Help.Report) -> Result x a -> Task Never a
handleStyledResult style toReport result =
    case result of
        Ok a ->
            Task.succeed a

        Err x ->
            exitWithError style (toReport x)


exitWithError : Style -> Help.Report -> Task Never a
exitWithError style helpReport =
    case style of
        Silent ->
            Exit.exitFailure

        Json ->
            exitWithJsonError helpReport

        Terminal mvar ->
            exitWithTerminalError mvar helpReport


exitWithJsonError : Help.Report -> Task Never a
exitWithJsonError helpReport =
    Utils.builderHPutBuilder IO.stderr (Encode.encodeUgly (Exit.toJson helpReport))
        |> Task.andThen (\_ -> Exit.exitFailure)


exitWithTerminalError : MVar () -> Help.Report -> Task Never a
exitWithTerminalError mvar helpReport =
    Utils.readMVar (Bytes.Decode.map (\_ -> ()) BD.bool) mvar
        |> Task.andThen (\_ -> Exit.toStderr helpReport)
        |> Task.andThen (\_ -> Exit.exitFailure)



-- MARKS


goodMark : D.Doc
goodMark =
    D.green
        (if isWindows then
            D.fromChars "+"

         else
            D.fromChars "●"
        )


badMark : D.Doc
badMark =
    D.red
        (if isWindows then
            D.fromChars "X"

         else
            D.fromChars "✗"
        )


isWindows : Bool
isWindows =
    -- TODO Info.os == "mingw32"
    False



-- KEY


type Key msg
    = Key (msg -> Task Never ())


report : Key msg -> msg -> Task Never ()
report (Key send) msg =
    send msg


ignorer : Key msg
ignorer =
    Key (\_ -> Task.succeed ())



-- ASK


ask : D.Doc -> Task Never Bool
ask doc =
    Help.toStdout doc
        |> Task.andThen (\_ -> askHelp)


askHelp : Task Never Bool
askHelp =
    IO.hFlush IO.stdout
        |> Task.andThen (\_ -> IO.getLine)
        |> Task.andThen parseYesNoResponse


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


promptAndRetry : Task Never Bool
promptAndRetry =
    IO.putStr "Must type 'y' for yes or 'n' for no: "
        |> Task.andThen (\_ -> askHelp)



-- DETAILS


type alias DKey =
    Key DMsg


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


trackDetailsWithChan : MVar () -> (DKey -> Task Never a) -> Chan (Maybe DMsg) -> Task Never a
trackDetailsWithChan mvar callback chan =
    Utils.forkIO (runDetailsWorker mvar chan)
        |> Task.andThen (\_ -> runDetailsCallback chan callback)


runDetailsWorker : MVar () -> Chan (Maybe DMsg) -> Task Never ()
runDetailsWorker mvar chan =
    Utils.takeMVar (Bytes.Decode.succeed ()) mvar
        |> Task.andThen (\_ -> detailsLoop chan (DState { total = 0, cached = 0, requested = 0, received = 0, failed = 0, built = 0, broken = 0 }))
        |> Task.andThen (\_ -> Utils.putMVar (\_ -> BE.bool True) mvar ())


runDetailsCallback : Chan (Maybe DMsg) -> (DKey -> Task Never a) -> Task Never a
runDetailsCallback chan callback =
    let
        encoder : Maybe DMsg -> Bytes.Encode.Encoder
        encoder =
            BE.maybe dMsgEncoder
    in
    callback (Key (Utils.writeChan encoder chan << Just))
        |> Task.andThen (signalDetailsComplete encoder chan)


signalDetailsComplete : (Maybe DMsg -> Bytes.Encode.Encoder) -> Chan (Maybe DMsg) -> a -> Task Never a
signalDetailsComplete encoder chan answer =
    Utils.writeChan encoder chan Nothing
        |> Task.map (\_ -> answer)


detailsLoop : Chan (Maybe DMsg) -> DState -> Task Never ()
detailsLoop chan ((DState ds) as state) =
    Utils.readChan (BD.maybe dMsgDecoder) chan
        |> Task.andThen (handleDetailsMessage chan state ds.total ds.built)


handleDetailsMessage : Chan (Maybe DMsg) -> DState -> Int -> Int -> Maybe DMsg -> Task Never ()
handleDetailsMessage chan state total built msg =
    case msg of
        Just dmsg ->
            detailsStep dmsg state
                |> Task.andThen (detailsLoop chan)

        Nothing ->
            printFinalDetailsStatus total built


printFinalDetailsStatus : Int -> Int -> Task Never ()
printFinalDetailsStatus total built =
    IO.putStrLn
        (clear (toBuildProgress total total)
            (if built == total then
                "Dependencies ready!"

             else
                "Dependency problem!"
            )
        )


type alias DStateData =
    { total : Int
    , cached : Int
    , requested : Int
    , received : Int
    , failed : Int
    , built : Int
    , broken : Int
    }


type DState
    = DState DStateData


type DMsg
    = DStart Int
    | DCached
    | DRequested
    | DReceived Pkg.Name V.Version
    | DFailed Pkg.Name V.Version
    | DBuilt
    | DBroken


detailsStep : DMsg -> DState -> Task Never DState
detailsStep msg (DState ds) =
    case msg of
        DStart numDependencies ->
            Task.succeed (DState { total = numDependencies, cached = 0, requested = 0, received = 0, failed = 0, built = 0, broken = 0 })

        DCached ->
            putTransition (DState { ds | cached = ds.cached + 1 })

        DRequested ->
            (if ds.requested == 0 then
                IO.putStrLn "Starting downloads...\n"

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


putBuilt : DState -> Task Never DState
putBuilt ((DState ds) as state) =
    (if ds.total == ds.cached + ds.received + ds.failed then
        putStrFlush (String.cons '\u{000D}' (toBuildProgress (ds.built + ds.broken + ds.failed) ds.total))

     else
        Task.succeed ()
    )
        |> Task.map (\_ -> state)


toBuildProgress : Int -> Int -> String
toBuildProgress built total =
    "Verifying dependencies (" ++ String.fromInt built ++ "/" ++ String.fromInt total ++ ")"


clear : String -> String -> String
clear before after =
    String.cons '\u{000D}'
        (String.repeat (String.length before) " "
            ++ String.cons '\u{000D}' after
        )



-- BUILD


type alias BKey =
    Key BMsg


type alias BResult a =
    Result Exit.BuildProblem a


trackBuild : Bytes.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> Style -> (BKey -> Task Never (BResult a)) -> Task Never (BResult a)
trackBuild decoder encoder style callback =
    case style of
        Silent ->
            callback (Key (\_ -> Task.succeed ()))

        Json ->
            callback (Key (\_ -> Task.succeed ()))

        Terminal mvar ->
            Utils.newChan Utils.mVarEncoder
                |> Task.andThen (trackBuildWithChan decoder encoder mvar callback)


trackBuildWithChan : Bytes.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> MVar () -> (BKey -> Task Never (BResult a)) -> Chan (Result BMsg (BResult a)) -> Task Never (BResult a)
trackBuildWithChan decoder encoder mvar callback chan =
    let
        chanEncoder : Result BMsg (BResult a) -> Bytes.Encode.Encoder
        chanEncoder =
            BE.result bMsgEncoder (bResultEncoder encoder)
    in
    Utils.forkIO (runBuildWorker decoder mvar chan)
        |> Task.andThen (\_ -> callback (Key (Utils.writeChan chanEncoder chan << Err)))
        |> Task.andThen (signalBuildComplete chanEncoder chan)


runBuildWorker : Bytes.Decode.Decoder a -> MVar () -> Chan (Result BMsg (BResult a)) -> Task Never ()
runBuildWorker decoder mvar chan =
    Utils.takeMVar (Bytes.Decode.succeed ()) mvar
        |> Task.andThen (\_ -> putStrFlush "Compiling ...")
        |> Task.andThen (\_ -> buildLoop decoder chan 0)
        |> Task.andThen (\_ -> Utils.putMVar (\_ -> BE.bool True) mvar ())


signalBuildComplete : (Result BMsg (BResult a) -> Bytes.Encode.Encoder) -> Chan (Result BMsg (BResult a)) -> BResult a -> Task Never (BResult a)
signalBuildComplete chanEncoder chan result =
    Utils.writeChan chanEncoder chan (Ok result)
        |> Task.map (\_ -> result)


type BMsg
    = BDone


buildLoop : Bytes.Decode.Decoder a -> Chan (Result BMsg (BResult a)) -> Int -> Task Never ()
buildLoop decoder chan done =
    Utils.readChan (BD.result bMsgDecoder (bResultDecoder decoder)) chan
        |> Task.andThen (handleBuildMessage decoder chan done)


handleBuildMessage : Bytes.Decode.Decoder a -> Chan (Result BMsg (BResult a)) -> Int -> Result BMsg (BResult a) -> Task Never ()
handleBuildMessage decoder chan done msg =
    case msg of
        Err BDone ->
            updateBuildProgress decoder chan (done + 1)

        Ok result ->
            printFinalBuildMessage done result


updateBuildProgress : Bytes.Decode.Decoder a -> Chan (Result BMsg (BResult a)) -> Int -> Task Never ()
updateBuildProgress decoder chan done =
    putStrFlush ("\u{000D}Compiling (" ++ String.fromInt done ++ ")")
        |> Task.andThen (\_ -> buildLoop decoder chan done)


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
    IO.putStrLn
        (if String.length message < width then
            String.cons '\u{000D}' (String.repeat width " ")
                ++ String.cons '\u{000D}' message

         else
            String.cons '\u{000D}' message
        )


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



-- GENERATE


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


printGenerateDiagram : NE.Nonempty ModuleName.Raw -> String -> Task Never ()
printGenerateDiagram names output =
    let
        cnames : NE.Nonempty String
        cnames =
            NE.map (Name.toChars >> String.fromList) names
    in
    IO.putStrLn (String.cons '\n' (toGenDiagram cnames output))


toGenDiagram : NE.Nonempty String -> String -> String
toGenDiagram (NE.Nonempty name names) output =
    let
        width : Int
        width =
            3 + List.foldr (max << String.length) (String.length name) names
    in
    case names of
        [] ->
            toGenLine width name (String.cons '>' (String.cons ' ' output ++ "\n"))

        _ :: _ ->
            Utils.unlines
                (toGenLine width name (String.cons vtop (String.cons hbar (String.cons hbar (String.cons '>' (String.cons ' ' output)))))
                    :: List.reverse (List.map2 (toGenLine width) (List.reverse names) (String.fromChar vbottom :: List.repeat (List.length names - 1) (String.fromChar vmiddle)))
                )


toGenLine : Int -> String -> String -> String
toGenLine width name end =
    "    "
        ++ name
        ++ String.cons ' ' (String.repeat (width - String.length name) (String.fromChar hbar))
        ++ end


hbar : Char
hbar =
    if isWindows then
        '-'

    else
        '─'


vtop : Char
vtop =
    if isWindows then
        '+'

    else
        '┬'


vmiddle : Char
vmiddle =
    if isWindows then
        '+'

    else
        '┤'


vbottom : Char
vbottom =
    if isWindows then
        '+'

    else
        '┘'



--


putStrFlush : String -> Task Never ()
putStrFlush str =
    IO.hPutStr IO.stdout str
        |> Task.andThen (\_ -> IO.hFlush IO.stdout)



-- ENCODERS and DECODERS


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


bMsgEncoder : BMsg -> Bytes.Encode.Encoder
bMsgEncoder _ =
    Bytes.Encode.unsignedInt8 0


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


bResultEncoder : (a -> Bytes.Encode.Encoder) -> BResult a -> Bytes.Encode.Encoder
bResultEncoder encoder bResult =
    BE.result Exit.buildProblemEncoder encoder bResult


bResultDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (BResult a)
bResultDecoder decoder =
    BD.result Exit.buildProblemDecoder decoder
