module Lru exposing (bench, output)

{-| LRU cache: `n` rounds of a put and a get on a 100-entry least-recently-used cache, with keys
from two linear congruential generators; report the hits and misses. `Dict` churn.

The cache keeps entries by key, each with the "time" of its last use, plus the keys by that time,
so the least recently used entry is the one with the smallest live time.

Every round is a hit or a miss, so they must add up to `n`. There is no cheaper way to know the
split than to run a cache, so it is checked exactly only at the sizes in `known` (on which the
official Elm compiler, eco's JavaScript and eco's native code agree).
-}

import Dict exposing (Dict)


type alias Cache =
    { capacity : Int
    , entries : Dict Int ( Int, Int ) -- key -> (value, last use)
    , byUse : Dict Int Int -- last use -> key
    , clock : Int
    , oldest : Int -- no live entry was used before this time
    }


empty : Int -> Cache
empty capacity =
    Cache capacity Dict.empty Dict.empty 0 0


touch : Int -> Int -> Int -> Cache -> Cache
touch key value lastUse cache =
    { cache
        | entries = Dict.insert key ( value, cache.clock ) cache.entries
        , byUse = Dict.insert cache.clock key (Dict.remove lastUse cache.byUse)
        , clock = cache.clock + 1
    }


get : Int -> Cache -> ( Maybe Int, Cache )
get key cache =
    case Dict.get key cache.entries of
        Just ( value, lastUse ) ->
            ( Just value, touch key value lastUse cache )

        Nothing ->
            ( Nothing, cache )


put : Int -> Int -> Cache -> Cache
put key value cache =
    case Dict.get key cache.entries of
        Just ( _, lastUse ) ->
            touch key value lastUse cache

        Nothing ->
            let
                room =
                    if Dict.size cache.entries == cache.capacity then
                        evict cache

                    else
                        cache
            in
            { room
                | entries = Dict.insert key ( value, room.clock ) room.entries
                , byUse = Dict.insert room.clock key room.byUse
                , clock = room.clock + 1
            }


evict : Cache -> Cache
evict cache =
    case Dict.get cache.oldest cache.byUse of
        Just key ->
            { cache
                | entries = Dict.remove key cache.entries
                , byUse = Dict.remove cache.oldest cache.byUse
                , oldest = cache.oldest + 1
            }

        Nothing ->
            evict { cache | oldest = cache.oldest + 1 }


{-| `(1103515245 * seed + 12345) mod 2^31`, with the product split so that every intermediate
value stays below 2^53 (exact on the JavaScript backend too).
-}
lcg : Int -> Int
lcg seed =
    let
        high =
            modBy 32768 (16838 * seed)

        low =
            20077 * seed
    in
    modBy 2147483648 (high * 65536 + low + 12345)


run : Int -> Int -> Int -> Int -> Int -> Cache -> ( Int, Int )
run i seed0 seed1 hits misses cache =
    if i <= 0 then
        ( hits, misses )

    else
        let
            s0 =
                lcg seed0

            s1 =
                lcg seed1

            modulus =
                cache.capacity * 10

            k0 =
                modBy modulus s0

            ( found, cache2 ) =
                get (modBy modulus s1) (put k0 k0 cache)
        in
        case found of
            Just _ ->
                run (i - 1) s0 s1 (hits + 1) misses cache2

            Nothing ->
                run (i - 1) s0 s1 hits (misses + 1) cache2


{-| Hits and misses for a cache of 100 entries and `n` rounds.
-}
hitsAndMisses : Int -> ( Int, Int )
hitsAndMisses n =
    run n 0 1 0 0 (empty 100)


{-| The benchmark's standard output for a cache of 100 entries and `n` rounds: hits, then
misses.
-}
output : Int -> String
output n =
    let
        ( hits, misses ) =
            hitsAndMisses n
    in
    String.fromInt hits ++ "\n" ++ String.fromInt misses ++ "\n"


{-| `( rounds, ( hits, misses ) )`.
-}
known : List ( Int, ( Int, Int ) )
known =
    [ ( 100000, ( 9616, 90384 ) ), ( 120000, ( 11506, 108494 ) ) ]


bench : Int -> Bool
bench n =
    let
        ( hits, misses ) =
            hitsAndMisses n
    in
    hits + misses
        == n
        && (case List.filter (\( rounds, _ ) -> rounds == n) known of
                ( _, expected ) :: _ ->
                    ( hits, misses ) == expected

                [] ->
                    True
           )
