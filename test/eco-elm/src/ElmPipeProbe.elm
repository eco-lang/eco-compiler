module ElmPipeProbe exposing (main)

{-| A partially applied constructor carried inside a custom type can later be
applied to its remaining argument.

`makePair` maps the two-argument constructor `Pair` over `Box 1`, giving a
`Box` holding `Pair 1`. `consume` unwraps it, applies it to 2 and sums the two
fields, so the logged value is 3. The file has no CHECK line, so only the
program compiling and running is checked.

## eco

A bisection control for test/eco-elm/src/LssGapKernelPipeline.elm: the same producer and consumer payload shapes, but the combinator is plain Elm with no kernel function on the chain. If this program is covered by lambda-set specialisation and that one is not, the kernel path is implicated; if both fail, the gap is in the generic call path of inference.

-}

import Html exposing (text)


type Box a
    = Box a


type Pair
    = Pair Int Int


pairValue : Pair -> Int
pairValue (Pair a b) =
    a + b


mapB : (a -> b) -> Box a -> Box b
mapB f (Box x) =
    Box (f x)


makePair : Box (Int -> Pair)
makePair =
    mapB Pair (Box 1)


consume : Box (Int -> Pair) -> Int
consume (Box f) =
    pairValue (f 2)


main =
    let
        _ =
            Debug.log "elmPipe" (consume makePair)
    in
    text "hello"
