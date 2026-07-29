module Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..), lub)

{-| The borrow access-mode lattice: `Borrowed < Owned`. Factored into its own
leaf module so both `Solve` and the interprocedural `Sig` / `Constrain`
call-boundary can reference it without an import cycle (`Sig` carries `Mode`
arrays; `Constrain.Env.sigs` yields a `Sig.BorrowSig`; `Solve` produces
`Mode`s).
-}


type Mode
    = Borrowed
    | Owned


lub : Mode -> Mode -> Mode
lub a b =
    case ( a, b ) of
        ( Owned, _ ) ->
            Owned

        ( _, Owned ) ->
            Owned

        _ ->
            Borrowed
