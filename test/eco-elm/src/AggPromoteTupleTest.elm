module AggPromoteTupleTest exposing (main)

{-| Tuples and single-constructor custom types give the right results when built, destructured, passed to functions, returned, and carried through tail-recursive loops.

The program covers, among others:

  - tuples of `Int`s, of mixed `Int` and `String`, and of three elements,
    built in a `let` and destructured by a `let` pattern or a `case`;
  - one tuple destructured twice, and a `case` with a literal in a tuple
    pattern;
  - tuples and custom-type values returned from a function or passed to one;
  - functions that return a pair from every branch, including from a call
    to another pair-returning function;
  - tail-recursive functions that build a tuple or custom-type value on each
    iteration, pass one as the accumulator, or return a pair.

## eco

Exercises aggregate promotion and its follow-ons (plans/opt-tier1-aggregate-promotion.md): let-bound tuples and single-constructor values that do not escape become SSA aggregates (`eco.make.tuple2/3`, `eco.make.custom`) instead of heap objects, per REP_AGG_001 in design_docs/invariants.csv. The mixed `( Int, String )` shapes pin the case where one slot is unboxed and one is a boxed pointer.

The helpers cover each promotion route: loop-local and loop-carried values in tail-recursive functions (scalar-split loop variables, compiler/src/Compiler/GenerateMlir/TailRec.elm); pair-returning functions that gain a `$sret` worker and pair-consuming functions that gain a `$psplit` worker (compiler/src/Compiler/GenerateMlir/Expr.elm); the selection fixpoint that admits forwarding chains; and inline constructor calls. Helpers marked NEGATIVE in their docstrings must stay on the heap path (the value escapes, is returned or is used whole).

The flags in compiler/src/Builder/Eco/Config.elm (`ECO_AGG_PROMOTE`, `ECO_SRET_RESULTS`, ...) change only the encoding, so every CHECK line must print the same with promotion on or off.

-}

-- CHECK: primsum: 42
-- CHECK: mixed: "n=7:seven"
-- CHECK: triple: "x=3 y=2.5 s=tri"
-- CHECK: twice: 21
-- CHECK: escaped: 15
-- CHECK: passed: 9
-- CHECK: casesum: 25
-- CHECK: casenested: 12
-- CHECK: casemixed: "8/eight"
-- CHECK: ctorsum: 33
-- CHECK: ctormixed: "9=nine"
-- CHECK: ctorwrap: 14
-- CHECK: ctorescape: 11
-- CHECK: tailloc: 45
-- CHECK: tailctor: 15
-- CHECK: tailcarried: 2
-- CHECK: tailstate: 32
-- CHECK: tailtrack: "6z"
-- CHECK: tailpeek: 6
-- CHECK: nextids: "id7id89"
-- CHECK: sumsplit: 15
-- CHECK: usepair: 7
-- CHECK: psplitmag: 25
-- CHECK: psplitlet: 52
-- CHECK: psplitid: 11
-- CHECK: psplitpartial: 14
-- CHECK: psplitst: 12
-- CHECK: psplitchain: 53
-- CHECK: psplitsret: 135
-- CHECK: psplitneg: 7
-- CHECK: sretfresh: 128
-- CHECK: sretmix: 24
-- CHECK: sretnegv: 8
-- CHECK: tailpair: "3:6"
-- CHECK: tailboth: 19

import Html exposing (text)


{-| Returns `acc` plus `3 * k` for each `k` from 1 to `n`, building a tuple and
destructuring it on each iteration.
-}
tailLocal : Int -> Int -> Int
tailLocal n acc =
    if n <= 0 then
        acc

    else
        let
            t =
                ( n, n * 2 )
        in
        case t of
            ( x, y ) ->
                tailLocal (n - 1) (acc + x + y)


{-| Returns `acc` plus `2 * k + 1` for each `k` from 1 to `n`, building an `IntPair`
and destructuring it on each iteration.
-}
tailCtor : Int -> Int -> Int
tailCtor n acc =
    if n <= 0 then
        acc

    else
        let
            p =
                MkIntPair n (n + 1)
        in
        case p of
            MkIntPair x y ->
                tailCtor (n - 1) (acc + x + y)


{-| Returns the sum of the pair passed on the last iteration, which is `( 1, 1 )`
when `n` starts positive. The pair is a tail-call argument rebuilt on each
iteration.
-}
tailCarried : Int -> ( Int, Int ) -> Int
tailCarried n p =
    if n <= 0 then
        case p of
            ( a, b ) ->
                a + b

    else
        let
            q =
                ( n, n )
        in
        tailCarried (n - 1) q


{-| Returns an identifier string built from `n`, paired with the next number.
-}
nextId : Int -> ( String, Int )
nextId n =
    ( "id" ++ String.fromInt n, n + 1 )


genIds : Int -> String
genIds k =
    let
        ( a, k1 ) =
            nextId k

        ( b, k2 ) =
            nextId k1
    in
    a ++ b ++ String.fromInt k2


{-| Returns `( 0, 0 )` for 0 and `( n, n * 2 )` otherwise, so each branch of the
`case` builds a pair.
-}
splitSign : Int -> ( Int, Int )
splitSign n =
    case n of
        0 ->
            ( 0, 0 )

        _ ->
            ( n, n * 2 )


sumSplit : Int -> Int
sumSplit n =
    let
        ( x, y ) =
            splitSign n
    in
    x + y


{-| Returns the number and the identifier length from `nextId k`, added together,
reading the pair with `Tuple.first` and `Tuple.second`.
-}
usePair : Int -> Int
usePair k =
    let
        p =
            nextId k
    in
    Tuple.second p + String.length (Tuple.first p)


{-| Returns the number of iterations as a string, paired with `total` plus the sum
of 1 to `n`. Only the base case builds the pair.
-}
tailAccPair : Int -> Int -> Int -> ( String, Int )
tailAccPair n cnt total =
    case n of
        0 ->
            ( String.fromInt cnt, total )

        _ ->
            tailAccPair (n - 1) (cnt + 1) (total + n)


useTailAccPair : Int -> String
useTailAccPair n =
    let
        ( label, total ) =
            tailAccPair n 0 0
    in
    label ++ ":" ++ String.fromInt total


{-| Returns the sum and the product of the pair after adding `n` to each of its
parts. The pair is both the tail-call argument and the result.
-}
tailBoth : Int -> ( Int, Int ) -> ( Int, Int )
tailBoth n p =
    case p of
        ( a, b ) ->
            case n of
                0 ->
                    ( a + b, a * b )

                _ ->
                    tailBoth (n - 1) ( a + 1, b + 1 )


useTailBoth : Int -> Int
useTailBoth n =
    let
        ( s, m ) =
            tailBoth n ( 1, 2 )
    in
    s + m


{-| Returns the sum of the squares of the two parts of a pair.
-}
pairMag : ( Int, Int ) -> Int
pairMag p =
    case p of
        ( x, y ) ->
            x * x + y * y


usePairMag : Int -> Int
usePairMag n =
    pairMag ( n, n + 1 )


{-| Returns `pairMag` of a pair bound in a `let`.
-}
usePairMagLet : Int -> Int
usePairMagLet n =
    let
        t =
            ( n * 2, n * 3 )
    in
    pairMag t


{-| Returns the pair it is given, unchanged.
-}
pairId : ( Int, Int ) -> ( Int, Int )
pairId p =
    p


usePairId : Int -> Int
usePairId n =
    let
        ( a, b ) =
            pairId ( n, n + 1 )
    in
    a + b


{-| Returns the dot product of two pairs.
-}
pairBoth : ( Int, Int ) -> ( Int, Int ) -> Int
pairBoth p q =
    case p of
        ( px, py ) ->
            case q of
                ( qx, qy ) ->
                    px * qx + py * qy


useBothPartial : Int -> ( Int, Int ) -> Int
useBothPartial k q =
    pairBoth ( k, k ) q


{-| Returns `pairMag` of its argument plus 1, passing the pair on unchanged.
-}
chainOuter : ( Int, Int ) -> Int
chainOuter p =
    pairMag p + 1


useChain : Int -> Int
useChain n =
    chainOuter ( n, n + 2 )


{-| Returns `( n * 3, n + 4 )`.
-}
pairFromSret : Int -> ( Int, Int )
pairFromSret n =
    ( n * 3, n + 4 )


pairDot : ( Int, Int ) -> Int
pairDot p =
    case p of
        ( x, y ) ->
            x * y


useSretBinder : Int -> Int
useSretBinder n =
    let
        t =
            pairFromSret n
    in
    pairDot t


{-| Returns one more than the first part of the pair, using the whole pair as a list
element.
-}
wholeSink : ( Int, Int ) -> Int
wholeSink p =
    List.length [ p ] + Tuple.first p


fwdWhole : ( Int, Int ) -> Int
fwdWhole p =
    wholeSink p


useFwdWhole : Int -> Int
useFwdWhole n =
    fwdWhole ( n, n * 5 )


{-| Returns the pair `pairFromSret` builds from `n + 1`.
-}
midPair : Int -> ( Int, Int )
midPair n =
    pairFromSret (n + 1)


useFresh : Int -> Int
useFresh n =
    let
        ( a, b ) =
            midPair n
    in
    a * 10 + b


{-| Returns a pair built here for even `n`, and the result of `pairFromSret` for odd
`n`.
-}
mixedPair : Int -> ( Int, Int )
mixedPair n =
    case modBy 2 n of
        0 ->
            ( n, n + 1 )

        _ ->
            pairFromSret n


useMixed : Int -> Int
useMixed n =
    let
        ( a, b ) =
            mixedPair n
    in
    a + b


{-| Returns `( n, n )` by way of `pairId`.
-}
viaId : Int -> ( Int, Int )
viaId n =
    pairId ( n, n )


useViaId : Int -> Int
useViaId n =
    let
        ( a, b ) =
            viaId n
    in
    a + b


{-| Returns the sum of the three fields of a `State`.
-}
stSum : State -> Int
stSum s =
    case s of
        St a b c ->
            a + b + c


useStSum : Int -> Int
useStSum n =
    stSum (St n (n + 1) (n + 2))


type State
    = St Int Int Int


{-| Returns a weighted sum of the fields of a `State` that is rebuilt and carried
through each iteration.
-}
tailState : Int -> State -> Int
tailState n s =
    case s of
        St a b c ->
            if n <= 0 then
                a + b * 2 + c * 3

            else
                let
                    s2 =
                        St (a + n) (b + 1) c
                in
                tailState (n - 1) s2


type Track
    = Tk Int String


{-| Returns the number in `t`, increased by the sum of 1 to `n`, followed by its
string. A new `Tk` is built directly in each tail call.
-}
tailTrack : Int -> Track -> String
tailTrack n t =
    case t of
        Tk k s ->
            if n <= 0 then
                String.fromInt k ++ s

            else
                tailTrack (n - 1) (Tk (k + n) s)


{-| Returns the sum of a carried pair whose second part is the sum of the previous
pair, so the pair is both carried and used whole on each iteration.
-}
tailPeek : Int -> ( Int, Int ) -> Int
tailPeek n p =
    if n <= 0 then
        sumPair p

    else
        let
            q =
                ( n, sumPair p )
        in
        tailPeek (n - 1) q


type IntPair
    = MkIntPair Int Int


type Labeled
    = MkLabeled Int String


type Wrapped
    = Wrap Int


{-| Returns `a * 2 + b * 3`, building an `IntPair` in a `let` and destructuring it
with `case`.
-}
ctorLocal : Int -> Int -> Int
ctorLocal a b =
    let
        p =
            MkIntPair (a * 2) (b * 3)
    in
    case p of
        MkIntPair x y ->
            x + y


{-| Returns `n + 2` and `s` joined by `=`, through a `Labeled` value built and
destructured locally.
-}
ctorMixed : Int -> String -> String
ctorMixed n s =
    let
        l =
            MkLabeled (n + 2) s
    in
    case l of
        MkLabeled num str ->
            String.fromInt num ++ "=" ++ str


{-| Returns `n * 2`, through a `Wrapped` value built and destructured locally.
-}
ctorWrapped : Int -> Int
ctorWrapped n =
    let
        w =
            Wrap (n * 2)
    in
    case w of
        Wrap inner ->
            inner


sumIntPair : IntPair -> Int
sumIntPair p =
    case p of
        MkIntPair x y ->
            x + y


{-| Returns `2 * n + 1`, passing a locally built `IntPair` to `sumIntPair`.
-}
ctorEscaping : Int -> Int
ctorEscaping n =
    let
        p =
            MkIntPair n (n + 1)
    in
    sumIntPair p


{-| Returns `a * 2 + b * 3`, destructuring a let-bound tuple with `case`.
-}
casePromotable : Int -> Int -> Int
casePromotable a b =
    let
        t =
            ( a * 2, b * 3 )
    in
    case t of
        ( x, y ) ->
            x + y


{-| Returns `n * 2` when `n` is 0 and `n + 6` otherwise, matching a let-bound tuple
against a pattern with a literal in it.
-}
caseNested : Int -> Int
caseNested n =
    let
        t =
            ( n, n * 2 )
    in
    case t of
        ( 0, y ) ->
            y

        ( x, _ ) ->
            x + 6


{-| Returns `n + 1` and `s` joined by `/`, destructuring a let-bound mixed tuple
with `case`.
-}
caseMixed : Int -> String -> String
caseMixed n s =
    let
        t =
            ( n + 1, s )
    in
    case t of
        ( num, str ) ->
            String.fromInt num ++ "/" ++ str


promotablePrims : Int -> Int -> Int
promotablePrims a b =
    let
        t =
            ( a * 2, b * 3 )

        ( x, y ) =
            t
    in
    x + y


promotableMixed : Int -> String -> String
promotableMixed n s =
    let
        t =
            ( n, s )

        ( num, str ) =
            t
    in
    "n=" ++ String.fromInt num ++ ":" ++ str


promotableTriple : Int -> Float -> String -> String
promotableTriple i f s =
    let
        t =
            ( i, f, s )

        ( x, y, z ) =
            t
    in
    "x=" ++ String.fromInt x ++ " y=" ++ String.fromFloat y ++ " s=" ++ z


{-| Returns `n * 3`, destructuring the same let-bound tuple twice, taking a
different part each time.
-}
promotableTwice : Int -> Int
promotableTwice n =
    let
        t =
            ( n, n * 2 )

        ( a, _ ) =
            t

        ( _, b ) =
            t
    in
    a + b


{-| Returns `( n, n + 1 )` through a let-bound tuple.
-}
escapingTuple : Int -> ( Int, Int )
escapingTuple n =
    let
        t =
            ( n, n + 1 )
    in
    t


useEscaping : Int -> Int
useEscaping n =
    case escapingTuple n of
        ( a, b ) ->
            a + b


{-| Returns the sum of the two parts of a pair.
-}
sumPair : ( Int, Int ) -> Int
sumPair p =
    case p of
        ( a, b ) ->
            a + b


passedTuple : Int -> Int
passedTuple n =
    let
        t =
            ( n, n * 2 )
    in
    sumPair t


main =
    let
        _ =
            Debug.log "primsum" (promotablePrims 6 10)

        _ =
            Debug.log "mixed" (promotableMixed 7 "seven")

        _ =
            Debug.log "triple" (promotableTriple 3 2.5 "tri")

        _ =
            Debug.log "twice" (promotableTwice 7)

        _ =
            Debug.log "escaped" (useEscaping 7)

        _ =
            Debug.log "passed" (passedTuple 3)

        _ =
            Debug.log "casesum" (casePromotable 5 5)

        _ =
            Debug.log "casenested" (caseNested 6)

        _ =
            Debug.log "casemixed" (caseMixed 7 "eight")

        _ =
            Debug.log "ctorsum" (ctorLocal 6 7)

        _ =
            Debug.log "ctormixed" (ctorMixed 7 "nine")

        _ =
            Debug.log "ctorwrap" (ctorWrapped 7)

        _ =
            Debug.log "ctorescape" (ctorEscaping 5)

        _ =
            Debug.log "tailloc" (tailLocal 5 0)

        _ =
            Debug.log "tailctor" (tailCtor 3 0)

        _ =
            Debug.log "tailcarried" (tailCarried 3 ( 0, 0 ))

        _ =
            Debug.log "tailstate" (tailState 4 (St 1 2 3))

        _ =
            Debug.log "tailtrack" (tailTrack 3 (Tk 0 "z"))

        _ =
            Debug.log "tailpeek" (tailPeek 3 ( 0, 0 ))

        _ =
            Debug.log "nextids" (genIds 7)

        _ =
            Debug.log "sumsplit" (sumSplit 5)

        _ =
            Debug.log "usepair" (usePair 3)

        _ =
            Debug.log "psplitmag" (usePairMag 3)

        _ =
            Debug.log "psplitlet" (usePairMagLet 2)

        _ =
            Debug.log "psplitid" (usePairId 5)

        _ =
            Debug.log "psplitpartial" (useBothPartial 2 ( 3, 4 ))

        _ =
            Debug.log "psplitst" (useStSum 3)

        _ =
            Debug.log "psplitchain" (useChain 4)

        _ =
            Debug.log "psplitsret" (useSretBinder 5)

        _ =
            Debug.log "psplitneg" (useFwdWhole 6)

        _ =
            Debug.log "sretfresh" (useFresh 3)

        _ =
            Debug.log "sretmix" (useMixed 5)

        _ =
            Debug.log "sretnegv" (useViaId 4)

        _ =
            Debug.log "tailpair" (useTailAccPair 3)

        _ =
            Debug.log "tailboth" (useTailBoth 2)
    in
    text "done"
