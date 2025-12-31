module Compiler.Type.Constrain.Typed.Program exposing
    ( ProgS(..), InstrS(..)
    , pureS, mapS, andThenS
    , runS
    , opMkFlexVarS, opMkFlexNumberS
    , opGetS, opModifyS
    , opIOS
    )

{-| Defunctionalized DSL for constraint generation with state (Typed pathway).

This module provides a stateful, stack-safe way to build type constraints.
The `ProgS` type extends the basic program type with state threading,
enabling expression ID tracking during constraint generation.

The stateful variant tracks expression ID to solver variable mappings,
which are needed for TypedCanonical AST construction.


# Stateful Program Type

@docs ProgS, InstrS


# Stateful Monad Operations

@docs pureS, mapS, andThenS


# Running Stateful Programs

@docs runS


# Stateful Smart Constructors

@docs opMkFlexVarS, opMkFlexNumberS
@docs opGetS, opModifyS
@docs opIOS

-}

import Compiler.Type.Type as Type exposing (Constraint)
import System.TypeCheck.IO as IO exposing (IO)



-- STATEFUL PROGRAM TYPE


{-| A stateful program that threads state through constraint generation.

Used by constrainWithIds to track expression ID to type variable mappings.

  - `DoneS a` - Computation complete with value `a`
  - `StepS instr` - One instruction to execute, with continuation

-}
type ProgS s a
    = DoneS a
    | StepS (InstrS s a)


{-| One instruction in the stateful constraint DSL.

  - `MkFlexVarS k` - Allocate a fresh flex var, continue with `k var`
  - `MkFlexNumberS k` - Allocate a fresh number var, continue with `k var`
  - `GetStateS k` - Get current state, continue with `k state`
  - `ModifyStateS f k` - Modify state with function f, continue with `k ()`
  - `RunIOS io` - Run an IO action, wrapping the result

-}
type InstrS s a
    = MkFlexVarS (IO.Variable -> ProgS s a)
    | MkFlexNumberS (IO.Variable -> ProgS s a)
    | GetStateS (s -> ProgS s a)
    | ModifyStateS (s -> s) (() -> ProgS s a)
    | RunIOS (IO (ProgS s a))



-- STATEFUL MONAD OPERATIONS


{-| Lift a pure value into the stateful program.
-}
pureS : a -> ProgS s a
pureS =
    DoneS


{-| Map a function over the stateful program result.
-}
mapS : (a -> b) -> ProgS s a -> ProgS s b
mapS f prog =
    case prog of
        DoneS a ->
            DoneS (f a)

        StepS instr ->
            StepS (mapInstrS f instr)


{-| Sequence two stateful programs, passing the result of the first to the second.
-}
andThenS : (a -> ProgS s b) -> ProgS s a -> ProgS s b
andThenS k prog =
    case prog of
        DoneS a ->
            k a

        StepS instr ->
            StepS (bindInstrS k instr)


{-| Map over stateful instruction continuations.
-}
mapInstrS : (a -> b) -> InstrS s a -> InstrS s b
mapInstrS f instr =
    case instr of
        MkFlexVarS k ->
            MkFlexVarS (k >> mapS f)

        MkFlexNumberS k ->
            MkFlexNumberS (k >> mapS f)

        GetStateS k ->
            GetStateS (k >> mapS f)

        ModifyStateS g cont ->
            ModifyStateS g (cont >> mapS f)

        RunIOS io ->
            RunIOS (IO.map (mapS f) io)


{-| Bind over stateful instruction continuations.
-}
bindInstrS : (a -> ProgS s b) -> InstrS s a -> InstrS s b
bindInstrS f instr =
    case instr of
        MkFlexVarS k ->
            MkFlexVarS (k >> andThenS f)

        MkFlexNumberS k ->
            MkFlexNumberS (k >> andThenS f)

        GetStateS k ->
            GetStateS (k >> andThenS f)

        ModifyStateS g cont ->
            ModifyStateS g (cont >> andThenS f)

        RunIOS io ->
            RunIOS (IO.map (andThenS f) io)



-- STATEFUL SMART CONSTRUCTORS


{-| Allocate a fresh flexible type variable (stateful version).
-}
opMkFlexVarS : ProgS s IO.Variable
opMkFlexVarS =
    StepS (MkFlexVarS DoneS)


{-| Allocate a fresh flexible number type variable (stateful version).
-}
opMkFlexNumberS : ProgS s IO.Variable
opMkFlexNumberS =
    StepS (MkFlexNumberS DoneS)


{-| Get the current state.
-}
opGetS : ProgS s s
opGetS =
    StepS (GetStateS DoneS)


{-| Modify the state with a function.
-}
opModifyS : (s -> s) -> ProgS s ()
opModifyS f =
    StepS (ModifyStateS f (\() -> DoneS ()))


{-| Run an IO action that produces a value, then continue (stateful version).
-}
opIOS : IO a -> ProgS s a
opIOS io =
    StepS (RunIOS (IO.map DoneS io))



-- STATEFUL INTERPRETER


{-| Run a stateful constraint program to produce an IO (Constraint, state).

Uses `IO.loop` to interpret the program with an explicit continuation stack,
ensuring constant stack depth regardless of program complexity.

-}
runS : s -> ProgS s Constraint -> IO ( Constraint, s )
runS state0 prog0 =
    IO.loop stepS ( prog0, state0, [] )


{-| Frame type for the stateful continuation stack.
-}
type FrameS s
    = FrameS (Constraint -> ProgS s Constraint)


{-| One step of the stateful interpreter.
-}
stepS : ( ProgS s Constraint, s, List (FrameS s) ) -> IO (IO.Step ( ProgS s Constraint, s, List (FrameS s) ) ( Constraint, s ))
stepS ( prog, state, stack ) =
    case prog of
        DoneS value ->
            case stack of
                [] ->
                    IO.pure (IO.Done ( value, state ))

                (FrameS k) :: rest ->
                    IO.pure (IO.Loop ( k value, state, rest ))

        StepS instr ->
            stepInstrS instr state stack


{-| Execute one stateful instruction and return the next loop state.
-}
stepInstrS : InstrS s Constraint -> s -> List (FrameS s) -> IO (IO.Step ( ProgS s Constraint, s, List (FrameS s) ) ( Constraint, s ))
stepInstrS instr state stack =
    case instr of
        MkFlexVarS k ->
            Type.mkFlexVar
                |> IO.map (\var -> IO.Loop ( k var, state, stack ))

        MkFlexNumberS k ->
            Type.mkFlexNumber
                |> IO.map (\var -> IO.Loop ( k var, state, stack ))

        GetStateS k ->
            IO.pure (IO.Loop ( k state, state, stack ))

        ModifyStateS f cont ->
            IO.pure (IO.Loop ( cont (), f state, stack ))

        RunIOS io ->
            io
                |> IO.map (\nextProg -> IO.Loop ( nextProg, state, stack ))
