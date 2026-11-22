module CtorLoops exposing (benchKnown, benchMaybe, benchSret, benchStep, benchTokens, benchWrapper)

{-| Tight loops over custom-type values, one per constructor representation eco can choose, so
each workload's cost is mostly the constructor itself:

  - `ctor-wrapper`: `n` iterations that add into a `Total Int` and measure a `Label String`, two
    one-constructor wrappers (eco erases both, so neither is built).
  - `ctor-maybe`: `n` iterations that get a `Maybe Cell`, pass it through `Maybe.andThen` and
    match it (eco represents `Just c` as `c` itself).
  - `ctor-step`: a generic `Continue s | Finish a` driver run for `n` steps, whose state is a
    record (eco makes `Continue` the record's own word, tagged).
  - `ctor-tokens`: a list of `n` tokens of a four-constructor type, built and then scored (eco
    makes the one-field constructors their field's word, tagged).
  - `ctor-sret`: the digit count and sum of `0 .. n-1`, each by a non-tail recursion that returns
    a `Pair Int Int` (eco returns it through a slot of the caller's).
  - `ctor-known`: `n` iterations of a `case` on `Rect` and `Square` values built in place (eco
    folds a `case` on a value whose constructor is known).

Each is checked at every size against the same figure computed with `Int`s only.

-}


-- ctor-wrapper


type Total
    = Total Int


type Label
    = Label String


addTotal : Total -> Int -> Total
addTotal (Total t) i =
    Total (t + modBy 7 i)


labelFor : Int -> Label
labelFor i =
    if modBy 2 i == 0 then
        Label "even"

    else
        Label "odd"


labelLength : Label -> Int
labelLength (Label s) =
    String.length s


wrapperLoop : Int -> Int -> Total -> Int -> Int
wrapperLoop n i total lengths =
    if i >= n then
        let
            (Total t) =
                total
        in
        t + lengths

    else
        wrapperLoop n (i + 1) (addTotal total i) (lengths + labelLength (labelFor i))


wrapperExpected : Int -> Int -> Int -> Int
wrapperExpected n i acc =
    if i >= n then
        acc

    else
        wrapperExpected n
            (i + 1)
            (acc
                + modBy 7 i
                + (if modBy 2 i == 0 then
                    4

                   else
                    3
                  )
            )


benchWrapper : Int -> Bool
benchWrapper n =
    wrapperLoop n 0 (Total 0) 0 == wrapperExpected n 0 0



-- ctor-maybe


type alias Cell =
    { weight : Int, name : String }


light : Cell
light =
    { weight = 2, name = "light" }


heavy : Cell
heavy =
    { weight = 5, name = "heavy" }


pick : Int -> Maybe Cell
pick i =
    case modBy 3 i of
        0 ->
            Nothing

        1 ->
            Just light

        _ ->
            Just heavy


heavier : Cell -> Maybe Cell
heavier c =
    if c.weight > 2 then
        Just c

    else
        Nothing


maybeLoop : Int -> Int -> Int -> Int
maybeLoop n i acc =
    if i >= n then
        acc

    else
        case Maybe.andThen heavier (pick i) of
            Nothing ->
                maybeLoop n (i + 1) (acc + 1)

            Just c ->
                maybeLoop n (i + 1) (acc + c.weight)


maybeExpected : Int -> Int -> Int -> Int
maybeExpected n i acc =
    if i >= n then
        acc

    else
        maybeExpected n
            (i + 1)
            (acc
                + (if modBy 3 i == 2 then
                    5

                   else
                    1
                  )
            )


benchMaybe : Int -> Bool
benchMaybe n =
    maybeLoop n 0 0 == maybeExpected n 0 0



-- ctor-step


type Step s a
    = Continue s
    | Finish a


iterate : (s -> Step s a) -> s -> a
iterate f s =
    case f s of
        Continue next ->
            iterate f next

        Finish a ->
            a


type alias StepState =
    { i : Int, n : Int, acc : Int }


step : StepState -> Step StepState Int
step st =
    if st.i >= st.n then
        Finish st.acc

    else
        Continue { st | i = st.i + 1, acc = st.acc + modBy 11 st.i }


stepExpected : Int -> Int -> Int -> Int
stepExpected n i acc =
    if i >= n then
        acc

    else
        stepExpected n (i + 1) (acc + modBy 11 i)


benchStep : Int -> Bool
benchStep n =
    iterate step { i = 0, n = n, acc = 0 } == stepExpected n 0 0



-- ctor-tokens


type Token
    = Word String
    | Sym String
    | Group (List Token)
    | Gap


tokenFor : Int -> Token
tokenFor i =
    case modBy 4 i of
        0 ->
            Word
                (if modBy 8 i == 0 then
                    "alpha"

                 else
                    "be"
                )

        1 ->
            Sym "+"

        2 ->
            Group [ Word "a", Gap ]

        _ ->
            Gap


score : Token -> Int
score t =
    case t of
        Word s ->
            String.length s

        Sym _ ->
            1

        Group ts ->
            10 + List.length ts

        Gap ->
            0


tokensExpected : Int -> Int -> Int -> Int
tokensExpected n i acc =
    if i >= n then
        acc

    else
        tokensExpected n
            (i + 1)
            (acc
                + (case modBy 4 i of
                    0 ->
                        if modBy 8 i == 0 then
                            5

                        else
                            2

                    1 ->
                        1

                    2 ->
                        12

                    _ ->
                        0
                  )
            )


benchTokens : Int -> Bool
benchTokens n =
    (List.range 0 (n - 1) |> List.map tokenFor |> List.foldl (\t acc -> acc + score t) 0)
        == tokensExpected n 0 0



-- ctor-sret


type Pair
    = Pair Int Int


digitStats : Int -> Pair
digitStats x =
    if x < 10 then
        Pair 1 x

    else
        let
            (Pair count sum) =
                digitStats (x // 10)
        in
        Pair (count + 1) (sum + modBy 10 x)


sretLoop : Int -> Int -> Int -> Int
sretLoop n i acc =
    if i >= n then
        acc

    else
        let
            (Pair count sum) =
                digitStats i
        in
        sretLoop n (i + 1) (acc + count * 100 + sum)


digitCount : Int -> Int -> Int
digitCount x c =
    if x < 10 then
        c + 1

    else
        digitCount (x // 10) (c + 1)


digitSum : Int -> Int -> Int
digitSum x s =
    if x < 10 then
        s + x

    else
        digitSum (x // 10) (s + modBy 10 x)


sretExpected : Int -> Int -> Int -> Int
sretExpected n i acc =
    if i >= n then
        acc

    else
        sretExpected n (i + 1) (acc + digitCount i 0 * 100 + digitSum i 0)


benchSret : Int -> Bool
benchSret n =
    sretLoop n 0 0 == sretExpected n 0 0



-- ctor-known


type Shape
    = Rect Int Int
    | Square Int


area : Shape -> Int
area s =
    case s of
        Rect w h ->
            w * h

        Square side ->
            side * side


knownLoop : Int -> Int -> Int -> Int
knownLoop n i acc =
    if i >= n then
        acc

    else
        knownLoop n (i + 1) (acc + area (Rect (modBy 100 i) 3) + area (Square (modBy 13 i)))


knownExpected : Int -> Int -> Int -> Int
knownExpected n i acc =
    if i >= n then
        acc

    else
        knownExpected n (i + 1) (acc + modBy 100 i * 3 + modBy 13 i * modBy 13 i)


benchKnown : Int -> Bool
benchKnown n =
    knownLoop n 0 0 == knownExpected n 0 0
