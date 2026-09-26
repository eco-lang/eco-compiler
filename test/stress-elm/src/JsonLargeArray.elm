module JsonLargeArray exposing (main)

-- CHECK: JsonLargeArray: True
--
-- threaded-gc-04b (plans/threaded-gc-04b-young-large-objects.md D0/D5):
-- decode large JSON arrays with list / array / index / oneOf decoders at
-- sizes around the chunk width F (~1,021 elements) and a large size scaled by
-- -m, and check the encode round trip. Large JSON arrays are the input-driven
-- source of large flat pointer arrays (the S2 hazard).

import Array
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


sizes : Int -> List Int
sizes maxSize =
    -- 1056 = 32 leaves (one tree level), 1088 = 34 leaves (a SubTree level),
    -- 32800 = 1025 leaves (two SubTree levels).
    [ 0, 1, 31, 32, 33, 1020, 1021, 1022, 1056, 1057, 1088, 2042, 2043, 3070, 5000, 32800, max 10000 (maxSize * 1000) ]


checkSize : Int -> Bool
checkSize n =
    let
        xs =
            List.range 0 (n - 1)

        text =
            E.encode 0 (E.list E.int xs)

        expectedSum =
            (n * (n - 1)) // 2

        listOk =
            case D.decodeString (D.list D.int) text of
                Ok ys ->
                    List.length ys == n && List.sum ys == expectedSum

                Err _ ->
                    False

        arrayOk =
            case D.decodeString (D.array D.int) text of
                Ok arr ->
                    Array.length arr
                        == n
                        && List.all (\i -> Array.get i arr == Just i)
                            (List.filter (\i -> i >= 0 && i < n) [ 0, 31, 32, 33, 1023, 1024, 1055, 1056, 1087, 32767, 32768, n // 3, n - 1 ])
                        && Array.toList arr
                        == xs
                        && arr
                        == Array.fromList xs

                Err _ ->
                    False

        indexAt i =
            D.decodeString (D.index i D.int) text == Ok i

        probes =
            List.filter (\i -> i >= 0 && i < n) [ 0, 1020, 1021, 1022, n // 2, n - 1 ]

        indexOk =
            List.all indexAt probes

        outOfRangeOk =
            case D.decodeString (D.index n D.int) text of
                Ok _ ->
                    False

                Err _ ->
                    True

        oneOfOk =
            case D.decodeString (D.oneOf [ D.map List.length (D.list D.string), D.map List.length (D.list D.int) ]) text of
                Ok len ->
                    len == n

                Err _ ->
                    False

        roundTripOk =
            case D.decodeString D.value text of
                Ok v ->
                    E.encode 0 v == text

                Err _ ->
                    False
    in
    listOk && arrayOk && indexOk && outOfRangeOk && oneOfOk && roundTripOk


run : StressFlags -> Task.Task Never Bool
run flags =
    StressHarness.loopWhileState flags
        (max 1 flags.numLoops)
        0
        (\_ s -> Task.succeed ( s + 1, checkSize (sizeAt flags.maxSize s) ))


sizeAt : Int -> Int -> Int
sizeAt maxSize i =
    -- One size per loop, cycling, so the default 100 loops check each size
    -- about six times without paying for the large size on every loop.
    let
        all =
            sizes maxSize
    in
    List.drop (modBy (List.length all) i) all
        |> List.head
        |> Maybe.withDefault 0


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonLargeArray"
        , run = run
        }
