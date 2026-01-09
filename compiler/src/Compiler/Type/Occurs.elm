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
import Data.Map as Dict
import System.TypeCheck.IO as IO exposing (IO)



-- ====== OCCURS ======


{-| Checks if a type variable occurs within its own definition, which would create an infinite type.

Returns True if a cycle is detected (the variable appears in its own structure),
False otherwise. This is used during type unification to prevent infinite types.

-}
occurs : IO.Variable -> IO Bool
occurs var =
    occursHelp [] var False


occursHelp : List IO.Variable -> IO.Variable -> Bool -> IO Bool
occursHelp seen var foundCycle =
    if List.member var seen then
        IO.pure True

    else
        UF.get var
            |> IO.andThen
                (\(IO.Descriptor props) ->
                    case props.content of
                        IO.FlexVar _ ->
                            IO.pure foundCycle

                        IO.FlexSuper _ _ ->
                            IO.pure foundCycle

                        IO.RigidVar _ ->
                            IO.pure foundCycle

                        IO.RigidSuper _ _ ->
                            IO.pure foundCycle

                        IO.Structure term ->
                            let
                                newSeen : List IO.Variable
                                newSeen =
                                    var :: seen
                            in
                            case term of
                                IO.App1 _ _ args ->
                                    IO.foldrM (occursHelp newSeen) foundCycle args

                                IO.Fun1 a b ->
                                    occursHelp newSeen b foundCycle |> IO.andThen (occursHelp newSeen a)

                                IO.EmptyRecord1 ->
                                    IO.pure foundCycle

                                IO.Record1 fields ext ->
                                    IO.foldrM (occursHelp newSeen) foundCycle (Dict.values compare fields) |> IO.andThen (occursHelp newSeen ext)

                                IO.Unit1 ->
                                    IO.pure foundCycle

                                IO.Tuple1 a b cs ->
                                    IO.foldrM (occursHelp newSeen) foundCycle cs |> IO.andThen (occursHelp newSeen b) |> IO.andThen (occursHelp newSeen a)

                        IO.Alias _ _ args _ ->
                            IO.foldrM (occursHelp (var :: seen)) foundCycle (List.map Tuple.second args)

                        IO.Error ->
                            IO.pure foundCycle
                )
