effect module System.Terminal where { subscription = MySub } exposing
    ( Configuration, Size, getConfiguration
    , setStdInRawMode, setProcessTitle
    , onResize
    )

{-| This lets you interact with the user's terminal, if an interactive terminal is connected to
this application.

Unlike gren-node's `Terminal` module there is no permission value and no `initialize`: call
[`getConfiguration`](#getConfiguration) to find out whether a terminal is attached, and use the
other functions directly.


## Configuration

@docs Configuration, Size, getConfiguration


## Commands

@docs setStdInRawMode, setProcessTitle


## Subscriptions

@docs onResize

-}

import Eco.Kernel.Terminal
import Platform
import Process
import Task exposing (Task)


{-| The configuration of the attached interactive terminal: the number of colours it supports
as a bit depth (`1` for no colour, `4` for 16 colours, `8` for 256 colours, `24` for true
colour) and its current size in character cells.

The colour depth is guessed from the environment: `NO_COLOR` or `TERM=dumb` give `1`,
`FORCE_COLOR`, `COLORTERM` and a `TERM` ending in `256color` raise it.

-}
type alias Configuration =
    { colorDepth : Int
    , columns : Int
    , rows : Int
    }


{-| Size of a terminal. Handy to know for drawing a text-based UI.
-}
type alias Size =
    { columns : Int
    , rows : Int
    }


{-| Get the configuration of the attached terminal.

`Nothing` is returned if this program is not connected to an interactive terminal, which can
happen in CI setups or when used as part of a Unix pipe.

This replaces gren-node's `Terminal.initialize`; it can be called at any time and as often as
you like.

-}
getConfiguration : Task x (Maybe Configuration)
getConfiguration =
    kGetConfiguration
        |> Task.mapError never
        |> Task.map
            (Maybe.map
                (\( colorDepth, columns, rows ) ->
                    { colorDepth = colorDepth, columns = columns, rows = rows }
                )
            )


{-| In its default mode, `stdin` only sends data when the user hits the enter key.

If you switch over to raw mode, every keypress will be sent over the stream, and special
combinations like `Ctrl-C` will no longer trigger the interrupt signal.

Enable this when you need full control over how input is handled. The original terminal mode is
restored when the program exits, also when it is ended by an interrupt (`SIGINT`) or terminate
(`SIGTERM`) signal it does not subscribe to. This does nothing if stdin is not a terminal.

-}
setStdInRawMode : Bool -> Task x ()
setStdInRawMode toggle =
    kSetStdInRawMode toggle
        |> Task.mapError never


{-| Set the title of the running process. This will usually display in activity monitors or in
the title bar of your terminal emulator.

On Linux this sets the process name shown by tools like `top` and `ps -o comm` (at most 15
bytes; the full command line shown by `ps` is unchanged). On macOS it does nothing.

-}
setProcessTitle : String -> Task x ()
setProcessTitle title =
    kSetProcessTitle title
        |> Task.mapError never


{-| A subscription that triggers every time the size of the terminal changes, with the new size.
-}
onResize : (Size -> msg) -> Sub msg
onResize toMsg =
    subscription (OnResize (\( columns, rows ) -> toMsg { columns = columns, rows = rows }))



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "System.Terminal"
-- (src/eco-system/Terminal/TerminalManager.{hpp,cpp}, plans/eco-system-library.md Appendix C.4)
-- and ignores the Elm functions below. The JS backend runs them (plans/eco-system-library.md
-- Phase 10, D15): while there is at least one OnResize subscription, one listener process
-- (a never-completing kernel binding, killed when the last subscription goes away)
-- notifies the manager of each new size through `Platform.sendToSelf`. The constructor
-- layout of MySub is mirrored by TerminalManager.hpp: keep them in sync.


type MySub msg
    = OnResize (( Int, Int ) -> msg)


subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnResize tagger) =
    OnResize (tagger >> f)


type alias State msg =
    { taggers : List (( Int, Int ) -> msg)
    , listener : Maybe Process.Id
    }


type Event
    = Resized ( Int, Int )


init : Task Never (State msg)
init =
    Task.succeed { taggers = [], listener = Nothing }


onEffects : Platform.Router msg Event -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router subs state =
    let
        -- Effects arrive in reverse order of declaration.
        taggers =
            List.reverse subs
                |> List.map (\(OnResize tagger) -> tagger)
    in
    case ( taggers, state.listener ) of
        ( [], Just pid ) ->
            Process.kill pid
                |> Task.map (\_ -> { taggers = [], listener = Nothing })

        ( [], Nothing ) ->
            Task.succeed { taggers = [], listener = Nothing }

        ( _, Just pid ) ->
            Task.succeed { taggers = taggers, listener = Just pid }

        ( _, Nothing ) ->
            Process.spawn (kAttachResizeListener (\size -> Platform.sendToSelf router (Resized size)))
                |> Task.map (\pid -> { taggers = taggers, listener = Just pid })


onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router (Resized size) state =
    state.taggers
        |> List.map (\tagger -> Platform.sendToApp router (tagger size))
        |> Task.sequence
        |> Task.map (\_ -> state)



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.5).


kGetConfiguration : Task Never (Maybe ( Int, Int, Int ))
kGetConfiguration =
    Eco.Kernel.Terminal.getConfiguration


kSetStdInRawMode : Bool -> Task Never ()
kSetStdInRawMode =
    Eco.Kernel.Terminal.setStdInRawMode


kSetProcessTitle : String -> Task Never ()
kSetProcessTitle =
    Eco.Kernel.Terminal.setProcessTitle



-- JS-only kernel, used by the effect-manager body above (the native backend drops that
-- body, so it has no C++ counterpart).


kAttachResizeListener : (( Int, Int ) -> Task Never ()) -> Task Never ()
kAttachResizeListener =
    Eco.Kernel.Terminal.attachResizeListener
