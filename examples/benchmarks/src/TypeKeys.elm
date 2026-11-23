module TypeKeys exposing
    ( Ty, hashOf, rehash
    , topOfCode, drawCodes, longKey, distinctCount
    , internBenchWith, benchInternCached, benchInternRehash
    , benchDictLongKey, triangle
    )

{-| Large keys, as the eco compiler uses them. The keys are type trees shaped like the compiler's
`MonoType`s, and Strings that spell such a tree out.

  - `benchDictLongKey` (dict-longkey) keys a `Dict String Int` on Strings of about 190 characters
    shaped like the LSS member keys (`l|<raw>|<type>|#<tag>`, `Engine.LssMemberTable.byKey`).
    Keys built from the same type share all but their last few characters, so every comparison
    walks a long common prefix. Half the lookups miss, and those differ from a present key only in
    the tag at the end. Every lookup key is a freshly built String, as the compiler rebuilds its
    keys. Checked in closed form: the size, the hit count and the value sum.
  - `benchInternCached` (intern-cached-hash) hash-conses the type trees bottom-up into a table of
    `Dict Int (List Ty)` buckets, as `Compiler.IR.Mono.Intern` does over `Data.HashMap`. Every
    composite node stores its hash, computed once when it is built from its children's stored
    hashes, as `MonoType`'s composite constructors do.
  - `benchInternRehash` (intern-rehash) does the same work, but computes each node's hash by walking
    its whole subtree at every probe. The ratio between the two is what caching a large
    structure's hash is worth.

Both intern workloads are checked against the generator: the table must find exactly as many
distinct top-level types as there are distinct codes drawn, and every 64th canonical copy must
equal the type it was interned for.

The trees come from fixed pools: 40 small function types, 400 pairs of those, and top-level
function types with four pair arguments and a two-field record result, picked by six base-`r`
digits of a code.

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Set



-- TYPES


{-| A type tree. Every composite node stores its hash, set by the `mk*` constructors.
-}
type Ty
    = TLeaf Int
    | TList Int Ty
    | TTuple Int Ty Ty
    | TFun Int (List Ty) Ty
    | TRec Int (List ( String, Ty ))


hashBase : Int
hashBase =
    67108864


{-| The compiler's `Mono.mixHash`: `h` with `x` mixed in, in `[0, 2^26)`.
-}
mix : Int -> Int -> Int
mix h x =
    modBy hashBase (h * 33 + modBy hashBase x + 7)


stringHash : String -> Int
stringHash s =
    String.foldl (\c h -> mix h (Char.toCode c)) 5381 s


{-| The hash a node stores; a leaf's is its kind plus one.
-}
hashOf : Ty -> Int
hashOf t =
    case t of
        TLeaf k ->
            k + 1

        TList h _ ->
            h

        TTuple h _ _ ->
            h

        TFun h _ _ ->
            h

        TRec h _ ->
            h


{-| The same hash as `hashOf`, computed by walking the whole tree instead of reading it.
-}
rehash : Ty -> Int
rehash t =
    case t of
        TLeaf k ->
            k + 1

        TList _ e ->
            mix 11 (rehash e)

        TTuple _ a b ->
            mix (mix 12 (rehash a)) (rehash b)

        TFun _ args res ->
            mix (List.foldl (\a h -> mix h (rehash a)) 13 args) (rehash res)

        TRec _ fields ->
            List.foldl (\( n, ft ) h -> mix (mix h (stringHash n)) (rehash ft)) 14 fields


mkList : Ty -> Ty
mkList e =
    TList (mix 11 (hashOf e)) e


mkTuple : Ty -> Ty -> Ty
mkTuple a b =
    TTuple (mix (mix 12 (hashOf a)) (hashOf b)) a b


mkFun : List Ty -> Ty -> Ty
mkFun args res =
    TFun (mix (List.foldl (\a h -> mix h (hashOf a)) 13 args) (hashOf res)) args res


mkRec : List ( String, Ty ) -> Ty
mkRec fields =
    TRec (List.foldl (\( n, ft ) h -> mix (mix h (stringHash n)) (hashOf ft)) 14 fields) fields



-- GENERATOR


{-| The `i`-th of 40 small function types, `a -> b -> c` over the four leaves (distinct, since
40 < 4^3).
-}
pool1 : Int -> Ty
pool1 i =
    mkFun [ TLeaf (modBy 4 i), TLeaf (modBy 4 (i // 4)) ] (TLeaf (modBy 4 (i // 16)))


{-| The `i`-th of 400 pair types, `( pool1 x, List (pool1 y) )`.
-}
pool2 : Int -> Ty
pool2 i =
    mkTuple (pool1 (modBy 40 i)) (mkList (pool1 (i // 40)))


{-| The top-level type of `code`, whose six base-`r` digits pick its pool members (`r` at most
400). Different codes give different types.
-}
topOfCode : Int -> Int -> Ty
topOfCode r code =
    let
        digit k =
            pool2 (modBy r (code // (r ^ k)))
    in
    mkFun [ digit 0, digit 1, digit 2, digit 3 ]
        (mkRec [ ( "result", digit 4 ), ( "state", mkList (digit 5) ) ])


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| `n` pseudo-random codes of six base-`r` digits each.
-}
drawCodes : Int -> Int -> List Int
drawCodes r n =
    let
        digits k seed acc =
            if k <= 0 then
                ( acc, seed )

            else
                let
                    s =
                        next seed
                in
                digits (k - 1) s (acc * r + modBy r s)

        go i seed acc =
            if i <= 0 then
                List.reverse acc

            else
                let
                    ( code, s ) =
                        digits 6 seed 0
                in
                go (i - 1) s (code :: acc)
    in
    go n 1 []


distinctCount : List Int -> Int
distinctCount codes =
    Set.size (Set.fromList codes)



-- LONG STRING KEYS


{-| The type spelt out, as `Mono.toComparableMonoType` does.
-}
fragments : Ty -> List String -> List String
fragments t acc =
    case t of
        TLeaf k ->
            (case k of
                0 ->
                    "I"

                1 ->
                    "F"

                2 ->
                    "S"

                _ ->
                    "B"
            )
                :: acc

        TList _ e ->
            "L(" :: fragments e (")" :: acc)

        TTuple _ a b ->
            "T(" :: fragments a ("," :: fragments b (")" :: acc))

        TFun _ args res ->
            "F(" :: List.foldr (\a rest -> fragments a ("," :: rest)) (")>" :: fragments res acc) args

        TRec _ fields ->
            "R{" :: List.foldr (\( n, ft ) rest -> n :: ":" :: fragments ft ("," :: rest)) ("}" :: acc) fields


{-| A member-key-shaped String for the type of `code`: `l|<raw>|<type>|#<tag>`, where `raw` comes
from the code, so keys differ only in the tag at the end when their types agree.
-}
longKey : Int -> Int -> Int -> String
longKey r code tag =
    String.concat ("l|" :: String.fromInt (modBy 97 code) :: "|" :: fragments (topOfCode r code) [ "|#", String.fromInt tag ])


benchDictLongKey : Int -> Bool
benchDictLongKey n =
    let
        codes =
            Array.fromList (drawCodes 20 n)

        codeAt j =
            Maybe.withDefault 0 (Array.get j codes)

        d =
            List.foldl (\j acc -> Dict.insert (longKey 20 (codeAt j) j) j acc) Dict.empty (List.range 0 (n - 1))

        -- even j looks up key j; odd j looks up the same String with tag j + n, which is absent
        hits =
            List.foldl
                (\j acc ->
                    let
                        tag =
                            if modBy 2 j == 0 then
                                j

                            else
                                j + n
                    in
                    case Dict.get (longKey 20 (codeAt j) tag) d of
                        Just _ ->
                            acc + 1

                        Nothing ->
                            acc
                )
                0
                (List.range 0 (n - 1))
    in
    (Dict.size d == n)
        && (hits == (n + 1) // 2)
        && (Dict.foldl (\_ v s -> s + v) 0 d == triangle n)



{-| 0 + 1 + ... + (n - 1), with the even factor halved first: JavaScript's `//` truncates to 32
bits.
-}
triangle : Int -> Int
triangle n =
    if modBy 2 n == 0 then
        (n // 2) * (n - 1)

    else
        n * ((n - 1) // 2)



-- HASH-CONSING


type alias InternTable =
    { buckets : Dict Int (List Ty)
    , size : Int
    }


emptyTable : InternTable
emptyTable =
    { buckets = Dict.empty, size = 0 }


{-| Returns the canonical copy of `node`, whose children are already canonical, under the hash
`h` gives, registering `node` if the table has no equal one; the `Bool` says it was new.
-}
probe : (Ty -> Int) -> Ty -> InternTable -> ( Ty, Bool, InternTable )
probe h node table =
    let
        k =
            h node

        bucket =
            Maybe.withDefault [] (Dict.get k table.buckets)
    in
    case List.filter (\x -> x == node) bucket of
        found :: _ ->
            ( found, False, table )

        [] ->
            ( node, True, { buckets = Dict.insert k (node :: bucket) table.buckets, size = table.size + 1 } )


{-| Rebuilds `t` from its children's canonical copies, interning each child first with `probeFn`;
leaves are not interned.
-}
consChildren : (Ty -> tbl -> ( Ty, Bool, tbl )) -> Ty -> tbl -> ( Ty, tbl )
consChildren probeFn t table =
    case t of
        TLeaf _ ->
            ( t, table )

        TList _ e ->
            let
                ( e1, t1 ) =
                    cons probeFn e table
            in
            ( mkList e1, t1 )

        TTuple _ a b ->
            let
                ( a1, t1 ) =
                    cons probeFn a table

                ( b1, t2 ) =
                    cons probeFn b t1
            in
            ( mkTuple a1 b1, t2 )

        TFun _ args res ->
            let
                ( revArgs, t1 ) =
                    List.foldl (\a ( acc, tb ) -> cons probeFn a tb |> Tuple.mapFirst (\c -> c :: acc)) ( [], table ) args

                ( res1, t2 ) =
                    cons probeFn res t1
            in
            ( mkFun (List.reverse revArgs) res1, t2 )

        TRec _ fields ->
            let
                ( revFields, t1 ) =
                    List.foldl (\( n, ft ) ( acc, tb ) -> cons probeFn ft tb |> Tuple.mapFirst (\c -> ( n, c ) :: acc)) ( [], table ) fields
            in
            ( mkRec (List.reverse revFields), t1 )


cons : (Ty -> tbl -> ( Ty, Bool, tbl )) -> Ty -> tbl -> ( Ty, tbl )
cons probeFn t table =
    case consChildren probeFn t table of
        ( (TLeaf _) as leaf, t1 ) ->
            ( leaf, t1 )

        ( node, t1 ) ->
            let
                ( canon, _, t2 ) =
                    probeFn node t1
            in
            ( canon, t2 )


{-| Interns `n` drawn top-level types bottom-up into `empty` with `probeFn`, and checks the
count of new top-level types and a sample of the canonical copies against the generator.
-}
internBenchWith : (Ty -> tbl -> ( Ty, Bool, tbl )) -> tbl -> Int -> Bool
internBenchWith probeFn empty n =
    let
        codes =
            drawCodes 6 n

        step code ( i, ( newTops, ok ), table ) =
            let
                fresh =
                    topOfCode 6 code

                ( node, table1 ) =
                    consChildren probeFn fresh table

                ( canon, isNew, table2 ) =
                    probeFn node table1

                sampleOk =
                    modBy 64 i /= 0 || canon == fresh
            in
            ( i + 1
            , ( if isNew then
                    newTops + 1

                else
                    newTops
              , ok && sampleOk
              )
            , table2
            )

        ( _, ( tops, allOk ), _ ) =
            List.foldl step ( 0, ( 0, True ), empty ) codes
    in
    allOk && tops == distinctCount codes


benchInternCached : Int -> Bool
benchInternCached n =
    internBenchWith (probe hashOf) emptyTable n


benchInternRehash : Int -> Bool
benchInternRehash n =
    internBenchWith (probe rehash) emptyTable n
