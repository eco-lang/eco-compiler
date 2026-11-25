module HashDeepTest exposing (main)

{-| A `Hashed` nested in a value contributes its stored hash (plans/hashed-values-and-hash-consing.md
§2.1): two `Hashed` of equal values make equal containers, `Hashed` of different values make different
ones, and a container of a `Hashed` differs from the container of its plain value. Large values (a
100,000-element list, a 100,000-deep chain) hash, and twice to the same number.

-}

-- CHECK: big: [True,True]
-- CHECK: nested: [True,True,True]

import Hash exposing (hashed)
import System
import Task


type Chain
    = End
    | Link Int Chain


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


chain : Int -> Chain
chain n =
    List.foldl Link End (List.range 1 n)


report : () -> ()
report () =
    let
        long1 =
            List.range 1 300

        long2 =
            0 :: List.range 2 300

        _ =
            Debug.log "big"
                [ Hash.hash (List.range 1 100000) == Hash.hash (List.range 1 100000)
                , Hash.hash (chain 100000) == Hash.hash (chain 100000)
                ]

        _ =
            Debug.log "nested"
                [ Hash.hash ( hashed long1, 1 ) == Hash.hash ( hashed (List.range 1 300), 1 )
                , Hash.hash ( hashed long1, 1 ) /= Hash.hash ( long1, 1 )
                , Hash.hash ( hashed long1, 1 ) /= Hash.hash ( hashed long2, 1 )
                ]
    in
    ()
