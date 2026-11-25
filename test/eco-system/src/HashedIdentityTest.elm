module HashedIdentityTest exposing (main)

{-| `Hash.hash` and `Hash.hashOf` of `Hash.Hashed` values, on their own and as tuple and record fields,
with the stored hash read inline (plans/hashed-values-and-hash-consing.md F4: `eco.hash` and
`eco.hash.mix` of kind `hashed`). HashedIdentityGenericTest.elm is the same program run with
ECO_HASH_INLINE=0, so that every `Hashed` is hashed by the runtime walker (`eco_hash_value`,
`eco_hash_walk`); the two must print the same numbers. The numbers are native ones (JavaScript has its
own hash), so both files skip JavaScript.

-}

-- SKIP-JS: the JavaScript hash gives other numbers
-- CHECK: alone: [4050385010,3742212023,3448930348,2963535345]
-- CHECK: fields: [611092403,2044774761,3596694188,1482168284,4122524957,4164087311]
-- CHECK: value: 43
import Hash exposing (hashOf, hashed, value)
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            Debug.log "alone"
                [ Hash.hash (hashed 42)
                , Hash.hash (hashed "abc")
                , hashOf (hashed [ 1, 2, 3 ])
                , Hash.hash (hashed ( 1, "a" ))
                ]

        _ =
            Debug.log "fields"
                [ Hash.hash ( hashed 1, 2 )
                , Hash.hash ( 2, hashed 1 )
                , Hash.hash { a = hashed "x", b = 'c' }
                , Hash.hash ( 1, ( hashed [ 'a' ], hashed () ) )
                , Hash.hash ( hashed ( hashed 1, 2 ), 3 )
                , Hash.hash ( hashed 1, hashed 1, hashed 2 )
                ]

        _ =
            Debug.log "value" (value (hashed 42) + 1)
    in
    ()
