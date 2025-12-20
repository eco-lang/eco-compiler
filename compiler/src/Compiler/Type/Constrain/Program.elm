module Compiler.Type.Constrain.Program exposing
    ( Prog(..), Instr(..)
    , pure, map, andThen
    , run
    , opMkFlexVar, opMkFlexNumber
    , opIO
      -- Stateful DSL for constrainWithIds
    , ProgS(..), InstrS(..)
    , pureS, mapS, andThenS
    , runS
    , opMkFlexVarS, opMkFlexNumberS
    , opGetS, opModifyS
    , opIOS
    )

{-| Defunctionalized DSL for constraint generation.

This module provides a stack-safe way to build type constraints by representing
constraint-generation steps as data rather than nested closures. The `Prog` type
captures operations like "allocate a flex var" as instructions that are
interpreted by a tail-recursive loop.

The key insight is that deeply nested `IO.andThen` chains grow the JavaScript
call stack proportionally to AST depth. By reifying these operations as data
and interpreting them with an explicit continuation stack, we maintain constant
stack depth regardless of AST complexity.


# Program Type

@docs Prog, Instr


# Monad Operations

@docs pure, map, andThen


# Running Programs

@docs run


# Smart Constructors

@docs opMkFlexVar, opMkFlexNumber
@docs opIO


# Stateful Program Type (for constrainWithIds)

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



-- PROGRAM TYPE


{-| A program representing constraint-generation steps.

  - `Done a` - Computation complete with value `a`
  - `Step instr` - One instruction to execute, with continuation

-}
type Prog a
    = Done a
    | Step (Instr a)


{-| One instruction in the constraint DSL.

Each instruction captures the operation to perform and a continuation
that receives the result and produces the next program.

  - `MkFlexVar k` - Allocate a fresh flex var, continue with `k var`
  - `MkFlexNumber k` - Allocate a fresh number var, continue with `k var`
  - `RunIO io` - Run an IO action, wrapping the result in Done

-}
type Instr a
    = MkFlexVar (IO.Variable -> Prog a)
    | MkFlexNumber (IO.Variable -> Prog a)
    | RunIO (IO (Prog a))



-- MONAD OPERATIONS


{-| Lift a pure value into the program.
-}
pure : a -> Prog a
pure =
    Done


{-| Map a function over the program result.
-}
map : (a -> b) -> Prog a -> Prog b
map f prog =
    case prog of
        Done a ->
            Done (f a)

        Step instr ->
            Step (mapInstr f instr)


{-| Sequence two programs, passing the result of the first to the second.
-}
andThen : (a -> Prog b) -> Prog a -> Prog b
andThen k prog =
    case prog of
        Done a ->
            k a

        Step instr ->
            Step (bindInstr k instr)


{-| Map over instruction continuations.
-}
mapInstr : (a -> b) -> Instr a -> Instr b
mapInstr f instr =
    case instr of
        MkFlexVar k ->
            MkFlexVar (k >> map f)

        MkFlexNumber k ->
            MkFlexNumber (k >> map f)

        RunIO io ->
            RunIO (IO.map (map f) io)


{-| Bind over instruction continuations.
-}
bindInstr : (a -> Prog b) -> Instr a -> Instr b
bindInstr f instr =
    case instr of
        MkFlexVar k ->
            MkFlexVar (k >> andThen f)

        MkFlexNumber k ->
            MkFlexNumber (k >> andThen f)

        RunIO io ->
            RunIO (IO.map (andThen f) io)



-- SMART CONSTRUCTORS


{-| Allocate a fresh flexible type variable.
-}
opMkFlexVar : Prog IO.Variable
opMkFlexVar =
    Step (MkFlexVar Done)


{-| Allocate a fresh flexible number type variable.
-}
opMkFlexNumber : Prog IO.Variable
opMkFlexNumber =
    Step (MkFlexNumber Done)


{-| Run an IO action that produces a value, then continue.
This is used to delegate to existing IO-based functions.
-}
opIO : IO a -> Prog a
opIO io =
    Step (RunIO (IO.map Done io))



-- INTERPRETER


{-| Run a constraint program to produce an IO Constraint.

Uses `IO.loop` to interpret the program with an explicit continuation stack,
ensuring constant stack depth regardless of program complexity.

-}
run : Prog Constraint -> IO Constraint
run prog0 =
    IO.loop step ( prog0, [] )


{-| Frame type for the continuation stack.
Each frame is a continuation waiting for a Constraint value.
-}
type Frame
    = Frame (Constraint -> Prog Constraint)


{-| One step of the interpreter.

Returns `IO.Loop` to continue with updated program and stack,
or `IO.Done` when the computation is complete.

-}
step : ( Prog Constraint, List Frame ) -> IO (IO.Step ( Prog Constraint, List Frame ) Constraint)
step ( prog, stack ) =
    case prog of
        Done value ->
            case stack of
                [] ->
                    IO.pure (IO.Done value)

                (Frame k) :: rest ->
                    IO.pure (IO.Loop ( k value, rest ))

        Step instr ->
            stepInstr instr stack


{-| Execute one instruction and return the next loop state.
-}
stepInstr : Instr Constraint -> List Frame -> IO (IO.Step ( Prog Constraint, List Frame ) Constraint)
stepInstr instr stack =
    case instr of
        MkFlexVar k ->
            Type.mkFlexVar
                |> IO.map (\var -> IO.Loop ( k var, stack ))

        MkFlexNumber k ->
            Type.mkFlexNumber
                |> IO.map (\var -> IO.Loop ( k var, stack ))

        RunIO io ->
            io
                |> IO.map (\nextProg -> IO.Loop ( nextProg, stack ))



-- =============================================================================
-- STATEFUL PROGRAM TYPE (for constrainWithIds)
-- =============================================================================


{-| A stateful program that threads state through constraint generation.

Used by constrainWithIds to track expression ID → type variable mappings.

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
