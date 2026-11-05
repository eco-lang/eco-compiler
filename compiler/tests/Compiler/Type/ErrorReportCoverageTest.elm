module Compiler.Type.ErrorReportCoverageTest exposing (suite)

{-| Checks that a module's type errors survive the binary form a build caches
them in: encoded as a `Compiler.Error.BadTypes` with the module's localizer
(`Compiler.Error.errorEncoder`) and decoded again (`errorDecoder`), they must
render to the same reports.

The programs are those of `SourceIR.TypeCheckFailsCases`, every one of which
fails type checking, so the round trip runs over every kind of type error
report that catalogue holds: mismatches of each category and context, the
problems of the type diff, the operators, type variables, records, patterns,
infinite types and the printing of types. Which report each program must get
is checked by `TestLogic.Reporting.ExpectedRejectionTest`, which those
programs' cases record it for.

Each program is canonicalized against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces` and type checked along the erased
path that `Compiler.Compile.typeCheck` takes, so that path's solver
(`Compiler.Type.Solve.run`) runs on every one; the native build's typed path
is what `ExpectedRejectionTest` runs. A program that canonicalizes with an
error, or type checks, fails. The reports are rendered by
`Compiler.Type.Error.toReport`; a program has no source text, so they quote
blank lines.

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Error as E
import Compiler.IR.Source as Src
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Report as Report
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Error as TypeError
import Compiler.Type.Solve as Solve
import Compiler.Type.State.IO as IO
import Data.NonEmptyList as NE
import Expect exposing (Expectation)
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)


{-| The round trip over every program of `SourceIR.TypeCheckFailsCases`, under
a label that contains "coverage run" so that the coverage loop's quick run
includes it.
-}
suite : Test
suite =
    Test.describe "Type error reports (coverage run)"
        [ TypeCheckFailsCases.expectSuite expectRoundTrip "render the same after a round trip" ]


{-| Passes when `srcModule` fails type checking and its errors render the same
after the round trip.
-}
expectRoundTrip : Src.Module -> Expectation
expectRoundTrip srcModule =
    case typeErrors srcModule of
        Err message ->
            Expect.fail message

        Ok ( localizer, errors ) ->
            let
                source =
                    blankSource srcModule
            in
            Expect.equal (List.map (render source localizer) (NE.toList errors))
                (roundTrip source localizer errors)


{-| Canonicalizes and type checks `srcModule` along the erased path, giving the
module's localizer and its type errors, or a message saying which step did not
go as a program of the catalogue requires.
-}
typeErrors : Src.Module -> Result String ( Localizer.Localizer, NE.Nonempty TypeError.Error )
typeErrors srcModule =
    case RResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        Err _ ->
            Err "the program does not canonicalize"

        Ok canonical ->
            case IO.unsafePerformIO (TypeErased.constrain canonical |> IO.andThen Solve.run) of
                Ok _ ->
                    Err "the program type checks"

                Err errors ->
                    Ok ( Localizer.fromModule srcModule, errors )


{-| The title and rendered message of the report for `error`, quoting `source`.
-}
render : Code.Source -> Localizer.Localizer -> TypeError.Error -> String
render source localizer error =
    let
        (Report.Report props) =
            TypeError.toReport source localizer error
    in
    props.title ++ "\n" ++ D.toString props.doc


{-| Blank lines standing in for the source text of `srcModule`, one more than
the last row its values, custom types and aliases reach, so that every region a
report quotes is within it.
-}
blankSource : Src.Module -> Code.Source
blankSource (Src.Module data) =
    let
        endRow (A.At (A.Region _ (A.Position row _)) _) =
            row

        lastRow =
            List.maximum
                (List.map endRow data.values
                    ++ List.map endRow data.unions
                    ++ List.map endRow data.aliases
                )
                |> Maybe.withDefault 0
    in
    Code.toSource (String.repeat (lastRow + 1) "\n")


{-| The rendered reports of `errors` after they and `localizer` have been
encoded as a `Compiler.Error.BadTypes` and decoded again, or a one-message list
saying the decoding failed or gave another kind of error.
-}
roundTrip : Code.Source -> Localizer.Localizer -> NE.Nonempty TypeError.Error -> List String
roundTrip source localizer errors =
    let
        bytes =
            Bytes.Encode.encode (E.errorEncoder (E.BadTypes localizer errors))
    in
    case Bytes.Decode.decode E.errorDecoder bytes of
        Just (E.BadTypes decodedLocalizer decodedErrors) ->
            List.map (render source decodedLocalizer) (NE.toList decodedErrors)

        Just _ ->
            [ "decoded to another kind of error" ]

        Nothing ->
            [ "did not decode" ]
