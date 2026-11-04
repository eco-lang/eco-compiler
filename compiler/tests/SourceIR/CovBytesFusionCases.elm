module SourceIR.CovBytesFusionCases exposing (expectSuite)

{-| Programs that encode and decode with the elm/bytes API through
`Bytes.Encode.encode` and `Bytes.Decode.decode` calls, written so that the MLIR
back end's bytes fusion (`Compiler.GenerateMlir.BytesFusion.Reify` and
`Compiler.GenerateMlir.BytesFusion.Emit`) meets each encoder and decoder form
it recognises, and many that it inspects and declines.

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies, so what is
checked, and at which stage, is decided by that function.

The programs are parsed as modules of elm/core (`Parse.Package Pkg.core`), so
they get no default imports and may name `Elm.Kernel.*` functions; every
import is written out in `header`. They compile against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`, where the elm/bytes functions are
externs with no body, so `encode`, `decode` and the combinators survive as
calls of the elm/bytes globals and reach the reifier as written. Most programs
define `testValue` as a function, so that the `decode` or `encode` call is
compiled inside a function rather than as a constant.

The cases, by group and label:

  - Recognised decoders (`decoderPrograms`): "Decode each fixed-width read",
    "Decode map to map4", "Decode length-prefixed string and bytes" (an
    `andThen` whose callback is `string n` or `bytes n`), count loops ("Decode
    count loop with let-bound count", "... with parameter count", "... of
    every integer width", "... counted by an andThen parameter", "... of
    float32"), "Decode sentinel loop" (stopping at `0 == b`), "Decode bytes and
    string of a variable length", "Decode andThen whose body maps over a
    length read" (a lambda applied to a `string` or `bytes` read of the
    callback's parameter, whose lambda is queued twice for generation:
    finding F11, fixed), and `map` over a function that is a local, a
    global, a kernel, a call, an `if`, a `case`, a record field or an accessor
    ("Decode map with function expressions of every kind") or one bound by a
    `let` or a destructuring.
  - Declined or unusual decoders (`declinedDecoderPrograms`): curried calls,
    `let`-bound partial applications and top-level decoders; `andThen` with a
    callback that is not a lambda, a decoder that is a parameter, a body that
    is not a length read, a body whose expressions use the callback's
    parameter ("Decode andThen with a general body", declined since finding
    F10 was fixed), or a length read of another width; `map4` with an
    unrecognised decoder in each position; count and sentinel loops that each
    differ from the recognised idiom in one place (state, condition,
    decrement, cons, `Done` value, item decoder, combinator, step or parts
    passed as parameters); `andThen` bodies that are a `map3`, a `map4`, a
    nested `andThen`, a sentinel loop or a call of a top-level decoder
    function ("Decode andThen bodies of every combinator"); and functions
    that return a partial decoder.
  - Recognised encoders (`encoderPrograms`): "Encode every write", length
    prefixed lists mapped with a lambda, a named function and a partial
    application, a `let`-bound partial application, and the kernel writes
    `write_u8` and `write_i8`.
  - Declined encoders (`declinedEncoderPrograms`): calls that are not
    encoders, length prefixes that differ from the recognised shape, loop
    items without a constant width, endianness that is not a constructor, a
    `sequence` of a parameter and of a `let` with a local tail function,
    values the fused encoder must unbox, and functions that return a partial
    encoder.

Among what is not tested: a run of the fused code, and the inlined forms that
a build against the real elm/bytes produces (the E2E suite, with
`test/elm-bytes/src/BytesLoopNearMissFusionTest.elm`, covers those).

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Bytes fusion coverage " followed by `condStr`,
that passes when `expectFn` passes on every case's program and otherwise fails
with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bytes fusion coverage " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, decoders first and then encoders.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) -> { label = label, run = \_ -> runSource expectFn body })
        (decoderPrograms ++ declinedDecoderPrograms ++ encoderPrograms ++ declinedEncoderPrograms)


{-| Runs `expectFn` on the module parsed from `header` followed by `body`, or
fails when that source does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) (header ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)


{-| The module header shared by the programs: module `Test` and the imports
they use, all written out because an elm/core module gets no default imports.
-}
header : String
header =
    """module Test exposing (..)

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Bytes.Decode as D

"""



-- ============================================================================
-- DECODERS
-- ============================================================================


{-| The decoder programs, by label, as the source that follows `header`.
-}
decoderPrograms : List ( String, String )
decoderPrograms =
    [ ( "Decode each fixed-width read"
      , """
testValue b =
    { a = D.decode (D.unsignedInt16 BE) b
    , c = D.decode (D.signedInt16 LE) b
    , d = D.decode (D.unsignedInt32 BE) b
    , e = D.decode (D.signedInt32 LE) b
    , f = D.decode (D.float32 BE) b
    , g = D.decode (D.float64 LE) b
    }
"""
      )
    , ( "Decode map to map4"
      , """
testValue b =
    { m1 = D.decode (D.map (\\x -> x + 1) D.unsignedInt8) b
    , m2 = D.decode (D.map2 (\\x y -> x + y) D.unsignedInt8 (D.unsignedInt16 BE)) b
    , m3 = D.decode (D.map3 (\\x y z -> x + y + z) D.unsignedInt8 D.signedInt8 (D.unsignedInt16 LE)) b
    , m4 = D.decode (D.map4 (\\x y z w -> x + y + z + w) D.unsignedInt8 D.signedInt8 (D.unsignedInt32 LE) (D.signedInt32 BE)) b
    }
"""
      )
    , ( "Decode length-prefixed string and bytes"
      , """
testValue b =
    ( D.decode (D.andThen (\\n -> D.string n) D.unsignedInt8) b
    , D.decode (D.andThen (\\n -> D.bytes n) (D.signedInt16 BE)) b
    , D.decode (D.andThen (\\n -> D.string n) (D.unsignedInt32 LE)) b
    )
"""
      )
    , ( "Decode count loop with let-bound count"
      , """
testValue b =
    let
        count =
            4
    in
    D.decode
        (D.loop ( count, [] )
            (\\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt16 LE)
            )
        )
        b
"""
      )
    , ( "Decode count loop with parameter count"
      , """
testValue k b =
    D.decode
        (D.loop ( k, [] )
            (\\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done acc)

                else
                    D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.float64 BE)
            )
        )
        b
"""
      )
    , ( "Decode sentinel loop"
      , """
testValue b =
    D.decode
        (D.loop []
            (\\acc ->
                D.andThen
                    (\\byte ->
                        if 0 == byte then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.succeed (D.Loop (byte :: acc))
                    )
                    (D.unsignedInt16 BE)
            )
        )
        b
"""
      )
    , ( "Decode count loops of every integer width"
      , """
testValue b =
    { s16 =
        D.decode
            (D.loop ( 2, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt16 BE)
                )
            )
            b
    , u32 =
        D.decode
            (D.loop ( 2, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt32 LE)
                )
            )
            b
    , s32 =
        D.decode
            (D.loop ( 2, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt32 BE)
                )
            )
            b
    , sentinelS8 =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.signedInt8
                )
            )
            b
    }
"""
      )
    , ( "Decode bytes and string of a variable length"
      , """
testValue k b =
    ( D.decode (D.bytes k) b, D.decode (D.string k) b )
"""
      )
    , ( "Decode count loop counted by an andThen parameter"
      , """
testValue b =
    D.decode
        (D.andThen
            (\\count ->
                D.loop ( count, [] )
                    (\\( n, acc ) ->
                        if n <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                    )
            )
            D.unsignedInt8
        )
        b
"""
      )
    , ( "Decode map with function expressions of every kind"
      , """
testValue f g c r m b =
    { local = D.decode (D.map f D.unsignedInt8) b
    , global = D.decode (D.map negate D.unsignedInt8) b
    , kernel = D.decode (D.map Elm.Kernel.Basics.negate D.signedInt8) b
    , call = D.decode (D.map (g 1) D.unsignedInt8) b
    , ifFn = D.decode (D.map (if c then f else negate) D.unsignedInt8) b
    , caseFn =
        D.decode
            (D.map
                (case m of
                    Just h ->
                        h

                    Nothing ->
                        f
                )
                D.unsignedInt8
            )
            b
    , field = D.decode (D.map r.fn D.unsignedInt8) b
    , accessor = D.decode (D.map .x (D.succeed { x = 1 })) b
    }
"""
      )
    , ( "Decode count loop of float32"
      , """
testValue b =
    D.decode
        (D.loop ( 2, [] )
            (\\( n, acc ) ->
                if n <= 0 then
                    D.succeed (D.Done acc)

                else
                    D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.float32 BE)
            )
        )
        b
"""
      )
    , ( "Decode map with a function bound by let or destructuring"
      , """
testValue g pr b =
    ( D.decode
        (D.map
            (let
                ( p, q ) =
                    pr
             in
             p
            )
            D.unsignedInt8
        )
        b
    , D.decode
        (D.map
            (let
                h =
                    g 2
             in
             if h 0 > 0 then h else negate
            )
            D.unsignedInt8
        )
        b
    )
"""
      )
    , ( "Decode andThen whose body maps over a length read"
      , """
testValue b =
    ( D.decode (D.andThen (\\n -> D.map (\\s -> s) (D.string n)) D.unsignedInt8) b
    , D.decode (D.andThen (\\n -> D.map2 (\\a s -> s) (D.succeed 0) (D.bytes n)) D.unsignedInt8) b
    )
"""
      )
    ]


{-| Decoder programs that each hold `decode` calls whose decoder the reifier
inspects and then declines, or recognises only after looking through an
unusual form: a curried call, a `let`-bound partial application, a top-level
decoder, an `andThen` whose callback is not a lambda or whose body is not a
length read, and count and sentinel loops that differ from the
recognised idioms in one place each.
-}
declinedDecoderPrograms : List ( String, String )
declinedDecoderPrograms =
    [ ( "Decode through curried call, let-bound partial and globals"
      , """
dec : D.Decoder Int
dec =
    D.unsignedInt8


decE : Endianness -> D.Decoder Int
decE e =
    D.unsignedInt16 e


testValue b =
    let
        rd =
            D.unsignedInt16

        rd2 =
            D.map2 (\\x y -> x + y) D.unsignedInt8
    in
    { a = D.decode ((D.map2 (\\x y -> x + y) D.unsignedInt8) D.unsignedInt8) b
    , c = D.decode (rd BE) b
    , d = D.decode dec b
    , e = D.decode (decE LE) b
    , f = D.decode (rd2 D.signedInt8) b
    }
"""
      )
    , ( "Decode andThen declined or general"
      , """
testValue d f b =
    { a = D.decode (D.andThen (\\n -> D.string n) d) b
    , c = D.decode (D.andThen D.string D.unsignedInt8) b
    , e = D.decode (D.andThen (\\n -> D.string n) (D.succeed 3)) b
    , g = D.decode (D.andThen (\\n -> f n) D.unsignedInt8) b
    , h = D.decode (D.andThen (\\n -> D.string 5) D.unsignedInt8) b
    }
"""
      )
    , ( "Decode length-prefixed string after other length reads"
      , """
testValue b =
    ( D.decode (D.andThen (\\n -> D.string n) D.signedInt8) b
    , D.decode (D.andThen (\\n -> D.bytes n) (D.unsignedInt16 LE)) b
    , D.decode (D.andThen (\\n -> D.string n) (D.signedInt32 BE)) b
    )
"""
      )
    , ( "Decode map4 with an unrecognised decoder"
      , """
testValue d b =
    ( D.decode (D.map4 (\\x y z w -> x + y + z + w) d D.signedInt8 D.unsignedInt8 D.unsignedInt8) b
    , D.decode (D.map4 (\\x y z w -> x + y + z + w) D.unsignedInt8 d D.unsignedInt8 D.unsignedInt8) b
    , D.decode (D.map4 (\\x y z w -> x + y + z + w) D.unsignedInt8 D.unsignedInt8 d D.unsignedInt8) b
    )
"""
      )
    , ( "Decode map4 with an unrecognised last decoder"
      , """
testValue d b =
    D.decode (D.map4 (\\x y z w -> x + y + z + w) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 d) b
"""
      )
    , ( "Decode count loops that differ from the idiom"
      , """
testValue k f pair b =
    { nonEmptyAcc =
        D.decode
            (D.loop ( 3, [ 1 ] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.signedInt8
                )
            )
            b
    , ltCond =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n < 1 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.unsignedInt32 BE)
                )
            )
            b
    , oneArgCond =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if f n then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.signedInt32 LE)
                )
            )
            b
    , noDecrement =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n, x :: acc )) (D.float32 LE)
                )
            )
            b
    , noCons =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, acc )) (D.signedInt16 BE)
                )
            )
            b
    , doubleReverse =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done (List.reverse (List.reverse acc)))

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , emptyDone =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done [])

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , stringItem =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) (D.string 3)
                )
            )
            b
    , noMap =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.succeed (D.Loop ( n - 1, acc ))
                )
            )
            b
    , computedCount =
        D.decode
            (D.loop ( k + 1, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , opaqueState =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop (pair n x acc)) D.unsignedInt8
                )
            )
            b
    , extraDestruct =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    let
                        ( p, q ) =
                            pair n 0 acc
                    in
                    if n <= 0 then
                        D.succeed (D.Done q)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , firstOfState =
        D.decode
            (D.loop ( 3, [] )
                (\\st ->
                    if Tuple.first st <= 0 then
                        D.succeed (D.Done (Tuple.second st))

                    else
                        D.map (\\x -> D.Loop ( Tuple.first st - 1, x :: Tuple.second st )) D.unsignedInt8
                )
            )
            b
    }
"""
      )
    , ( "Decode loops whose combinators are the wrong call"
      , """
testValue dflt stepBody b =
    { elseAndThen =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.andThen (\\x -> D.succeed (D.Loop ( n - 1, x :: acc ))) D.unsignedInt8
                )
            )
            b
    , elseParam =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        dflt
                )
            )
            b
    , sentinelMap =
        D.decode
            (D.loop []
                (\\acc ->
                    D.map
                        (\\x ->
                            if x == 0 then
                                D.Done acc

                            else
                                D.Loop (x :: acc)
                        )
                        D.unsignedInt8
                )
            )
            b
    , sentinelParam = D.decode (D.loop [] (\\acc -> stepBody)) b
    }
"""
      )
    , ( "Decode through functions that return a partial decoder"
      , """
mapWith : (Int -> Int) -> (D.Decoder Int -> D.Decoder Int)
mapWith f =
    D.map f


rk : Int -> (Int -> D.Decoder Int)
rk a =
    Elm.Kernel.Bytes.read_pair a


pickD : Int -> (D.Decoder Int -> D.Decoder Int)
pickD k =
    if k > 0 then
        D.map negate

    else
        D.map abs


testValue k b =
    { a = D.decode (mapWith negate D.unsignedInt8) b
    , c = D.decode (rk 1 2) b
    , d = D.decode (pickD k D.unsignedInt8) b
    }
"""
      )
    , ( "Decode sentinel loops that differ from the idiom"
      , """
testValue f g c b =
    { noAndThen =
        D.decode (D.loop [] (\\acc -> D.succeed (D.Done acc))) b
    , namedCallback =
        D.decode (D.loop [] (\\acc -> D.andThen (g acc) D.unsignedInt8)) b
    , noIf =
        D.decode (D.loop [] (\\acc -> D.andThen (\\x -> D.succeed (D.Done acc)) D.unsignedInt8)) b
    , gtCond =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x > 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , otherOperand =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if c == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , oneArgCond =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if f x then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.signedInt8
                )
            )
            b
    , loopWithoutCons =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop acc)
                        )
                        (D.signedInt16 LE)
                )
            )
            b
    , elseFails =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.fail
                        )
                        (D.unsignedInt32 LE)
                )
            )
            b
    , elseDone =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Done (x :: acc))
                        )
                        (D.signedInt32 BE)
                )
            )
            b
    , floatItem =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        (D.float32 BE)
                )
            )
            b
    , float64Item =
        D.decode
            (D.loop []
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        (D.float64 LE)
                )
            )
            b
    }
"""
      )
    , ( "Decode sentinel loop with a named step"
      , """
step : List Int -> D.Decoder (D.Step (List Int) (List Int))
step acc =
    D.andThen
        (\\x ->
            if x == 0 then
                D.succeed (D.Done acc)

            else
                D.succeed (D.Loop (x :: acc))
        )
        D.unsignedInt8


testValue b =
    D.decode (D.loop [] step) b
"""
      )
    , ( "Decode through a local function and let-bound partial calls"
      , """
twoArg : Int -> Int -> D.Decoder Int
twoArg a c =
    if a + c > 3 then
        D.unsignedInt8

    else
        D.map (\\x -> x + a + c) D.signedInt8


testValue f g b =
    let
        r1 =
            g 1

        r2 =
            Elm.Kernel.Bytes.read_pair 1

        r3 =
            twoArg 1
    in
    { a = D.decode (f BE) b
    , c = D.decode (r1 2) b
    , d = D.decode (r2 2) b
    , e = D.decode (r3 2) b
    , h =
        D.decode
            (let
                go n =
                    if n <= 0 then
                        0

                    else
                        go (n - 1)
             in
             D.string (go 3)
            )
            b
    }
"""
      )
    , ( "Decode loops whose parts are parameters"
      , """
testValue step g le mk done r b =
    { namedStep = D.decode (D.loop ( 3, [] ) step) b
    , sentinelInit =
        D.decode
            (D.loop [ 1 ]
                (\\acc ->
                    D.andThen
                        (\\x ->
                            if x == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (x :: acc))
                        )
                        D.unsignedInt8
                )
            )
            b
    , thenNotSucceed =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        g (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , condThroughLocal =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if le n 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , mapFnNotLambda =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed (D.Done acc)

                    else
                        D.map (mk n acc) D.unsignedInt8
                )
            )
            b
    , doneNotCtor =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    if n <= 0 then
                        D.succeed done

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    , recordDestruct =
        D.decode
            (D.loop ( 3, [] )
                (\\( n, acc ) ->
                    let
                        { fx } =
                            r
                    in
                    if n <= fx then
                        D.succeed (D.Done acc)

                    else
                        D.map (\\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                )
            )
            b
    }
"""
      )
    , ( "Decode andThen with a general body"
      , """
testValue b =
    ( D.decode (D.andThen (\\n -> D.map (\\x -> x + n) (D.unsignedInt16 BE)) D.unsignedInt8) b
    , D.decode (D.andThen (\\n -> D.succeed n) (D.unsignedInt16 BE)) b
    )
"""
      )
    , ( "Decode andThen bodies of every combinator"
      , """
pickDec : Int -> D.Decoder Int
pickDec k =
    if k > 3 then
        D.unsignedInt8

    else
        D.map (\\x -> x * 2) D.signedInt8


testValue b =
    { m3 = D.decode (D.andThen (\\n -> D.map3 (\\x y z -> x + y + z) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) D.unsignedInt8) b
    , m4 = D.decode (D.andThen (\\n -> D.map4 (\\x y z w -> x + y + z + w) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) D.unsignedInt8) b
    , nested = D.decode (D.andThen (\\n -> D.andThen (\\m -> D.unsignedInt8) D.unsignedInt8) D.unsignedInt8) b
    , sentinel =
        D.decode
            (D.andThen
                (\\n ->
                    D.loop []
                        (\\acc ->
                            D.andThen
                                (\\x ->
                                    if x == 0 then
                                        D.succeed (D.Done acc)

                                    else
                                        D.succeed (D.Loop (x :: acc))
                                )
                                D.unsignedInt8
                        )
                )
                D.unsignedInt8
            )
            b
    , named = D.decode (D.andThen (\\n -> pickDec n) D.unsignedInt8) b
    }
"""
      )
    ]



-- ============================================================================
-- ENCODERS
-- ============================================================================


{-| The encoder programs, by label, as the source that follows `header`.
-}
encoderPrograms : List ( String, String )
encoderPrograms =
    [ ( "Encode every write"
      , """
testValue s b =
    E.encode
        (E.sequence
            [ E.unsignedInt8 1
            , E.signedInt8 -2
            , E.unsignedInt16 BE 3
            , E.signedInt16 LE 4
            , E.unsignedInt32 BE 5
            , E.signedInt32 LE 6
            , E.float32 BE 1.5
            , E.float64 LE 2.5
            , E.bytes b
            , E.string s
            ]
        )
"""
      )
    , ( "Encode length-prefixed list with lambda, named and eta-expanded function"
      , """
item : Int -> E.Encoder
item x =
    E.unsignedInt16 LE x


item2 : Endianness -> Int -> E.Encoder
item2 e x =
    E.signedInt32 e x


testValue fs xs =
    ( E.encode (E.sequence (E.unsignedInt32 BE (List.length fs) :: List.map (\\x -> E.float32 LE x) fs))
    , E.encode (E.sequence (E.unsignedInt32 LE (List.length xs) :: List.map item xs))
    , E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map (item2 BE) xs))
    )
"""
      )
    , ( "Encode partial application through let"
      , """
testValue x =
    let
        w =
            E.unsignedInt16 BE
    in
    E.encode (E.sequence [ w x, E.unsignedInt8 x ])
"""
      )
    , ( "Encode kernel writes"
      , """
testValue x =
    E.encode (E.sequence [ Elm.Kernel.Bytes.write_u8 x, Elm.Kernel.Bytes.write_i8 x, E.unsignedInt8 x ])
"""
      )
    ]


{-| Encoder programs whose encoders, or parts of them, the reifier inspects
and declines: curried calls and `let`-bound partial applications of locals and
kernels, length-prefixed lists that differ from the recognised shape in
one place each, loop bodies without a constant width, and endianness values
that are not constructors.
-}
declinedEncoderPrograms : List ( String, String )
declinedEncoderPrograms =
    [ ( "Encode curried and let-bound calls that are not encoders"
      , """
testValue f g x =
    let
        w1 =
            Elm.Kernel.Bytes.write_u16 1

        w2 =
            f 1

        w3 =
            g
    in
    E.encode (E.sequence [ (f 1) x, w1 x, w2 x, w3 x, E.unsignedInt8 x ])
"""
      )
    , ( "Encode length prefixes that differ from the shape"
      , """
testValue e k xs ys =
    { otherList = E.encode (E.sequence (E.unsignedInt32 BE (List.length ys) :: List.map (\\x -> E.unsignedInt8 x) xs))
    , varEndian = E.encode (E.sequence (E.unsignedInt32 e (List.length xs) :: List.map (\\x -> E.unsignedInt8 x) xs))
    , u16Header = E.encode (E.sequence (E.unsignedInt16 BE (List.length xs) :: List.map (\\x -> E.unsignedInt8 x) xs))
    , u8Header = E.encode (E.sequence (E.unsignedInt8 (List.length xs) :: List.map (\\x -> E.unsignedInt8 x) xs))
    , absHeader = E.encode (E.sequence (E.unsignedInt32 BE (abs k) :: List.map (\\x -> E.unsignedInt8 x) xs))
    , litHeader = E.encode (E.sequence (E.unsignedInt32 BE 3 :: List.map (\\x -> E.unsignedInt8 x) xs))
    , litList = E.encode (E.sequence (E.unsignedInt32 BE (List.length [ 1, 2 ]) :: List.map (\\x -> E.unsignedInt8 x) [ 1, 2 ]))
    , notMap = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.reverse (List.map (\\x -> E.unsignedInt8 x) xs)))
    , externFn = E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map E.unsignedInt8 xs))
    }
"""
      )
    , ( "Encode length-prefixed lists whose items have no constant width"
      , """
testValue bs ss yss flags =
    { bytesItems = E.encode (E.sequence (E.unsignedInt32 BE (List.length bs) :: List.map (\\x -> E.bytes x) bs))
    , stringItems = E.encode (E.sequence (E.unsignedInt32 BE (List.length ss) :: List.map (\\x -> E.string x) ss))
    , loopItems =
        E.encode
            (E.sequence
                (E.unsignedInt32 BE (List.length yss)
                    :: List.map (\\ys -> E.sequence (E.unsignedInt32 BE (List.length ys) :: List.map (\\y -> E.unsignedInt8 y) ys)) yss
                )
            )
    , opaqueItems =
        E.encode
            (E.sequence
                (E.unsignedInt32 BE (List.length flags)
                    :: List.map (\\f -> if f then E.unsignedInt8 1 else E.unsignedInt8 0) flags
                )
            )
    }
"""
      )
    , ( "Encode with endianness that is not a constructor"
      , """
big : Endianness
big =
    BE


testValue e x =
    E.encode (E.sequence [ E.unsignedInt16 big x, E.unsignedInt16 e x, E.float64 e 1.0 ])
"""
      )
    , ( "Encode sequence of a parameter and a let-rec element"
      , """
testValue encs x =
    ( E.encode (E.sequence encs)
    , E.encode
        (E.sequence
            [ let
                go n =
                    if n <= 0 then
                        0

                    else
                        go (n - 1)
              in
              E.unsignedInt8 (go x)
            , E.unsignedInt8 x
            ]
        )
    )
"""
      )
    , ( "Encode values the fused encoder must unbox"
      , """
testValue x =
    E.encode (E.sequence [ E.unsignedInt8 (Elm.Kernel.Debug.log "x" x), E.unsignedInt16 BE x ])
"""
      )
    , ( "Encode through functions that return a partial encoder"
      , """
encWith : Endianness -> (Int -> E.Encoder)
encWith e =
    E.unsignedInt16 e


wk : Int -> (Int -> E.Encoder)
wk a =
    Elm.Kernel.Bytes.write_u16 a


pick : Int -> (Int -> E.Encoder)
pick k =
    if k > 0 then
        E.unsignedInt8

    else
        E.signedInt8


testValue k x =
    E.encode (E.sequence [ encWith BE x, wk 1 x, pick k x, E.unsignedInt8 x ])
"""
      )
    ]
