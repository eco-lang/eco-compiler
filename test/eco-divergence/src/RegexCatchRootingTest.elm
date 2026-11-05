module RegexCatchRootingTest exposing (main)

{-| REGEX-03 (plans/kernel-lib-bug-fixes.md), E2E variant: when srell throws part-way through
`Regex.replace` / `Regex.split` (here: its backtracking budget runs out on `(a+)+b` against a run
of 'a's with no 'b'), the native kernels' error path returns the subject string. Before the fix
it returned the word the subject was passed as, which was not rooted, and the replacer
(allocating heavily) and the parts' allocations run minor GCs before the throw, so that word
could name the pre-GC copy. The subject is built
at run time so it lives in the nursery. Expected (eco-only behaviour): both return the subject
unchanged. Native-only: JavaScript backtracks for a very long time instead of failing.

A stale nursery word may still read correctly without a heap-validate build, so this test is a
weaker guard than the unit tests in test/kernel/RegexKernelTest.cpp.

-}

-- DIVERGENCE: eco's regex engine fails (a+)+b fast; JavaScript backtracks on it for minutes
-- CHECK: replace len: 130
-- CHECK: replace head: "x,x,x,"
-- CHECK: split parts: 1
-- CHECK: split len: 130
-- CHECK: split head: "x,x,x,"

import Html exposing (text)
import Regex


subject : () -> String
subject () =
    String.repeat 50 "x," ++ String.repeat 30 "a"


main =
    let
        re =
            Maybe.withDefault Regex.never (Regex.fromString ",|(a+)+b")

        replaced =
            Regex.replace re (\_ -> String.fromInt (List.sum (List.range 0 20000))) (subject ())

        parts =
            Regex.split re (subject ())

        first =
            Maybe.withDefault "" (List.head parts)

        _ =
            Debug.log "replace len" (String.length replaced)

        _ =
            Debug.log "replace head" (String.left 6 replaced)

        _ =
            Debug.log "split parts" (List.length parts)

        _ =
            Debug.log "split len" (String.length first)

        _ =
            Debug.log "split head" (String.left 6 first)
    in
    text "done"
