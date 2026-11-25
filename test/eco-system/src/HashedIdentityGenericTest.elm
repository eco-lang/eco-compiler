module HashedIdentityGenericTest exposing (main)

{-| HashedIdentityTest.elm's program with ECO_HASH_INLINE=0: every `Hash.Hashed` is hashed by the
runtime walker (`eco_hash_value`, `eco_hash_walk`) instead of from its stored hash read inline. Its
CHECK lines must stay identical to HashedIdentityTest.elm's.

-}

-- SKIP-JS: the JavaScript hash gives other numbers
-- CHECK: alone: [4050385010,3742212023,3448930348,2963535345]
-- CHECK: fields: [611092403,2044774761,3596694188,1482168284,4122524957,4164087311]
-- CHECK: value: 43
-- ENV: ECO_HASH_INLINE=0
import Hash exposing (hashed, value)
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
                , Hash.hash (hashed [ 1, 2, 3 ])
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
