module HashTypedTest exposing (main)

{-| `Hash.hash` of a tuple or record whose fields are Int, Float, Char, Bool or String is computed by
the compiler's typed hash (an `eco.hash.mix` chain, plans/seq-data-structures-performance.md D2). It
must give the number the runtime walker gives for the same value: `viaKernel` passes `Hash.hash` as a
function value, which calls the kernel and so the walker. Every comparison must be `True`. On
JavaScript both sides are the JavaScript kernel.

-}

-- CHECK: tuples: [True,True,True,True,True,True]
-- CHECK: records: [True,True,True,True]
-- CHECK: built: [True,True]

import Hash
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


viaKernel : a -> Int
viaKernel x =
    List.foldl (+) 0 (List.map Hash.hash [ x ])


report : () -> ()
report () =
    let
        negZero =
            -0.0

        _ =
            Debug.log "tuples"
                [ Hash.hash ( 1, 2 ) == viaKernel ( 1, 2 )
                , Hash.hash ( -7, "seven" ) == viaKernel ( -7, "seven" )
                , Hash.hash ( 2.5, 'x', True ) == viaKernel ( 2.5, 'x', True )
                , Hash.hash ( negZero, "" ) == viaKernel ( 0.0, "" )
                , Hash.hash ( "a", String.repeat 5000 "b" ) == viaKernel ( "a", String.repeat 5000 "b" )
                , Hash.hash ( False, 'z' ) == viaKernel ( False, 'z' )
                ]

        _ =
            Debug.log "records"
                [ Hash.hash { a = 1, b = "two", c = True } == viaKernel { a = 1, b = "two", c = True }
                , Hash.hash { x = 1.5, y = -2.5 } == viaKernel { x = 1.5, y = -2.5 }
                , Hash.hash { name = "", code = 'q', count = 0 } == viaKernel { name = "", code = 'q', count = 0 }
                , Hash.hash { only = 42 } == viaKernel { only = 42 }
                ]

        pairs =
            List.map (\i -> ( i, String.fromInt i )) (List.range 1 100)

        _ =
            Debug.log "built"
                [ List.all (\p -> Hash.hash p == viaKernel p) pairs
                , List.all (\i -> Hash.hash { k = i, s = String.fromInt i } == viaKernel { k = i, s = String.fromInt i }) (List.range 1 100)
                ]
    in
    ()
