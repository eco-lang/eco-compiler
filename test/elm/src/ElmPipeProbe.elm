module ElmPipeProbe exposing (main)

{-| Lever-4 bisection control: the SAME producer/consumer payload shapes as
LssGapKernelPipeline but with an ALL-ELM combinator (no kernels anywhere on
the chain). If this covers, the kernel path is implicated; if it also fails,
the leak is the generic inference call path (A.1).
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
