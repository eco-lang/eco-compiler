module Compiler.Type.Constrain.Erased.Program exposing
    ( Prog(..), Instr(..)
    , pure, map, andThen
    , run
    , opMkFlexVar, opMkFlexNumber
    , opIO
    )

{-| Defunctionalized DSL for constraint generation (Erased pathway).

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
type alias Frame =
    Constraint -> Prog Constraint


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

                k :: rest ->
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
