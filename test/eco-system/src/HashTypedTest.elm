module HashTypedTest exposing (main)

{-| `Hash.hash` of a tuple or record is computed by the compiler's typed hash: an `eco.hash.mix` chain
over its fields, nested tuples and records unrolled, and every other field (a list, a custom type in
any representation, unit) handed to the walker resumed from the chain's state (`eco.hash.walk`,
plans/seq-data-structures-performance.md D2). It must give the number the runtime walker gives for
the same value, bounds included: `viaKernel` passes `Hash.hash` as a function value, which calls the
kernel and so the walker. `nested` mixes lists, tagged and nullary constructors, Maybe of a record and
records in tuples; `bounds` nests tuples past depth 16 and puts a 300-element list (which uses up the
walker's 256 items) before fields that must then be skipped; `hashed` hashes `Hash.Hashed` values on
their own and as fields, read inline from the object's stored hash (eco.hash and eco.hash.mix of kind
`hashed`), its last check a negative control. Every comparison must be `True`. On JavaScript both sides
are the JavaScript kernel.

-}

-- CHECK: tuples: [True,True,True,True,True,True]
-- CHECK: records: [True,True,True,True]
-- CHECK: built: [True,True]
-- CHECK: nested: [True,True,True,True,True,True,True]
-- CHECK: bounds: [True,True,True,True]
-- CHECK: hashed: [True,True,True,True,True]

import Hash exposing (hashed)
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


type Shape
    = Circle Float
    | Square Int
    | Empty
    | Named String Shape


type alias Inner =
    { label : String, shape : Shape, tags : List String }


deep : Int -> b -> ( Int, b )
deep n t =
    ( n, t )


viaKernel : a -> Int
viaKernel x =
    List.foldl (+) 0 (List.map Hash.hash [ x ])


report : () -> ()
report () =
    let
        negZero =
            -0.0

        _ =
            Debug.log "hashed"
                [ Hash.hash (hashed [ 1, 2, 3 ]) == viaKernel (hashed [ 1, 2, 3 ])
                , Hash.hash ( hashed "k", 1 ) == viaKernel ( hashed "k", 1 )
                , Hash.hash { k = hashed (Just 2.5), n = 3 } == viaKernel { k = hashed (Just 2.5), n = 3 }
                , Hash.hash ( 1, ( hashed [ 'a' ], hashed () ) ) == viaKernel ( 1, ( hashed [ 'a' ], hashed () ) )
                , Hash.hash ( hashed 1, 1 ) /= Hash.hash ( hashed 2, 1 )
                ]

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

        inner =
            { label = "in", shape = Named "n" (Circle 1.5), tags = [ "x", "y" ] }

        _ =
            Debug.log "nested"
                [ Hash.hash ( [ 1, 2, 3 ], "list" ) == viaKernel ( [ 1, 2, 3 ], "list" )
                , Hash.hash ( Square 4, Empty ) == viaKernel ( Square 4, Empty )
                , Hash.hash { a = inner, b = ( 1, inner ) } == viaKernel { a = inner, b = ( 1, inner ) }
                , Hash.hash ( Just inner, Nothing ) == viaKernel ( Just inner, Nothing )
                , Hash.hash ( ( 1, ( 2.5, 'c' ) ), { r = ( "s", [ Circle 0.0 ] ) } ) == viaKernel ( ( 1, ( 2.5, 'c' ) ), { r = ( "s", [ Circle 0.0 ] ) } )
                , Hash.hash ( (), [ () ] ) == viaKernel ( (), [ () ] )
                , List.all (\i -> Hash.hash ( i, { s = Square i, l = List.range 0 i } ) == viaKernel ( i, { s = Square i, l = List.range 0 i } )) (List.range 0 40)
                ]

        tower =
            deep 1 (deep 2 (deep 3 (deep 4 (deep 5 (deep 6 (deep 7 (deep 8 (deep 9 (deep 10 (deep 11 (deep 12 (deep 13 (deep 14 (deep 15 (deep 16 (deep 17 ( 18, "bottom" )))))))))))))))))

        long =
            List.range 1 300

        _ =
            Debug.log "bounds"
                [ Hash.hash tower == viaKernel tower
                , Hash.hash { a = long, b = 7, c = ( 1, 2 ) } == viaKernel { a = long, b = 7, c = ( 1, 2 ) }
                , Hash.hash ( long, { b = 7, c = "x" } ) == viaKernel ( long, { b = 7, c = "x" } )
                , Hash.hash { a = List.range 1 255, b = 7, c = 8 } == viaKernel { a = List.range 1 255, b = 7, c = 8 }
                ]
    in
    ()
