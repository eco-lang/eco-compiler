module Control.Monad.State.Strict exposing
    ( StateT(..)
    , evalStateT
    , liftIO
    , put
    )

{-| Provides a computation over tasks that carries a value from step to step,
and a way to save the source text of a REPL session outside the program.

The carried value is called the _state_. A state computation, `StateT s a`,
takes the state it starts from, of type `s`, and gives back a task that produces
a result, of type `a`, together with the state to carry on with. The task cannot
fail. This is the state monad transformer of Haskell with the inner monad fixed
to `Task Never`. "Strict" is part of that name only: nothing here controls when
anything is evaluated.

Only two operations on state computations are defined here. `liftIO` makes one
from a task, and `evalStateT` runs one. Nothing here chains two state
computations, reads the state or replaces it.

`put` is not one of those operations, despite its name. It takes a
`System.IO.ReplState` and hands it to `Eco.Runtime.saveState` as JSON, and it
neither takes nor makes a `StateT`.


# State Transformer Type

@docs StateT


# Running Computations

@docs evalStateT


# Lifting

@docs liftIO


# Saving a REPL Session

@docs put

-}

import Eco.Runtime
import Json.Encode as Encode
import System.IO as IO
import Task exposing (Task)


{-| A computation that starts from a state of type `s` and gives a task
producing a result of type `a` together with the state to carry on with.

The constructor `StateT` is exposed and takes that function, so a computation
that does change the state can be built from one directly.

-}
type StateT s a
    = StateT (s -> Task Never ( a, s ))


{-| Runs a state computation from the given starting state, giving a task that
produces its result and drops the final state.
-}
evalStateT : StateT s a -> s -> Task Never a
evalStateT (StateT f) =
    f >> Task.map Tuple.first


{-| Makes a state computation that performs `io` and produces its result,
giving back the state it started from unchanged.
-}
liftIO : Task Never a -> StateT s a
liftIO io =
    StateT (\s -> Task.map (\a -> ( a, s )) io)


{-| Sends the source text of a REPL session to `Eco.Runtime.saveState`, to be
kept outside the program.

The value sent is a JSON object with the fields `imports`, `types` and `decls`,
holding the state's three dictionaries in that order, each as an object from a
name to its source text.

-}
put : IO.ReplState -> Task Never ()
put (IO.ReplState imports types decls) =
    Eco.Runtime.saveState
        (Encode.object
            [ ( "imports", Encode.dict identity Encode.string imports )
            , ( "types", Encode.dict identity Encode.string types )
            , ( "decls", Encode.dict identity Encode.string decls )
            ]
        )
