module AggPromoteTupleTest exposing (main)

{-| U-T1.3.1 aggregate promotion (`plans/opt-tier1-aggregate-promotion.md`):
behavioral coverage for let-bound tuples that the per-def use walk proves
non-escaping. Under `ECO_AGG_PROMOTE=1` the promotable shapes below emit
`eco.make.tuple2/3` (no heap allocation); flag-off they take the heap path.
Results must be identical either way — this test runs in BOTH corpus
flavors and pins the behavior, not the encoding.

U-T1.3.2c: under `ECO_CTOR_INLINE=1` every saturated ctor call below
additionally emits its `eco.construct.custom` inline in the caller
(no ctor-function call). Behavior is again identical.

Shapes exercised:

  - promotable tuple2, all-primitive (Int, Int)
  - promotable tuple2, MIXED slots (Int unboxed + String boxed) — the
    REP_AGG_001 pointer-element case
  - promotable tuple3 (Int, Float, String)
  - multiple destructs of the same promoted binder
  - NEGATIVE: a tuple that escapes (returned from a helper) must stay on
    the heap path and still behave identically
  - NEGATIVE: a tuple passed to a call (escapes as an argument)

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
-- CHECK: tailpair: "3:6"
-- CHECK: tailboth: 19

import Html exposing (text)


{-| U-T1.3.2t: a LOOP-LOCAL tuple in a tail-recursive function — built and
consumed within one iteration; the TailRec real-body threading must let it
promote (a per-iteration allocation eliminated).
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


{-| U-T1.3.2t: loop-local single-ctor custom.
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


{-| U-T1.3.3L: the tuple is LOOP-CARRIED (a tail-call argument). Under
scalar-split loop variables the param `p` is carried as two slots, `q`
promotes to an aggregate (the tail-call step slot-extracts it), and the
per-iteration allocation disappears. Behavior identical either way.
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


{-| U-T1.3.3: a state-threading helper — returns a locally-constructed
MIXED pair (boxed String + unboxed Int) on every path. Under
`ECO_SRET_RESULTS=1` it gains a `$sret` worker (caller-slot ABI) and the
destructuring call sites below migrate to it — the pair container never
exists. Behavior identical either way.
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


{-| U-T1.3.3: a CASE-shaped candidate (every decider leaf constructs).
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


{-| U-T1.3.3: `Tuple.first/second` compile to Mono PROJECTIONS, so the
walker admits this too — the site migrates (an accidental positive; the
whole-use veto is covered by the walker unit tests).
-}
usePair : Int -> Int
usePair k =
    let
        p =
            nextId k
    in
    Tuple.second p + String.length (Tuple.first p)


{-| U-T1.3.6: a tail-recursive DOUBLE-ACCUMULATOR returning a pair — the
base case constructs the result. Promoted, the loop carries DECOMPOSED
result columns and the `$sret` worker multi-returns them; the
destructuring caller consumes slots. The mixed (String, Int) pair pins
the boxed-slot case.
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


{-| U-T1.3.6 + T1.3.3L composition: the loop param `p` is SPLIT
(carried as slots) AND the result is promoted — both representation
changes in one function.
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


{-| U-T1.3.5 (a): a projection-only pair consumer — under
`ECO_PSPLIT_PARAMS=1` it gains a `$psplit` worker taking the two fields
as scalars; the inline-literal caller's container never exists.
-}
pairMag : ( Int, Int ) -> Int
pairMag p =
    case p of
        ( x, y ) ->
            x * x + y * y


usePairMag : Int -> Int
usePairMag n =
    pairMag ( n, n + 1 )


{-| U-T1.3.5 (b): the let-bound tuple was previously VETOED (passed to a
call); the walker's call-position allowance now admits it — the binder
promotes to make-form and the site slot-projects it (SROA-free).
-}
usePairMagLet : Int -> Int
usePairMagLet n =
    let
        t =
            ( n * 2, n * 3 )
    in
    pairMag t


{-| U-T1.3.5 (c) NEGATIVE: returns its param whole — admissibility veto,
no worker; callers use the normal path.
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


{-| U-T1.3.5 (d): both params promoted but the second argument is a plain
boxed var (not slot-available) — migration aborts and the site calls the
re-boxing SHIM. Behavior identical.
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


{-| U-T1.3.5 custom variant: single-ctor 3-field State consumed by
projections only; the inline ctor-call argument's container vanishes.
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


{-| U-T1.3.3L: loop-CARRIED single-ctor custom state (the solveGo shape).
The split param destructs to slot reads; the fresh state `s2` promotes to
an `eco.make.custom` whose slots feed the tail call directly — no
per-iteration State allocation.
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


{-| U-T1.3.3L: carried custom with a BOXED slot (String), fed by an INLINE
ctor call in the tail position — the elements compile straight into the
slots and the per-iteration `Tk` allocation vanishes.
-}
tailTrack : Int -> Track -> String
tailTrack n t =
    case t of
        Tk k s ->
            if n <= 0 then
                String.fromInt k ++ s

            else
                tailTrack (n - 1) (Tk (k + n) s)


{-| U-T1.3.3L NEGATIVE: the carried tuple is ALSO used whole (`sumPair p`
each iteration) — the win gate vetoes the split (a split would
rematerialize `p` per use), and without the split the carried `q` stays
heap. Behavior identical regardless.
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


{-| T1.3.2: single-ctor custom built + cased locally — the ctor call AND
its allocation should vanish under promotion.
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


{-| T1.3.2: mixed slots (unboxed Int + boxed String).
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


{-| T1.3.2: Can.Unbox single-field wrapper (MonoUnbox projection path).
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


{-| NEGATIVE: the ctor value escapes into a call — stays heap.
-}
ctorEscaping : Int -> Int
ctorEscaping n =
    let
        p =
            MkIntPair n (n + 1)
    in
    sumIntPair p


{-| T1.3.1b: explicit `case t of (x, y) ->` — the scrutinee position.
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


{-| T1.3.1b: nested pattern — the element test (IsInt on field 0) must
project through the promoted root (a Chain test path over the aggregate).
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


{-| T1.3.1b: case over a MIXED-slot promoted tuple (boxed String element).
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


{-| The same promoted binder destructured twice (two MonoDestructs on one
promoted var — both must route through the aggregate projection).
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


{-| NEGATIVE: the tuple is returned — escapes; must not promote.
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


{-| NEGATIVE: the tuple is passed to a call — escapes as an argument.
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
            Debug.log "tailpair" (useTailAccPair 3)

        _ =
            Debug.log "tailboth" (useTailBoth 2)
    in
    text "done"
