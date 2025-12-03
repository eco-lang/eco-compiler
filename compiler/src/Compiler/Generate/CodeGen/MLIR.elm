module Compiler.Generate.CodeGen.MLIR exposing (backend)

import Compiler.AST.Optimized as Opt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Compiler.Reporting.Annotation as A
import Data.Map as EveryDict
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Mlir.Loc as Loc exposing (Loc)
import Mlir.Mlir as Mlir
    exposing
        ( MlirAttr(..)
        , MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import Mlir.Pretty as Pretty
import OrderedDict
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- BACKEND


backend : CodeGen.CodeGen
backend =
    { generate =
        \config ->
            CodeGen.TextOutput <|
                generateModule config.mode config.graph config.mains
    , generateForRepl =
        \_ ->
            -- MLIR REPL would need compilation + execution
            CodeGen.TextOutput "// MLIR REPL not yet implemented\n"
    , generateForReplEndpoint =
        \_ ->
            CodeGen.TextOutput "// MLIR REPL endpoint not yet implemented\n"
    }



-- ECO DIALECT TYPE


{-| The eco.value type used for all Elm runtime values
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"



-- STATE
-- Tracks which globals have been generated (for dead code elimination)


type State
    = State (List MlirOp) (EverySet (List String) Opt.Global)


emptyState : State
emptyState =
    State [] EverySet.empty


stateToOps : State -> List MlirOp
stateToOps (State ops _) =
    List.reverse ops


addOp : MlirOp -> State -> State
addOp op (State ops seen) =
    State (op :: ops) seen


addOps : List MlirOp -> State -> State
addOps newOps (State ops seen) =
    State (List.reverse newOps ++ ops) seen


hasSeen : Opt.Global -> State -> Bool
hasSeen global (State _ seen) =
    EverySet.member Opt.toComparableGlobal global seen


markSeen : Opt.Global -> State -> State
markSeen global (State ops seen) =
    State ops (EverySet.insert Opt.toComparableGlobal global seen)



-- CONTEXT
-- The context tracks SSA variable numbering and other state during expression generation


type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    }


initContext : Mode.Mode -> Context
initContext mode =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    }


freshVar : Context -> ( String, Context )
freshVar ctx =
    ( "%" ++ String.fromInt ctx.nextVar
    , { ctx | nextVar = ctx.nextVar + 1 }
    )


freshOpId : Context -> ( String, Context )
freshOpId ctx =
    ( "op" ++ String.fromInt ctx.nextOpId
    , { ctx | nextOpId = ctx.nextOpId + 1 }
    )



-- EXPRESSION RESULT


type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , ctx : Context
    }


emptyResult : Context -> String -> ExprResult
emptyResult ctx var =
    { ops = [], resultVar = var, ctx = ctx }



-- OP BUILDER
-- A builder pattern for constructing MLIR ops more concisely


type alias OpBuilder =
    { name : String
    , id : String
    , operands : List String
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    , loc : Loc
    , successors : List String
    }


{-| Start building an op with the given name. Uses the context to generate a fresh op ID.
-}
mlirOp : String -> Context -> OpBuilder
mlirOp name ctx =
    let
        ( opId, _ ) =
            freshOpId ctx
    in
    { name = name
    , id = opId
    , operands = []
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


withOperands : List String -> OpBuilder -> OpBuilder
withOperands operands builder =
    { builder | operands = operands }


withResult : String -> MlirType -> OpBuilder -> OpBuilder
withResult ssa type_ builder =
    { builder | results = [ ( ssa, type_ ) ] }


withResults : List ( String, MlirType ) -> OpBuilder -> OpBuilder
withResults results builder =
    { builder | results = results }


withAttr : String -> MlirAttr -> OpBuilder -> OpBuilder
withAttr key value builder =
    { builder | attrs = Dict.insert key value builder.attrs }


withAttrs : Dict String MlirAttr -> OpBuilder -> OpBuilder
withAttrs attrs builder =
    { builder | attrs = Dict.union attrs builder.attrs }


withRegion : MlirRegion -> OpBuilder -> OpBuilder
withRegion region builder =
    { builder | regions = [ region ] }


withRegions : List MlirRegion -> OpBuilder -> OpBuilder
withRegions regions builder =
    { builder | regions = regions }


withLoc : Loc -> OpBuilder -> OpBuilder
withLoc loc builder =
    { builder | loc = loc }


asTerminator : OpBuilder -> OpBuilder
asTerminator builder =
    { builder | isTerminator = True }


build : OpBuilder -> MlirOp
build builder =
    { name = builder.name
    , id = builder.id
    , operands = builder.operands
    , results = builder.results
    , attrs = builder.attrs
    , regions = builder.regions
    , isTerminator = builder.isTerminator
    , loc = builder.loc
    , successors = builder.successors
    }



-- ECO DIALECT OP HELPERS
-- These use the builder pattern for cleaner construction


{-| eco.construct - create an ADT value
-}
ecoConstruct : Context -> String -> Int -> Int -> List String -> MlirOp
ecoConstruct ctx resultVar tag size operands =
    mlirOp "eco.construct" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "tag" (IntAttr tag)
        |> withAttr "size" (IntAttr size)
        |> build


{-| eco.call - call a function
-}
ecoCall : Context -> String -> String -> List String -> MlirOp
ecoCall ctx resultVar funcName operands =
    mlirOp "eco.call" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "callee" (SymbolRefAttr funcName)
        |> build


{-| eco.project - extract a field/index from a value
-}
ecoProject : Context -> String -> Int -> String -> MlirOp
ecoProject ctx resultVar index operand =
    mlirOp "eco.project" ctx
        |> withOperands [ operand ]
        |> withResult resultVar ecoValue
        |> withAttr "index" (IntAttr index)
        |> build


{-| eco.return - return a value
-}
ecoReturn : Context -> String -> MlirOp
ecoReturn ctx operand =
    mlirOp "eco.return" ctx
        |> withOperands [ operand ]
        |> asTerminator
        |> build


{-| eco.string\_literal - create a string literal
-}
ecoStringLiteral : Context -> String -> String -> MlirOp
ecoStringLiteral ctx resultVar value =
    mlirOp "eco.string_literal" ctx
        |> withResult resultVar ecoValue
        |> withAttr "value" (StringAttr value)
        |> build


{-| eco.papCreate - create a partial application (closure)
-}
ecoPapCreate : Context -> String -> String -> Int -> Int -> MlirOp
ecoPapCreate ctx resultVar funcName arity numCaptured =
    mlirOp "eco.papCreate" ctx
        |> withResult resultVar ecoValue
        |> withAttr "function" (SymbolRefAttr funcName)
        |> withAttr "arity" (IntAttr arity)
        |> withAttr "num_captured" (IntAttr numCaptured)
        |> build


{-| eco.papExtend - extend a partial application with more arguments
-}
ecoPapExtend : Context -> String -> List String -> MlirOp
ecoPapExtend ctx resultVar operands =
    mlirOp "eco.papExtend" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> build


{-| eco.jump - jump to a join point (for tail calls)
-}
ecoJump : Context -> Int -> List String -> MlirOp
ecoJump ctx joinPoint operands =
    mlirOp "eco.jump" ctx
        |> withOperands operands
        |> withAttr "join_point" (IntAttr joinPoint)
        |> asTerminator
        |> build


{-| arith.constant for integers
-}
arithConstantInt : Context -> String -> Int -> MlirOp
arithConstantInt ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I64
        |> withAttr "value" (IntAttr value)
        |> build


{-| arith.constant for floats
-}
arithConstantFloat : Context -> String -> Float -> MlirOp
arithConstantFloat ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar F64
        |> withAttr "value" (FloatAttr value)
        |> build


{-| func.func - define a function
-}
funcFunc : Context -> String -> List ( String, MlirType ) -> MlirRegion -> MlirOp
funcFunc ctx funcName args bodyRegion =
    mlirOp "func.func" ctx
        |> withRegion bodyRegion
        |> withAttr "sym_name" (StringAttr funcName)
        |> withAttr "sym_visibility" (VisibilityAttr Private)
        |> withAttr "function_type"
            (TypeAttr
                (FunctionType
                    { inputs = List.map Tuple.second args
                    , results = [ ecoValue ]
                    }
                )
            )
        |> build


{-| Create a simple region with a single entry block
-}
mkRegion : List ( String, MlirType ) -> List MlirOp -> MlirOp -> MlirRegion
mkRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }



-- GENERATE MODULE


generateModule : Mode.Mode -> Opt.GlobalGraph -> CodeGen.Mains -> String
generateModule mode ((Opt.GlobalGraph graph _) as globalGraph) mains =
    let
        -- Start from mains and recursively add only reachable globals (dead code elimination)
        state : State
        state =
            EveryDict.foldr ModuleName.compareCanonical (addMain mode graph) emptyState mains

        ops : List MlirOp
        ops =
            stateToOps state

        mlirModule : MlirModule
        mlirModule =
            { body = ops
            , loc = Loc.unknown
            }
    in
    Pretty.ppModule mlirModule


addMain : Mode.Mode -> Graph -> IO.Canonical -> Opt.Main -> State -> State
addMain mode graph home main state =
    let
        mainGlobal : Opt.Global
        mainGlobal =
            Opt.Global home "main"

        stateWithMain : State
        stateWithMain =
            addGlobal mode graph mainGlobal state

        ctx : Context
        ctx =
            initContext mode

        funcName : String
        funcName =
            canonicalToMLIRName home ++ "_main"
    in
    case main of
        Opt.Static ->
            let
                ( callVar, ctx1 ) =
                    freshVar ctx

                callOp : MlirOp
                callOp =
                    ecoCall ctx1 callVar funcName []

                ( _, ctx2 ) =
                    freshOpId ctx1

                returnOp : MlirOp
                returnOp =
                    ecoReturn ctx2 callVar

                region : MlirRegion
                region =
                    mkRegion [] [ callOp ] returnOp

                mainFunc : MlirOp
                mainFunc =
                    funcFunc ctx (funcName ++ "_entry") [] region
            in
            addOp mainFunc stateWithMain

        Opt.Dynamic _ flagsDecoder ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx flagsDecoder

                ( callVar, ctx1 ) =
                    freshVar exprResult.ctx

                callOp : MlirOp
                callOp =
                    ecoCall ctx1 callVar "Elm_Platform_initialize" [ exprResult.resultVar ]

                ( _, ctx2 ) =
                    freshOpId ctx1

                returnOp : MlirOp
                returnOp =
                    ecoReturn ctx2 callVar

                region : MlirRegion
                region =
                    mkRegion [] (exprResult.ops ++ [ callOp ]) returnOp

                mainFunc : MlirOp
                mainFunc =
                    funcFunc ctx (funcName ++ "_entry") [] region
            in
            addOp mainFunc stateWithMain


addGlobal : Mode.Mode -> Graph -> Opt.Global -> State -> State
addGlobal mode graph global state =
    if hasSeen global state then
        state

    else
        addGlobalHelp mode graph global (markSeen global state)


addGlobalHelp : Mode.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph ((Opt.Global home name) as global) state =
    let
        addDeps : EverySet (List String) Opt.Global -> State -> State
        addDeps deps someState =
            let
                sortedDeps : List Opt.Global
                sortedDeps =
                    List.sortWith Opt.compareGlobal (EverySet.toList Opt.compareGlobal deps)
            in
            List.foldl (\dep st -> addGlobal mode graph dep st) someState sortedDeps

        funcName : String
        funcName =
            globalToMLIRName global

        ctx : Context
        ctx =
            initContext mode
    in
    case Utils.find Opt.toComparableGlobal global graph of
        Opt.Define expr deps ->
            addOp (generateTopLevelDef ctx funcName expr) (addDeps deps state)

        Opt.TrackedDefine _ expr deps ->
            addOp (generateTopLevelDef ctx funcName expr) (addDeps deps state)

        Opt.DefineTailFunc _ argNames body deps ->
            addOp (generateTailFunc ctx funcName argNames body) (addDeps deps state)

        Opt.Ctor index arity ->
            addOp (generateCtorFunc ctx funcName index arity) state

        Opt.Enum index ->
            addOp (generateEnumConstant ctx funcName index) state

        Opt.Box ->
            addOp (generateBoxFunc ctx funcName) state

        Opt.Link linkedGlobal ->
            -- For links, we just need to ensure the linked global is generated
            addGlobal mode graph linkedGlobal state

        Opt.Cycle names values funcs deps ->
            -- TODO: Implement cycle handling
            addDeps deps state

        Opt.Manager effectsType ->
            -- TODO: Implement effects manager
            state

        Opt.Kernel chunks deps ->
            -- TODO: Implement kernel code
            addDeps deps state

        Opt.PortIncoming _ deps ->
            -- TODO: Implement port incoming
            addDeps deps state

        Opt.PortOutgoing _ deps ->
            -- TODO: Implement port outgoing
            addDeps deps state



-- GENERATE TOP-LEVEL DEFINITION


generateTopLevelDef : Context -> String -> Opt.Expr -> MlirOp
generateTopLevelDef ctx funcName expr =
    case expr of
        Opt.Function args body ->
            generateFuncDef ctx funcName args body

        Opt.TrackedFunction locatedArgs body ->
            generateFuncDef ctx funcName (List.map A.toValue locatedArgs) body

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                returnOp : MlirOp
                returnOp =
                    ecoReturn exprResult.ctx exprResult.resultVar

                region : MlirRegion
                region =
                    mkRegion [] exprResult.ops returnOp
            in
            funcFunc ctx funcName [] region


generateFuncDef : Context -> String -> List Name.Name -> Opt.Expr -> MlirOp
generateFuncDef ctx funcName args body =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map (\name -> ( "%" ++ name, ecoValue )) args

        -- Create context with args already bound
        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length args }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    funcFunc ctx funcName argPairs region


generateTailFunc : Context -> String -> List (A.Located Name.Name) -> Opt.Expr -> MlirOp
generateTailFunc ctx funcName locatedArgs body =
    let
        args : List Name.Name
        args =
            List.map A.toValue locatedArgs

        argPairs : List ( String, MlirType )
        argPairs =
            List.map (\name -> ( "%" ++ name, ecoValue )) args

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length args }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar

        -- TODO: Implement proper joinpoint region structure
        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    funcFunc ctx funcName argPairs region


generateCtorFunc : Context -> String -> Index.ZeroBased -> Int -> MlirOp
generateCtorFunc ctx funcName index arity =
    let
        tag : Int
        tag =
            Index.toMachine index
    in
    if arity == 0 then
        -- Nullary constructor - return constant
        let
            ( resultVar, ctx1 ) =
                freshVar ctx

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar tag 0 []

            ( _, ctx2 ) =
                freshOpId ctx1

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx2 resultVar

            region : MlirRegion
            region =
                mkRegion [] [ constructOp ] returnOp
        in
        funcFunc ctx funcName [] region

    else
        -- Constructor with arguments
        let
            argNames : List String
            argNames =
                List.range 0 (arity - 1)
                    |> List.map (\i -> "%arg" ++ String.fromInt i)

            argPairs : List ( String, MlirType )
            argPairs =
                List.map (\n -> ( n, ecoValue )) argNames

            ( resultVar, ctx1 ) =
                freshVar { ctx | nextVar = arity }

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar tag arity argNames

            ( _, ctx2 ) =
                freshOpId ctx1

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx2 resultVar

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp
        in
        funcFunc ctx funcName argPairs region


generateEnumConstant : Context -> String -> Index.ZeroBased -> MlirOp
generateEnumConstant ctx funcName index =
    let
        tag : Int
        tag =
            Index.toMachine index

        ( resultVar, ctx1 ) =
            freshVar ctx

        constructOp : MlirOp
        constructOp =
            ecoConstruct ctx1 resultVar tag 0 []

        ( _, ctx2 ) =
            freshOpId ctx1

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx2 resultVar

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp
    in
    funcFunc ctx funcName [] region


generateBoxFunc : Context -> String -> MlirOp
generateBoxFunc ctx funcName =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            [ ( "%arg0", ecoValue ) ]

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx "%arg0"

        region : MlirRegion
        region =
            mkRegion argPairs [] returnOp
    in
    funcFunc ctx funcName argPairs region



-- GENERATE EXPRESSION


generateExpr : Context -> Opt.Expr -> ExprResult
generateExpr ctx expr =
    case expr of
        Opt.Bool _ value ->
            generateBoolExpr ctx value

        Opt.Chr _ value ->
            generateChrExpr ctx value

        Opt.Str _ value ->
            generateStrExpr ctx value

        Opt.Int _ value ->
            generateIntExpr ctx value

        Opt.Float _ value ->
            generateFloatExpr ctx value

        Opt.VarLocal name ->
            generateVarLocalExpr ctx name

        Opt.TrackedVarLocal _ name ->
            generateVarLocalExpr ctx name

        Opt.VarGlobal _ global ->
            generateVarGlobalExpr ctx global

        Opt.VarEnum _ global index ->
            generateVarEnumExpr ctx global index

        Opt.VarBox _ global ->
            generateVarBoxExpr ctx global

        Opt.VarCycle _ home name ->
            generateVarCycleExpr ctx home name

        Opt.VarDebug _ name home maybeName ->
            generateVarDebugExpr ctx name home maybeName

        Opt.VarKernel _ home name ->
            generateVarKernelExpr ctx home name

        Opt.Unit ->
            generateUnitExpr ctx

        Opt.Tuple _ a b maybeC ->
            generateTupleExpr ctx a b maybeC

        Opt.List _ items ->
            generateListExpr ctx items

        Opt.Record fields ->
            generateRecordExpr ctx fields

        Opt.TrackedRecord _ fields ->
            generateTrackedRecordExpr ctx fields

        Opt.Function args body ->
            generateFunctionExpr ctx args body

        Opt.TrackedFunction locatedArgs body ->
            generateTrackedFunctionExpr ctx locatedArgs body

        Opt.Call _ func args ->
            generateCallExpr ctx func args

        Opt.TailCall name args ->
            generateTailCallExpr ctx name args

        Opt.If branches final ->
            generateIfExpr ctx branches final

        Opt.Let def body ->
            generateLetExpr ctx def body

        Opt.Destruct destructor body ->
            generateDestructExpr ctx destructor body

        Opt.Case scrutinee1 scrutinee2 decider jumps ->
            generateCaseExpr ctx scrutinee1 scrutinee2 decider jumps

        Opt.Accessor _ fieldName ->
            generateAccessorExpr ctx fieldName

        Opt.Access record _ fieldName ->
            generateAccessExpr ctx record fieldName

        Opt.Update _ record updates ->
            generateUpdateExpr ctx record updates

        Opt.Shader _ _ _ ->
            generateShaderExpr ctx



-- LITERAL EXPRESSIONS


generateBoolExpr : Context -> Bool -> ExprResult
generateBoolExpr ctx value =
    let
        ( var, ctx1 ) =
            freshVar ctx

        tag : Int
        tag =
            if value then
                1

            else
                0

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoConstruct ctx1 var tag 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateChrExpr : Context -> String -> ExprResult
generateChrExpr ctx value =
    let
        ( var, ctx1 ) =
            freshVar ctx

        charCode : Int
        charCode =
            String.uncons value
                |> Maybe.map (Tuple.first >> Char.toCode)
                |> Maybe.withDefault 0

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Proper char representation
    { ops = [ ecoConstruct ctx1 var charCode 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateStrExpr : Context -> String -> ExprResult
generateStrExpr ctx value =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoStringLiteral ctx1 var value ]
    , resultVar = var
    , ctx = ctx2
    }


generateIntExpr : Context -> Int -> ExprResult
generateIntExpr ctx value =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ arithConstantInt ctx1 var value ]
    , resultVar = var
    , ctx = ctx2
    }


generateFloatExpr : Context -> Float -> ExprResult
generateFloatExpr ctx value =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ arithConstantFloat ctx1 var value ]
    , resultVar = var
    , ctx = ctx2
    }



-- VARIABLE EXPRESSIONS


generateVarLocalExpr : Context -> Name.Name -> ExprResult
generateVarLocalExpr ctx name =
    emptyResult ctx ("%" ++ name)


generateVarGlobalExpr : Context -> Opt.Global -> ExprResult
generateVarGlobalExpr ctx global =
    let
        ( var, ctx1 ) =
            freshVar ctx

        globalName : String
        globalName =
            globalToMLIRName global

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoCall ctx1 var globalName [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateVarEnumExpr : Context -> Opt.Global -> Index.ZeroBased -> ExprResult
generateVarEnumExpr ctx global index =
    let
        ( var, ctx1 ) =
            freshVar ctx

        tag : Int
        tag =
            Index.toMachine index

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoConstruct ctx1 var tag 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateVarBoxExpr : Context -> Opt.Global -> ExprResult
generateVarBoxExpr ctx global =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoCall ctx1 var (globalToMLIRName global) [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateVarCycleExpr : Context -> IO.Canonical -> Name.Name -> ExprResult
generateVarCycleExpr ctx home name =
    let
        ( var, ctx1 ) =
            freshVar ctx

        cycleName : String
        cycleName =
            canonicalToMLIRName home ++ "_" ++ name

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoCall ctx1 var cycleName [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateVarDebugExpr : Context -> Name.Name -> IO.Canonical -> Maybe Name.Name -> ExprResult
generateVarDebugExpr ctx name home maybeName =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Implement debug
    { ops = [ ecoConstruct ctx1 var 0 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateVarKernelExpr : Context -> Name.Name -> Name.Name -> ExprResult
generateVarKernelExpr ctx home name =
    let
        ( var, ctx1 ) =
            freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoCall ctx1 var kernelName [] ]
    , resultVar = var
    , ctx = ctx2
    }



-- DATA STRUCTURE EXPRESSIONS


generateUnitExpr : Context -> ExprResult
generateUnitExpr ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoConstruct ctx1 var 0 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }


generateTupleExpr : Context -> Opt.Expr -> Opt.Expr -> List Opt.Expr -> ExprResult
generateTupleExpr ctx a b maybeC =
    let
        resultA : ExprResult
        resultA =
            generateExpr ctx a

        resultB : ExprResult
        resultB =
            generateExpr resultA.ctx b

        ( restOps, restVars, finalCtx ) =
            generateExprList resultB.ctx maybeC

        allVars : List String
        allVars =
            resultA.resultVar :: resultB.resultVar :: restVars

        ( resultVar, ctx1 ) =
            freshVar finalCtx

        arity : Int
        arity =
            List.length allVars

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = resultA.ops ++ resultB.ops ++ restOps ++ [ ecoConstruct ctx1 resultVar 0 arity allVars ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateListExpr : Context -> List Opt.Expr -> ExprResult
generateListExpr ctx items =
    generateList ctx items


generateRecordExpr : Context -> EveryDict.Dict String Name.Name Opt.Expr -> ExprResult
generateRecordExpr ctx fields =
    generateRecord ctx fields


generateTrackedRecordExpr : Context -> EveryDict.Dict String (A.Located Name.Name) Opt.Expr -> ExprResult
generateTrackedRecordExpr ctx fields =
    generateTrackedRecord ctx fields



-- FUNCTION EXPRESSIONS


generateFunctionExpr : Context -> List Name.Name -> Opt.Expr -> ExprResult
generateFunctionExpr ctx args body =
    let
        ( var, ctx1 ) =
            freshVar ctx

        arity : Int
        arity =
            List.length args

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Generate actual closure
    { ops = [ ecoPapCreate ctx1 var "anonymous" arity 0 ]
    , resultVar = var
    , ctx = ctx2
    }


generateTrackedFunctionExpr : Context -> List (A.Located Name.Name) -> Opt.Expr -> ExprResult
generateTrackedFunctionExpr ctx locatedArgs body =
    let
        args =
            List.map A.toValue locatedArgs

        ( var, ctx1 ) =
            freshVar ctx

        arity : Int
        arity =
            List.length args

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Generate actual closure
    { ops = [ ecoPapCreate ctx1 var "anonymous" arity 0 ]
    , resultVar = var
    , ctx = ctx2
    }


generateCallExpr : Context -> Opt.Expr -> List Opt.Expr -> ExprResult
generateCallExpr ctx func args =
    generateCall ctx func args


generateTailCallExpr : Context -> Name.Name -> List ( Name.Name, Opt.Expr ) -> ExprResult
generateTailCallExpr ctx name args =
    let
        ( argsOps, argVars, ctx1 ) =
            generateNamedArgs ctx args

        ( _, ctx2 ) =
            freshOpId ctx1

        ( resultVar, ctx3 ) =
            freshVar ctx2

        ( _, ctx4 ) =
            freshOpId ctx3
    in
    { ops = argsOps ++ [ ecoJump ctx1 0 argVars, ecoConstruct ctx3 resultVar 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx4
    }



-- CONTROL FLOW EXPRESSIONS


generateIfExpr : Context -> List ( Opt.Expr, Opt.Expr ) -> Opt.Expr -> ExprResult
generateIfExpr ctx branches final =
    generateIf ctx branches final


generateLetExpr : Context -> Opt.Def -> Opt.Expr -> ExprResult
generateLetExpr ctx def body =
    generateLet ctx def body


generateDestructExpr : Context -> Opt.Destructor -> Opt.Expr -> ExprResult
generateDestructExpr ctx destructor body =
    generateDestruct ctx destructor body


generateCaseExpr : Context -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> List ( Int, Opt.Expr ) -> ExprResult
generateCaseExpr ctx scrutinee1 scrutinee2 decider jumps =
    generateCase ctx scrutinee1 scrutinee2 decider jumps



-- RECORD OPERATION EXPRESSIONS


generateAccessorExpr : Context -> Name.Name -> ExprResult
generateAccessorExpr ctx fieldName =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Generate proper accessor function
    { ops = [ ecoPapCreate ctx1 var ("accessor_" ++ fieldName) 1 0 ]
    , resultVar = var
    , ctx = ctx2
    }


generateAccessExpr : Context -> Opt.Expr -> Name.Name -> ExprResult
generateAccessExpr ctx record fieldName =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Compute actual field index
    { ops = recordResult.ops ++ [ ecoProject ctx1 resultVar 0 recordResult.resultVar ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateUpdateExpr : Context -> Opt.Expr -> EveryDict.Dict String (A.Located Name.Name) Opt.Expr -> ExprResult
generateUpdateExpr ctx record updates =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- TODO: Implement record update
    { ops = recordResult.ops ++ [ ecoConstruct ctx1 resultVar 0 1 [ recordResult.resultVar ] ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- SPECIAL EXPRESSIONS


generateShaderExpr : Context -> ExprResult
generateShaderExpr ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    -- Shader not supported
    { ops = [ ecoConstruct ctx1 var 0 0 [] ]
    , resultVar = var
    , ctx = ctx2
    }



-- HELPER: Generate list of expressions


generateExprList : Context -> List Opt.Expr -> ( List MlirOp, List String, Context )
generateExprList ctx exprs =
    List.foldl
        (\expr ( accOps, accVars, accCtx ) ->
            let
                result : ExprResult
                result =
                    generateExpr accCtx expr
            in
            ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
        )
        ( [], [], ctx )
        exprs



-- HELPER: Generate named args for tail call


generateNamedArgs : Context -> List ( Name.Name, Opt.Expr ) -> ( List MlirOp, List String, Context )
generateNamedArgs ctx args =
    List.foldl
        (\( _, expr ) ( accOps, accVars, accCtx ) ->
            let
                result : ExprResult
                result =
                    generateExpr accCtx expr
            in
            ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
        )
        ( [], [], ctx )
        args



-- GENERATE LIST


generateList : Context -> List Opt.Expr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Empty list: Nil
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( _, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ ecoConstruct ctx1 var 0 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        _ ->
            -- Build list from right to left: Cons(head, Cons(head2, ... Nil))
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                nilOp : MlirOp
                nilOp =
                    ecoConstruct ctx1 nilVar 0 0 []

                ( _, ctx2 ) =
                    freshOpId ctx1

                -- Fold from right, building up the list
                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                itemResult : ExprResult
                                itemResult =
                                    generateExpr accCtx item

                                ( consVar, ctx3 ) =
                                    freshVar itemResult.ctx

                                consOp : MlirOp
                                consOp =
                                    ecoConstruct ctx3 consVar 1 2 [ itemResult.resultVar, tailVar ]

                                ( _, ctx4 ) =
                                    freshOpId ctx3
                            in
                            ( itemResult.ops ++ [ consOp ] ++ accOps, consVar, ctx4 )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = [ nilOp ] ++ consOps
            , resultVar = finalVar
            , ctx = finalCtx
            }



-- GENERATE RECORD


generateRecord : Context -> EveryDict.Dict String Name.Name Opt.Expr -> ExprResult
generateRecord ctx fields =
    let
        fieldList : List ( Name.Name, Opt.Expr )
        fieldList =
            EveryDict.toList compare fields

        ( fieldsOps, fieldVars, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                fieldList

        ( resultVar, ctx2 ) =
            freshVar ctx1

        arity : Int
        arity =
            List.length fieldList

        ( _, ctx3 ) =
            freshOpId ctx2
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar 0 arity fieldVars ]
    , resultVar = resultVar
    , ctx = ctx3
    }


generateTrackedRecord : Context -> EveryDict.Dict String (A.Located Name.Name) Opt.Expr -> ExprResult
generateTrackedRecord ctx fields =
    let
        fieldList : List ( A.Located Name.Name, Opt.Expr )
        fieldList =
            EveryDict.toList A.compareLocated fields

        ( fieldsOps, fieldVars, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                fieldList

        ( resultVar, ctx2 ) =
            freshVar ctx1

        arity : Int
        arity =
            List.length fieldList

        ( _, ctx3 ) =
            freshOpId ctx2
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar 0 arity fieldVars ]
    , resultVar = resultVar
    , ctx = ctx3
    }



-- GENERATE CALL


generateCall : Context -> Opt.Expr -> List Opt.Expr -> ExprResult
generateCall ctx func args =
    case func of
        Opt.VarGlobal _ global ->
            -- Direct call to known function
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                funcName : String
                funcName =
                    globalToMLIRName global

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            { ops = argsOps ++ [ ecoCall ctx2 resultVar funcName argVars ]
            , resultVar = resultVar
            , ctx = ctx3
            }

        Opt.VarLocal name ->
            -- Call to local variable (closure)
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                allArgs : List String
                allArgs =
                    ("%" ++ name) :: argVars

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            { ops = argsOps ++ [ ecoPapExtend ctx2 resultVar allArgs ]
            , resultVar = resultVar
            , ctx = ctx3
            }

        _ ->
            -- General case: evaluate function, then call
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                ( argsOps, argVars, ctx1 ) =
                    generateExprList funcResult.ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                allArgs : List String
                allArgs =
                    funcResult.resultVar :: argVars

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            { ops = funcResult.ops ++ argsOps ++ [ ecoPapExtend ctx2 resultVar allArgs ]
            , resultVar = resultVar
            , ctx = ctx3
            }



-- GENERATE IF


generateIf : Context -> List ( Opt.Expr, Opt.Expr ) -> Opt.Expr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            -- No branches, just the else
            generateExpr ctx final

        ( cond, thenBranch ) :: restBranches ->
            let
                condResult : ExprResult
                condResult =
                    generateExpr ctx cond

                thenResult : ExprResult
                thenResult =
                    generateExpr condResult.ctx thenBranch

                elseResult : ExprResult
                elseResult =
                    generateIf thenResult.ctx restBranches final

                -- TODO: Implement proper control flow with scf.if or cf.cond_br
                -- For now, just generate all the ops sequentially
            in
            { ops = condResult.ops ++ thenResult.ops ++ elseResult.ops
            , resultVar = elseResult.resultVar
            , ctx = elseResult.ctx
            }



-- GENERATE LET


generateLet : Context -> Opt.Def -> Opt.Expr -> ExprResult
generateLet ctx def body =
    case def of
        Opt.Def _ name expr ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                -- Create an alias: %name = eco.construct(%exprVar) for the binding
                aliasOp : MlirOp
                aliasOp =
                    ecoConstruct exprResult.ctx ("%" ++ name) 0 1 [ exprResult.resultVar ]

                ( _, ctx1 ) =
                    freshOpId exprResult.ctx

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body
            in
            { ops = exprResult.ops ++ [ aliasOp ] ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , ctx = bodyResult.ctx
            }

        Opt.TailDef _ name locatedArgs expr ->
            -- TODO: Implement local tail-recursive definition with joinpoint
            let
                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx expr
            in
            bodyResult



-- GENERATE DESTRUCT


generateDestruct : Context -> Opt.Destructor -> Opt.Expr -> ExprResult
generateDestruct ctx (Opt.Destructor name path) body =
    let
        ( pathOps, pathVar, ctx1 ) =
            generatePath ctx path

        aliasOp : MlirOp
        aliasOp =
            ecoConstruct ctx1 ("%" ++ name) 0 1 [ pathVar ]

        ( _, ctx2 ) =
            freshOpId ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ [ aliasOp ] ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , ctx = bodyResult.ctx
    }


generatePath : Context -> Opt.Path -> ( List MlirOp, String, Context )
generatePath ctx path =
    case path of
        Opt.Root name ->
            ( [], "%" ++ name, ctx )

        Opt.Index index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generatePath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                idx : Int
                idx =
                    Index.toMachine index

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            ( subOps ++ [ ecoProject ctx2 resultVar idx subVar ]
            , resultVar
            , ctx3
            )

        Opt.Field name subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generatePath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            -- TODO: Compute actual field index
            ( subOps ++ [ ecoProject ctx2 resultVar 0 subVar ]
            , resultVar
            , ctx3
            )

        Opt.Unbox subPath ->
            -- Unbox is identity for our purposes
            generatePath ctx subPath

        Opt.ArrayIndex idx subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generatePath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( _, ctx3 ) =
                    freshOpId ctx2
            in
            ( subOps ++ [ ecoProject ctx2 resultVar idx subVar ]
            , resultVar
            , ctx3
            )



-- GENERATE CASE


generateCase : Context -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> List ( Int, Opt.Expr ) -> ExprResult
generateCase ctx scrutinee1 scrutinee2 decider jumps =
    -- TODO: Implement proper case/decision tree
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        ( _, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoConstruct ctx1 resultVar 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- HELPERS


type alias Graph =
    EveryDict.Dict (List String) Opt.Global Opt.Node


canonicalToMLIRName : IO.Canonical -> String
canonicalToMLIRName (IO.Canonical _ moduleName) =
    String.replace "." "_" moduleName


globalToMLIRName : Opt.Global -> String
globalToMLIRName (Opt.Global home name) =
    canonicalToMLIRName home ++ "_" ++ sanitizeName name


sanitizeName : String -> String
sanitizeName name =
    -- Replace operators and special chars with safe names
    name
        |> String.replace "+" "_plus_"
        |> String.replace "-" "_minus_"
        |> String.replace "*" "_star_"
        |> String.replace "/" "_slash_"
        |> String.replace "<" "_lt_"
        |> String.replace ">" "_gt_"
        |> String.replace "=" "_eq_"
        |> String.replace "&" "_amp_"
        |> String.replace "|" "_pipe_"
        |> String.replace "!" "_bang_"
        |> String.replace "?" "_question_"
        |> String.replace ":" "_colon_"
        |> String.replace "." "_dot_"
        |> String.replace "$" "_dollar_"
