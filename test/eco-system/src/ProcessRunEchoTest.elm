module ProcessRunEchoTest exposing (main)

{-| `System.Process.run` (plans/eco-system-library.md Phase 5 step 5.4): the
child's stdout comes back as Bytes, with the default shell and without one.
-}

-- CHECK: shell: ok stdout=hi| stderr=
-- CHECK: noshell: ok stdout=a b| stderr=
-- CHECK: both: ok stdout=out| stderr=err|
-- CHECK: binary: ok stdout=0123456789 stderr=
-- EXIT: 0

import ProcessTestHelp exposing (describeRun, noShell, simpleRun)
import System.Process as P


main =
    simpleRun
        [ ( "shell", describeRun (P.run "echo" [ "hi" ] P.defaultRunOptions) )
        , ( "noshell", describeRun (P.run "echo" [ "a b" ] noShell) )
        , ( "both", describeRun (P.run "sh" [ "-c", "echo out; echo err >&2" ] noShell) )
        , ( "binary", describeRun (P.run "printf" [ "0123456789" ] noShell) )
        ]
