module HashedTest exposing (main)

{-| eco/system's `Hash.Hashed` (plans/hashed-values-and-hash-consing.md): `hashOf` is `Hash.hash` of the
value, a `Hashed` hashes as its value does, `value` gives the value back (an Int, Float or Char
unboxed from it), `==` on two `Hashed` is `==` on their values (NaN included: built through different
routes, so that no identical-object shortcut answers), and `Debug.toString` and `Debug.log` print the
value alone. The same on both backends.

-}

-- CHECK: hashOf: [True,True,True,True,True,True]
-- CHECK: transparent: [True,True,True,True,True,True]
-- CHECK: value: [True,True]
-- CHECK: unboxed: [True,True,True,True]
-- CHECK: equality: [True,True,True]
-- CHECK: nan: False
-- CHECK: toString: [True,True,True]
-- CHECK: show1: 1
-- CHECK: show2: "s"
-- CHECK: show3: Just (Box { h = 2, w = 1 })
-- CHECK: show4: [(1,'c')]
-- CHECK: show5: { k = [1] }

import Hash exposing (Hashed, hashOf, hashed, value)
import System
import Task


type Shape
    = Dot
    | Circle Float
    | Box { w : Int, h : Int }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


hashOfIsHash : a -> Bool
hashOfIsHash x =
    hashOf (hashed x) == Hash.hash x


transparent : a -> Bool
transparent x =
    Hash.hash (hashed x) == Hash.hash x


report : () -> ()
report () =
    let
        zero =
            toFloat (List.length [])

        nan1 =
            zero / zero

        nan2 =
            sqrt (zero - 1)

        listA =
            List.range 1 3

        listB =
            [ 1, 2, 3 ]

        _ =
            Debug.log "hashOf"
                [ hashOfIsHash 42
                , hashOfIsHash "a string of more than thirty-two units, so it has a slot"
                , hashOfIsHash ( 1, "a" )
                , hashOfIsHash listA
                , hashOfIsHash (Box { w = 1, h = 2 })
                , hashOfIsHash (Circle 2.5)
                ]

        _ =
            Debug.log "transparent"
                [ transparent 42
                , transparent "s"
                , transparent ( 1, "a" )
                , transparent listA
                , transparent (Box { w = 1, h = 2 })
                , transparent Dot
                ]

        _ =
            Debug.log "value" [ value (hashed listA) == listA, value (hashed "s") == "s" ]

        _ =
            Debug.log "unboxed"
                [ value (hashed 42) + 1 == 43
                , value (hashed 2.5) * 2 == 5
                , Char.toCode (value (hashed 'a')) == 97
                , hashOf (hashed 7) == Hash.hash 7
                ]

        _ =
            Debug.log "equality"
                [ hashed listA == hashed listB
                , hashed listA /= hashed (List.range 2 4)
                , hashed (Box { w = 1, h = 2 }) /= hashed (Circle 1)
                ]

        _ =
            Debug.log "nan" (hashed nan1 == hashed nan2)

        _ =
            Debug.log "toString"
                [ Debug.toString (hashed 1) == "1"
                , Debug.toString (hashed (Just (Circle 2.5))) == Debug.toString (Just (Circle 2.5))
                , Debug.toString [ hashed "x" ] == "[\"x\"]"
                ]

        _ =
            Debug.log "show1" (hashed 1)

        _ =
            Debug.log "show2" (hashed "s")

        _ =
            Debug.log "show3" (Just (hashed (Box { w = 1, h = 2 })))

        _ =
            Debug.log "show4" [ hashed ( 1, 'c' ) ]

        _ =
            Debug.log "show5" { k = hashed [ 1 ] }
    in
    ()
