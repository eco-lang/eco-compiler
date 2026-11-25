module HashConsTest exposing (main)

{-| Hash-consing with `Hashed` children and `HashedSet.intern` (plans/hashed-values-and-hash-consing.md
H7): the same 1,000 types, built bottom-up twice through one table, give as many table entries as
there are distinct types, and the second build's types equal the first's. Each node's hash comes from
its children's stored hashes.

-}

-- CHECK: distinct: True
-- CHECK: rebuilt: True
-- CHECK: shapes: [True,True]

import Hash exposing (Hashed, hashed, value)
import HashedSet exposing (HashedSet)
import SeqSet
import System
import Task


type Ty
    = TInt
    | TBool
    | TList (Hashed Ty)
    | TFun (Hashed Ty) (Hashed Ty)


{-| The same types without `Hashed`, to count the distinct ones independently.
-}
type PTy
    = PInt
    | PBool
    | PList PTy
    | PFun PTy PTy


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


intern : Ty -> HashedSet Ty -> ( Hashed Ty, HashedSet Ty )
intern ty table =
    HashedSet.intern (hashed ty) table


{-| The `i`-th type: a small expression over earlier choices, deterministic in `i`.
-}
build : Int -> HashedSet Ty -> ( Hashed Ty, HashedSet Ty )
build i table =
    case modBy 4 i of
        0 ->
            intern TInt table

        1 ->
            intern TBool table

        2 ->
            let
                ( e, t1 ) =
                    build (i // 3) table
            in
            intern (TList e) t1

        _ ->
            let
                ( a, t1 ) =
                    build (i // 2) table

                ( b, t2 ) =
                    build (i // 5) t1
            in
            intern (TFun a b) t2


plain : Int -> PTy
plain i =
    case modBy 4 i of
        0 ->
            PInt

        1 ->
            PBool

        2 ->
            PList (plain (i // 3))

        _ ->
            PFun (plain (i // 2)) (plain (i // 5))


toPlain : Ty -> PTy
toPlain ty =
    case ty of
        TInt ->
            PInt

        TBool ->
            PBool

        TList e ->
            PList (toPlain (value e))

        TFun a b ->
            PFun (toPlain (value a)) (toPlain (value b))


{-| Every subterm of a plain type, itself included.
-}
subterms : PTy -> List PTy
subterms ty =
    ty
        :: (case ty of
                PList e ->
                    subterms e

                PFun a b ->
                    subterms a ++ subterms b

                _ ->
                    []
           )


buildAll : HashedSet Ty -> ( List (Hashed Ty), HashedSet Ty )
buildAll table =
    List.foldl
        (\i ( acc, t ) ->
            let
                ( ty, t1 ) =
                    build i t
            in
            ( ty :: acc, t1 )
        )
        ( [], table )
        (List.range 1 1000)


report : () -> ()
report () =
    let
        ( first, table1 ) =
            buildAll HashedSet.empty

        ( second, table2 ) =
            buildAll table1

        distinct =
            SeqSet.size (SeqSet.fromList (List.concatMap (\i -> subterms (plain i)) (List.range 1 1000)))

        _ =
            Debug.log "distinct" (HashedSet.size table1 == distinct && HashedSet.size table2 == distinct)

        _ =
            Debug.log "rebuilt" (first == second)

        _ =
            Debug.log "shapes"
                [ List.map (value >> toPlain) first == List.reverse (List.map plain (List.range 1 1000))
                , Hash.hash (TList (hashed TInt)) == Hash.hash (TList (hashed TInt))
                ]
    in
    ()
