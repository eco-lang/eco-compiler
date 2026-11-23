module HashIdentityGenericTest exposing (main)

{-| HashIdentityTest.elm's program with ECO_HASH_INLINE=0: every `eco.hash` calls the runtime walker
instead of computing an Int, Float, Char or Bool hash inline. Its CHECK lines must stay identical to
HashIdentityTest.elm's.

-}

-- SKIP-JS: the JavaScript hash gives other numbers
-- CHECK: ints: [1766246582,3422327743,2079506285,683080085,948621581,2379943564]
-- CHECK: floats: [1251439042,1251439042,593676089,2902364805,2409162822]
-- CHECK: chars: [2277228005,583401031,2642981514]
-- CHECK: bools: [311195553,601926293]
-- CHECK: strings: [92598572,991678686,618780984,3719206139]
-- CHECK: values: [3633460323,866040821,3732251940,2612630852,2240964614]
-- ENV: ECO_HASH_INLINE=0
import Hash
import System
import Task


type Shape
    = Dot
    | Circle Float
    | Box { w : Int, h : Int }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            Debug.log "ints" ([ Hash.hash (0), Hash.hash (1), Hash.hash (-1), Hash.hash ((2 ^ 62 - 1) * 2 + 1), Hash.hash (-((2 ^ 62 - 1) * 2 + 1)), Hash.hash (123456789) ])

        _ =
            Debug.log "floats" ([ Hash.hash (0.0), Hash.hash (-0.0), Hash.hash (1.5), Hash.hash (1 / 0), Hash.hash (-2.25e300) ])

        _ =
            Debug.log "chars" ([ Hash.hash ('a'), Hash.hash ('\u{0000}'), Hash.hash ('\u{10FFFF}') ])

        _ =
            Debug.log "bools" ([ Hash.hash (True), Hash.hash (False) ])

        _ =
            Debug.log "strings" ([ Hash.hash (""), Hash.hash ("a"), Hash.hash ("hello world"), Hash.hash (String.repeat 5000 "xy") ])

        _ =
            Debug.log "values"
                [ Hash.hash ( 1, "a" )
                , Hash.hash { w = 1, h = 2 }
                , Hash.hash [ Dot, Circle 2.5, Box { w = 3, h = 4 } ]
                , Hash.hash (Just ( 1.5, 'c' ))
                , Hash.hash [ [ 1, 2 ], [ 3 ] ]
                ]
    in
    ()
