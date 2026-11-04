module TestLogic.Canonicalize.NameClashes exposing (expectNameClashesRejected)

{-| The name-clash oracle (CANON\_003): canonicalization rejects a program with
a `NAME CLASH` or `SHADOWING` report exactly when the program, read directly,
binds a name twice.

`TestLogic.Canonicalize.SourceFacts.nameClashes` reads the clashes from the
program. `expectNameClashesRejected` runs the program through canonicalization
(`TestLogic.TestPipeline.runToReportsThrough Canonicalize`, with the production
reporters) and compares:

  - when the program has a clash, canonicalization must reject it, and one
    report must have the title of one such clash and name it: a `NAME CLASH`
    report quotes the name between backquotes. A `SHADOWING` report names it
    only when the two bindings are on different lines; one whose bindings
    share a line (as every binding of a `Compiler.AST.SourceBuilder` program
    does, all at one region) says only "These variables cannot have the same
    name", which is then accepted for any name;
  - otherwise, no report may have the title `NAME CLASH` or `SHADOWING`. The
    program may still be rejected for something else.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import TestLogic.Canonicalize.SourceFacts as SourceFacts
import TestLogic.TestPipeline as Pipeline exposing (Outcome(..), Stage(..))


{-| Returns an expectation that canonicalization rejects `program` for the names
it binds twice exactly as `SourceFacts.nameClashes` predicts.
-}
expectNameClashesRejected : Src.Module -> Expectation
expectNameClashesRejected program =
    let
        clashes =
            SourceFacts.nameClashes program
    in
    case ( Pipeline.runToReportsThrough Canonicalize program, clashes ) of
        ( Accepted, [] ) ->
            Expect.pass

        ( Accepted, _ ) ->
            Expect.fail ("canonicalization accepted a program that binds names twice: " ++ describe clashes)

        ( Rejected reports, [] ) ->
            if List.any (\t -> t == "NAME CLASH" || t == "SHADOWING") reports.titles then
                Expect.fail ("a program that binds no name twice got a name-clash report:\n" ++ reports.text)

            else
                Expect.pass

        ( Rejected reports, _ ) ->
            if List.any (reported reports) clashes then
                Expect.pass

            else
                Expect.fail
                    ("expected a report for one of "
                        ++ describe clashes
                        ++ ", but "
                        ++ Pipeline.stageName reports.stage
                        ++ " reported:\n"
                        ++ reports.text
                    )


{-| Whether `reports` hold a report for `clash`, as the module docstring
describes.
-}
reported : Pipeline.Reports -> SourceFacts.Clash -> Bool
reported reports clash =
    List.member clash.title reports.titles
        && (if clash.title == "SHADOWING" then
                String.contains ("The name `" ++ clash.name ++ "`") reports.text
                    || String.contains "These variables cannot have the same name" reports.text

            else
                String.contains ("`" ++ clash.name ++ "`") reports.text
           )


describe : List SourceFacts.Clash -> String
describe clashes =
    String.join ", " (List.map (\c -> c.title ++ " `" ++ c.name ++ "`") clashes)
