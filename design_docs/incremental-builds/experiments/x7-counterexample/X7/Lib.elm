module X7.Lib exposing (Op(..), applyTwice, mkLib, run, runAll)

{-| Lower module: defines a type whose payload is a function, constructs it
with its OWN lambda, and destructures values it receives from importers.
Under requester ownership `run`/`runAll` are owned by X7.Lib; the
`Op (\x -> x * 3)` construction in the importer is owned by the importer.
-}


type Op
    = Op (Int -> Int)


mkLib : Int -> Op
mkLib k =
    Op (\x -> x + k)


run : Op -> Int -> Int
run op x =
    case op of
        Op f ->
            f x


runAll : List Op -> Int -> List Int
runAll ops x =
    List.map (\op -> run op x) ops


applyTwice : (a -> a) -> a -> a
applyTwice f x =
    f (f x)
