module Compiler.Type.Occurs exposing (occurs)

{-| Occurs check for detecting infinite types during type unification.

The occurs check prevents the creation of infinite types by detecting when a type
variable would occur within its own definition (e.g., `a = List a` where `a` appears
on both sides). This is essential for ensuring that type unification terminates and
produces valid, finite types.

During type inference, if we attempt to unify a type variable with a structure
containing that same variable, we have detected a type error that would create an
infinite type. This module performs that check by traversing type structures and
tracking which variables have been seen.


# Occurs Check

@docs occurs

-}

import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Dict
import System.TypeCheck.IO as IO exposing (IO)



-- ====== OCCURS ======


{-| Checks if a type variable occurs within its own definition, which would create an infinite type.

Returns True if a cycle is detected (the variable appears in its own structure),
False otherwise. This is used during type unification to prevent infinite types.

-}
occurs : Vars.Variable -> IO Bool
occurs var =
    occursHelp [] var False


occursHelp : List Vars.Variable -> Vars.Variable -> Bool -> IO Bool
occursHelp seen var foundCycle =
    if List.member var seen then
        IO.pure True

    else
        UF.get var
            |> IO.andThen
                (\props ->
                    case props.content of
                        Vars.FlexVar _ ->
                            IO.pure foundCycle

                        Vars.FlexSuper _ _ ->
                            IO.pure foundCycle

                        Vars.RigidVar _ ->
                            IO.pure foundCycle

                        Vars.RigidSuper _ _ ->
                            IO.pure foundCycle

                        Vars.Structure term ->
                            let
                                newSeen : List Vars.Variable
                                newSeen =
                                    var :: seen
                            in
                            case term of
                                Vars.App1 _ _ args ->
                                    IO.foldrM (occursHelp newSeen) foundCycle args

                                Vars.Fun1 a b ->
                                    occursHelp newSeen b foundCycle |> IO.andThen (occursHelp newSeen a)

                                Vars.FunL a b s ->
                                    occursHelp newSeen s foundCycle
                                        |> IO.andThen (occursHelp newSeen b)
                                        |> IO.andThen (occursHelp newSeen a)

                                Vars.LambdaSet1 _ ->
                                    -- Ground member ids. Since LSS_023 an
                                    -- `LsFrom` set MAY carry source Points,
                                    -- and the occurs check deliberately does
                                    -- NOT descend into them: inclusion edges
                                    -- are SET-LATTICE edges, not type
                                    -- structure — no infinite TYPE can arise
                                    -- through them.
                                    IO.pure foundCycle

                                Vars.EmptyRecord1 ->
                                    IO.pure foundCycle

                                Vars.Record1 fields ext ->
                                    IO.foldrM (occursHelp newSeen) foundCycle (Dict.values fields) |> IO.andThen (occursHelp newSeen ext)

                                Vars.Unit1 ->
                                    IO.pure foundCycle

                                Vars.Tuple1 a b cs ->
                                    IO.foldrM (occursHelp newSeen) foundCycle cs |> IO.andThen (occursHelp newSeen b) |> IO.andThen (occursHelp newSeen a)

                        Vars.Alias _ _ args _ ->
                            IO.foldrM (occursHelp (var :: seen)) foundCycle (List.map Tuple.second args)

                        Vars.Error ->
                            IO.pure foundCycle
                )
