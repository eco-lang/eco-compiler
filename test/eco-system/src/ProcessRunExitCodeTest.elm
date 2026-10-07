module ProcessRunExitCodeTest exposing (main)

{-| A non-zero exit is a `ProgramError` with the exit code and the output so
far (plans/eco-system-library.md Phase 5 step 5.4, E.4); a program killed by
a signal reports -1, as node does.
-}

-- CHECK: exit3: ProgramError 3 stdout= stderr=
-- CHECK: noshell: ProgramError 3 stdout=out| stderr=err|
-- CHECK: notfound-in-shell: ProgramError 127
-- CHECK: signalled: ProgramError -1
-- EXIT: 0

import ProcessTestHelp exposing (describeRun, noShell, simpleRun)
import System.Process as P


main =
    simpleRun
        [ ( "exit3", describeRun (P.run "exit" [ "3" ] P.defaultRunOptions) )
        , ( "noshell", describeRun (P.run "sh" [ "-c", "echo out; echo err >&2; exit 3" ] noShell) )
        , ( "notfound-in-shell", describeRun (P.run "eco-no-such-program-p5" [] P.defaultRunOptions) )
        , ( "signalled", describeRun (P.run "sh" [ "-c", "kill -KILL $$" ] noShell) )
        ]
