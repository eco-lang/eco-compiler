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
import Dict
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



-- MLIR OP BUILDERS


{-| Create an empty MlirOp with the given name
-}
mkOp : String -> String -> MlirOp
mkOp name opId =
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


{-| Helper to create attribute dict from list
-}
attrsFromList : List ( String, MlirAttr ) -> Dict.Dict String MlirAttr
attrsFromList =
    Dict.fromList


{-| eco.construct - create an ADT value
-}
ecoConstruct : String -> String -> Int -> Int -> List String -> MlirOp
ecoConstruct resultVar opId tag size operands =
    { name = "eco.construct"
    , id = opId
    , operands = operands
    , results = [ ( resultVar, ecoValue ) ]
    , attrs =
        attrsFromList
            [ ( "tag", IntAttr tag )
            , ( "size", IntAttr size )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.call - call a function
-}
ecoCall : String -> String -> String -> List String -> MlirOp
ecoCall resultVar opId funcName operands =
    { name = "eco.call"
    , id = opId
    , operands = operands
    , results = [ ( resultVar, ecoValue ) ]
    , attrs =
        attrsFromList
            [ ( "callee", SymbolRefAttr funcName )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.project - extract a field/index from a value
-}
ecoProject : String -> String -> Int -> String -> MlirOp
ecoProject resultVar opId index operand =
    { name = "eco.project"
    , id = opId
    , operands = [ operand ]
    , results = [ ( resultVar, ecoValue ) ]
    , attrs =
        attrsFromList
            [ ( "index", IntAttr index )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.return - return a value
-}
ecoReturn : String -> String -> MlirOp
ecoReturn opId operand =
    { name = "eco.return"
    , id = opId
    , operands = [ operand ]
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = True
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.string\_literal - create a string literal
-}
ecoStringLiteral : String -> String -> String -> MlirOp
ecoStringLiteral resultVar opId value =
    { name = "eco.string_literal"
    , id = opId
    , operands = []
    , results = [ ( resultVar, ecoValue ) ]
    , attrs =
        attrsFromList
            [ ( "value", StringAttr value )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.papCreate - create a partial application (closure)
-}
ecoPapCreate : String -> String -> String -> Int -> Int -> MlirOp
ecoPapCreate resultVar opId funcName arity numCaptured =
    { name = "eco.papCreate"
    , id = opId
    , operands = []
    , results = [ ( resultVar, ecoValue ) ]
    , attrs =
        attrsFromList
            [ ( "function", SymbolRefAttr funcName )
            , ( "arity", IntAttr arity )
            , ( "num_captured", IntAttr numCaptured )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.papExtend - extend a partial application with more arguments
-}
ecoPapExtend : String -> String -> List String -> MlirOp
ecoPapExtend resultVar opId operands =
    { name = "eco.papExtend"
    , id = opId
    , operands = operands
    , results = [ ( resultVar, ecoValue ) ]
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| eco.jump - jump to a join point (for tail calls)
-}
ecoJump : String -> Int -> List String -> MlirOp
ecoJump opId joinPoint operands =
    { name = "eco.jump"
    , id = opId
    , operands = operands
    , results = []
    , attrs =
        attrsFromList
            [ ( "join_point", IntAttr joinPoint )
            ]
    , regions = []
    , isTerminator = True
    , loc = Loc.unknown
    , successors = []
    }


{-| arith.constant for integers
-}
arithConstantInt : String -> String -> Int -> MlirOp
arithConstantInt resultVar opId value =
    { name = "arith.constant"
    , id = opId
    , operands = []
    , results = [ ( resultVar, I64 ) ]
    , attrs =
        attrsFromList
            [ ( "value", IntAttr value )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| arith.constant for floats
-}
arithConstantFloat : String -> String -> Float -> MlirOp
arithConstantFloat resultVar opId value =
    { name = "arith.constant"
    , id = opId
    , operands = []
    , results = [ ( resultVar, F64 ) ]
    , attrs =
        attrsFromList
            [ ( "value", FloatAttr value )
            ]
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| func.func - define a function
-}
funcFunc : String -> String -> List ( String, MlirType ) -> MlirRegion -> MlirOp
funcFunc funcName opId args bodyRegion =
    { name = "func.func"
    , id = opId
    , operands = []
    , results = []
    , attrs =
        attrsFromList
            [ ( "sym_name", StringAttr funcName )
            , ( "sym_visibility", VisibilityAttr Private )
            , ( "function_type"
              , TypeAttr
                    (FunctionType
                        { inputs = List.map Tuple.second args
                        , results = [ ecoValue ]
                        }
                    )
              )
            ]
    , regions = [ bodyRegion ]
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


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

                ( opId1, ctx2 ) =
                    freshOpId ctx1

                ( opId2, _ ) =
                    freshOpId ctx2

                callOp : MlirOp
                callOp =
                    ecoCall callVar opId1 funcName []

                returnOp : MlirOp
                returnOp =
                    ecoReturn opId2 callVar

                region : MlirRegion
                region =
                    mkRegion [] [ callOp ] returnOp

                ( funcOpId, _ ) =
                    freshOpId ctx

                mainFunc : MlirOp
                mainFunc =
                    funcFunc (funcName ++ "_entry") funcOpId [] region
            in
            addOp mainFunc stateWithMain

        Opt.Dynamic _ flagsDecoder ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx flagsDecoder

                ( callVar, ctx1 ) =
                    freshVar exprResult.ctx

                ( opId1, ctx2 ) =
                    freshOpId ctx1

                ( opId2, _ ) =
                    freshOpId ctx2

                callOp : MlirOp
                callOp =
                    ecoCall callVar opId1 "Elm_Platform_initialize" [ exprResult.resultVar ]

                returnOp : MlirOp
                returnOp =
                    ecoReturn opId2 callVar

                region : MlirRegion
                region =
                    mkRegion [] (exprResult.ops ++ [ callOp ]) returnOp

                ( funcOpId, _ ) =
                    freshOpId ctx

                mainFunc : MlirOp
                mainFunc =
                    funcFunc (funcName ++ "_entry") funcOpId [] region
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

                ( opId, _ ) =
                    freshOpId exprResult.ctx

                returnOp : MlirOp
                returnOp =
                    ecoReturn opId exprResult.resultVar

                region : MlirRegion
                region =
                    mkRegion [] exprResult.ops returnOp

                ( funcOpId, _ ) =
                    freshOpId ctx
            in
            funcFunc funcName funcOpId [] region


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

        ( opId, _ ) =
            freshOpId exprResult.ctx

        returnOp : MlirOp
        returnOp =
            ecoReturn opId exprResult.resultVar

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp

        ( funcOpId, _ ) =
            freshOpId ctx
    in
    funcFunc funcName funcOpId argPairs region


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

        ( opId, _ ) =
            freshOpId exprResult.ctx

        returnOp : MlirOp
        returnOp =
            ecoReturn opId exprResult.resultVar

        -- TODO: Implement proper joinpoint region structure
        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp

        ( funcOpId, _ ) =
            freshOpId ctx
    in
    funcFunc funcName funcOpId argPairs region


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

            ( opId1, ctx2 ) =
                freshOpId ctx1

            ( opId2, _ ) =
                freshOpId ctx2

            constructOp : MlirOp
            constructOp =
                ecoConstruct resultVar opId1 tag 0 []

            returnOp : MlirOp
            returnOp =
                ecoReturn opId2 resultVar

            region : MlirRegion
            region =
                mkRegion [] [ constructOp ] returnOp

            ( funcOpId, _ ) =
                freshOpId ctx
        in
        funcFunc funcName funcOpId [] region

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

            ( opId1, ctx2 ) =
                freshOpId ctx1

            ( opId2, _ ) =
                freshOpId ctx2

            constructOp : MlirOp
            constructOp =
                ecoConstruct resultVar opId1 tag arity argNames

            returnOp : MlirOp
            returnOp =
                ecoReturn opId2 resultVar

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp

            ( funcOpId, _ ) =
                freshOpId ctx
        in
        funcFunc funcName funcOpId argPairs region


generateEnumConstant : Context -> String -> Index.ZeroBased -> MlirOp
generateEnumConstant ctx funcName index =
    let
        tag : Int
        tag =
            Index.toMachine index

        ( resultVar, ctx1 ) =
            freshVar ctx

        ( opId1, ctx2 ) =
            freshOpId ctx1

        ( opId2, _ ) =
            freshOpId ctx2

        constructOp : MlirOp
        constructOp =
            ecoConstruct resultVar opId1 tag 0 []

        returnOp : MlirOp
        returnOp =
            ecoReturn opId2 resultVar

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp

        ( funcOpId, _ ) =
            freshOpId ctx
    in
    funcFunc funcName funcOpId [] region


generateBoxFunc : Context -> String -> MlirOp
generateBoxFunc ctx funcName =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            [ ( "%arg0", ecoValue ) ]

        ( opId, _ ) =
            freshOpId ctx

        returnOp : MlirOp
        returnOp =
            ecoReturn opId "%arg0"

        region : MlirRegion
        region =
            mkRegion argPairs [] returnOp

        ( funcOpId, _ ) =
            freshOpId ctx
    in
    funcFunc funcName funcOpId argPairs region



-- GENERATE EXPRESSION


generateExpr : Context -> Opt.Expr -> ExprResult
generateExpr ctx expr =
    case expr of
        ------------------------------------------
        -- LITERALS
        ------------------------------------------
        Opt.Bool _ value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                tag : Int
                tag =
                    if value then
                        1

                    else
                        0
            in
            { ops = [ ecoConstruct var opId tag 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Chr _ value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                charCode : Int
                charCode =
                    String.uncons value
                        |> Maybe.map (Tuple.first >> Char.toCode)
                        |> Maybe.withDefault 0
            in
            -- TODO: Proper char representation
            { ops = [ ecoConstruct var opId charCode 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Str _ value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ ecoStringLiteral var opId value ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Int _ value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ arithConstantInt var opId value ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Float _ value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ arithConstantFloat var opId value ]
            , resultVar = var
            , ctx = ctx2
            }

        ------------------------------------------
        -- VARIABLES
        ------------------------------------------
        Opt.VarLocal name ->
            emptyResult ctx ("%" ++ name)

        Opt.TrackedVarLocal _ name ->
            emptyResult ctx ("%" ++ name)

        Opt.VarGlobal _ global ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                globalName : String
                globalName =
                    globalToMLIRName global
            in
            { ops = [ ecoCall var opId globalName [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.VarEnum _ global index ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                tag : Int
                tag =
                    Index.toMachine index
            in
            { ops = [ ecoConstruct var opId tag 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.VarBox _ global ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ ecoCall var opId (globalToMLIRName global) [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.VarCycle _ home name ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                cycleName : String
                cycleName =
                    canonicalToMLIRName home ++ "_" ++ name
            in
            { ops = [ ecoCall var opId cycleName [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.VarDebug _ name home maybeName ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            -- TODO: Implement debug
            { ops = [ ecoConstruct var opId 0 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.VarKernel _ home name ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name
            in
            { ops = [ ecoCall var opId kernelName [] ]
            , resultVar = var
            , ctx = ctx2
            }

        ------------------------------------------
        -- DATA STRUCTURES
        ------------------------------------------
        Opt.Unit ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ ecoConstruct var opId 0 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Tuple _ a b maybeC ->
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

                ( opId, ctx2 ) =
                    freshOpId ctx1

                arity : Int
                arity =
                    List.length allVars
            in
            { ops = resultA.ops ++ resultB.ops ++ restOps ++ [ ecoConstruct resultVar opId 0 arity allVars ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        Opt.List _ items ->
            generateList ctx items

        Opt.Record fields ->
            generateRecord ctx fields

        Opt.TrackedRecord _ fields ->
            generateTrackedRecord ctx fields

        ------------------------------------------
        -- FUNCTIONS AND CALLS
        ------------------------------------------
        Opt.Function args body ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                arity : Int
                arity =
                    List.length args
            in
            -- TODO: Generate actual closure
            { ops = [ ecoPapCreate var opId "anonymous" arity 0 ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.TrackedFunction locatedArgs body ->
            let
                args =
                    List.map A.toValue locatedArgs

                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1

                arity : Int
                arity =
                    List.length args
            in
            -- TODO: Generate actual closure
            { ops = [ ecoPapCreate var opId "anonymous" arity 0 ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Call _ func args ->
            generateCall ctx func args

        Opt.TailCall name args ->
            let
                ( argsOps, argVars, ctx1 ) =
                    generateNamedArgs ctx args

                ( opId, ctx2 ) =
                    freshOpId ctx1

                ( resultVar, ctx3 ) =
                    freshVar ctx2

                ( opId2, ctx4 ) =
                    freshOpId ctx3
            in
            { ops = argsOps ++ [ ecoJump opId 0 argVars, ecoConstruct resultVar opId2 0 0 [] ]
            , resultVar = resultVar
            , ctx = ctx4
            }

        ------------------------------------------
        -- CONTROL FLOW
        ------------------------------------------
        Opt.If branches final ->
            generateIf ctx branches final

        Opt.Let def body ->
            generateLet ctx def body

        Opt.Destruct destructor body ->
            generateDestruct ctx destructor body

        Opt.Case scrutinee1 scrutinee2 decider jumps ->
            generateCase ctx scrutinee1 scrutinee2 decider jumps

        ------------------------------------------
        -- RECORD OPERATIONS
        ------------------------------------------
        Opt.Accessor _ fieldName ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            -- TODO: Generate proper accessor function
            { ops = [ ecoPapCreate var opId ("accessor_" ++ fieldName) 1 0 ]
            , resultVar = var
            , ctx = ctx2
            }

        Opt.Access record _ fieldName ->
            let
                recordResult : ExprResult
                recordResult =
                    generateExpr ctx record

                ( resultVar, ctx1 ) =
                    freshVar recordResult.ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            -- TODO: Compute actual field index
            { ops = recordResult.ops ++ [ ecoProject resultVar opId 0 recordResult.resultVar ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        Opt.Update _ record updates ->
            let
                recordResult : ExprResult
                recordResult =
                    generateExpr ctx record

                ( resultVar, ctx1 ) =
                    freshVar recordResult.ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            -- TODO: Implement record update
            { ops = recordResult.ops ++ [ ecoConstruct resultVar opId 0 1 [ recordResult.resultVar ] ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        ------------------------------------------
        -- SPECIAL
        ------------------------------------------
        Opt.Shader _ _ _ ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            -- Shader not supported
            { ops = [ ecoConstruct var opId 0 0 [] ]
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

                ( opId, ctx2 ) =
                    freshOpId ctx1
            in
            { ops = [ ecoConstruct var opId 0 0 [] ]
            , resultVar = var
            , ctx = ctx2
            }

        _ ->
            -- Build list from right to left: Cons(head, Cons(head2, ... Nil))
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                ( nilOpId, ctx2 ) =
                    freshOpId ctx1

                nilOp : MlirOp
                nilOp =
                    ecoConstruct nilVar nilOpId 0 0 []

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

                                ( consOpId, ctx4 ) =
                                    freshOpId ctx3

                                consOp : MlirOp
                                consOp =
                                    ecoConstruct consVar consOpId 1 2 [ itemResult.resultVar, tailVar ]
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

        ( opId, ctx3 ) =
            freshOpId ctx2

        arity : Int
        arity =
            List.length fieldList
    in
    { ops = fieldsOps ++ [ ecoConstruct resultVar opId 0 arity fieldVars ]
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

        ( opId, ctx3 ) =
            freshOpId ctx2

        arity : Int
        arity =
            List.length fieldList
    in
    { ops = fieldsOps ++ [ ecoConstruct resultVar opId 0 arity fieldVars ]
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

                ( opId, ctx3 ) =
                    freshOpId ctx2

                funcName : String
                funcName =
                    globalToMLIRName global
            in
            { ops = argsOps ++ [ ecoCall resultVar opId funcName argVars ]
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

                ( opId, ctx3 ) =
                    freshOpId ctx2

                allArgs : List String
                allArgs =
                    ("%" ++ name) :: argVars
            in
            { ops = argsOps ++ [ ecoPapExtend resultVar opId allArgs ]
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

                ( opId, ctx3 ) =
                    freshOpId ctx2

                allArgs : List String
                allArgs =
                    funcResult.resultVar :: argVars
            in
            { ops = funcResult.ops ++ argsOps ++ [ ecoPapExtend resultVar opId allArgs ]
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
                ( opId, ctx1 ) =
                    freshOpId exprResult.ctx

                aliasOp : MlirOp
                aliasOp =
                    ecoConstruct ("%" ++ name) opId 0 1 [ exprResult.resultVar ]

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

        ( opId, ctx2 ) =
            freshOpId ctx1

        aliasOp : MlirOp
        aliasOp =
            ecoConstruct ("%" ++ name) opId 0 1 [ pathVar ]

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

                ( opId, ctx3 ) =
                    freshOpId ctx2

                idx : Int
                idx =
                    Index.toMachine index
            in
            ( subOps ++ [ ecoProject resultVar opId idx subVar ]
            , resultVar
            , ctx3
            )

        Opt.Field name subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generatePath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( opId, ctx3 ) =
                    freshOpId ctx2
            in
            -- TODO: Compute actual field index
            ( subOps ++ [ ecoProject resultVar opId 0 subVar ]
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

                ( opId, ctx3 ) =
                    freshOpId ctx2
            in
            ( subOps ++ [ ecoProject resultVar opId idx subVar ]
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

        ( opId, ctx2 ) =
            freshOpId ctx1
    in
    { ops = [ ecoConstruct resultVar opId 0 0 [] ]
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
