effect module Terminal where { subscription = MySub } exposing
    ( Configuration, Size, configuration
    , setStdinRawMode, setTitle
    , onResize
    )

{-| A program run from a terminal may want to colour its output, draw to the
size of the window, read single keypresses or set the window title. This
module tells it whether a terminal is there, how many colours it can show and
how big it is, and lets it switch stdin into raw mode, set the title and hear
about resizes.

A _terminal_ here is a standard stream connected to a terminal device rather
than to a file or a pipe. `configuration` and `setTitle` act on stdout, and
`setStdinRawMode` on stdin: `configuration` gives `Nothing` and the other two
do nothing when that stream is not a terminal. There is therefore no setup
step, and none of the tasks can fail. `configuration` is how a program finds
out whether stdout is a terminal.

On the native backend on Windows, running any of these tasks, or subscribing
with `onResize`, stops the program with a fatal error saying it is not
supported there yet.


## Configuration

@docs Configuration, Size, configuration


## Commands

@docs setStdinRawMode, setTitle


## Subscriptions

@docs onResize

-}

import Eco.Kernel.Terminal
import Platform
import Process
import Task exposing (Task)


{-| What is known about the terminal on stdout: how many colours it can show,
and the size of its window in character cells.

`colorDepth` is a number of bits per colour: `1` for no colour, `4` for 16
colours, `8` for 256 colours and `24` for true colour. It is not asked of the
terminal but guessed from the environment, by the first of these rules that
applies:

  - a non-empty `NO_COLOR`, or `TERM=dumb`, gives `1`;
  - `FORCE_COLOR` set to exactly `0`, `1`, `2` or `3` gives `1`, `4`, `8` or
    `24`;
  - `COLORTERM` set to `truecolor` or `24bit` gives `24`;
  - a `TERM` ending in `256color` gives `8`;
  - otherwise it is `4`.

The size is the one stdout reports or, when stdout reports a width of zero,
the one another standard stream that is a terminal reports (stdin, then
stderr, on the native backend; stderr on the JS backend). `columns` and `rows`
are both `0` when none can be read.

-}
type alias Configuration =
    { colorDepth : Int
    , columns : Int
    , rows : Int
    }


{-| The size of a terminal window, in character cells.
-}
type alias Size =
    { columns : Int
    , rows : Int
    }


{-| Gets the configuration of the terminal on stdout, or `Nothing` when stdout
is not a terminal, as when the output is redirected to a file or a pipe.

It reads the terminal again each time it is run, so a later run reports the
current size.

-}
configuration : Task x (Maybe Configuration)
configuration =
    kGetConfiguration
        |> Task.mapError never
        |> Task.map
            (Maybe.map
                (\( colorDepth, columns, rows ) ->
                    { colorDepth = colorDepth, columns = columns, rows = rows }
                )
            )


{-| Switches stdin into raw mode with `True`, and back to its original mode with
`False`. It does nothing when stdin is not a terminal.

In its original mode a terminal usually hands input over a line at a time,
once the user presses enter. In raw mode every keypress is sent over the stdin
stream as it happens, and is not echoed. Key combinations such as Ctrl-C arrive
as input too, rather than raising a signal, so `System.onSignalInterrupt` does
not see them.

The original mode is the one stdin had when this was first run. It is restored
when the process exits, but on the native backend not when a fatal error stops
the program. It is also restored when the program is ended by an interrupt
(`SIGINT`) or terminate (`SIGTERM`) signal it does not subscribe to, unless,
on the native backend, the program is embedded in a host application, which
keeps its own signal handling; any other signal that ends the program leaves
raw mode on. While the program subscribes to that signal
with `System.onSignalInterrupt` or `System.onSignalTerminate`, the signal does
not end it and raw mode stays on.

-}
setStdinRawMode : Bool -> Task x ()
setStdinRawMode toggle =
    kSetStdInRawMode toggle
        |> Task.mapError never


{-| Sets the title of the terminal window, as shown in the title bar or tab of a
terminal emulator.

It writes the title escape sequence (OSC 2) to stdout when stdout is a
terminal, and does nothing otherwise, so the sequence never ends up in a
redirected file or pipe. ASCII control characters, DEL included, are removed
from `title` first, so that none of them (BEL or ESC in particular) can end
the sequence early. Whether the title changes is up to the terminal, and a
failure to write is ignored.

-}
setTitle : String -> Task x ()
setTitle title =
    kSetTitle title
        |> Task.mapError never


{-| Creates a subscription to changes in the size of the terminal, with the new
size.

A size arrives each time the program receives `SIGWINCH`, the signal the
operating system sends when a terminal's window is resized, and may equal the
previous one. It is read as `configuration` reads its size, falling back to
the other standard streams also when stdout is not a terminal, and nothing
arrives when no standard stream reports one, or, on the native backend, when
the program is embedded in a host application. The subscription does not keep
the program running.

-}
onResize : (Size -> msg) -> Sub msg
onResize toMsg =
    subscription (OnResize (\( columns, rows ) -> toMsg { columns = columns, rows = rows }))



-- EFFECT MANAGER
--
-- These definitions run only on the JS backend. The native backend runs the
-- C++ manager registered as "Terminal"
-- (src/eco-system/Terminal/TerminalManager.{hpp,cpp}) in their place, and that
-- manager mirrors the constructor layout of MySub: keep the two in sync. On JS,
-- one listener process (a kernel binding that never completes) runs while
-- there is at least one OnResize subscription, and is killed when the last one
-- goes away.


{-| A subscription the manager holds. `OnResize` carries the function that turns
a new size, as `( columns, rows )`, into the program's message.
-}
type MySub msg
    = OnResize (( Int, Int ) -> msg)


{-| Applies `f` to the messages a subscription produces.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnResize tagger) =
    OnResize (tagger >> f)


{-| The manager's state on the JS backend: the current subscriptions' message
functions, in the order the program declared them, and the listener process
while there are any.
-}
type alias State msg =
    { taggers : List (( Int, Int ) -> msg)
    , listener : Maybe Process.Id
    }


{-| A message the listener process sends to the manager. `Resized` carries the
new size as `( columns, rows )`.
-}
type Event
    = Resized ( Int, Int )


{-| The manager's starting state: no subscriptions and no listener.
-}
init : Task Never (State msg)
init =
    Task.succeed { taggers = [], listener = Nothing }


{-| Replaces the stored subscriptions with `subs`, starting the listener process
when the first subscription appears and killing it when the last one goes.
-}
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


{-| Sends a new size to every current subscription, in the order they were
declared, leaving the state unchanged.
-}
onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router (Resized size) state =
    state.taggers
        |> List.map (\tagger -> Platform.sendToApp router (tagger size))
        |> Task.sequence
        |> Task.map (\_ -> state)



-- KERNELS
-- The type annotations fix the kernel ABI: the kernels rely on exactly these
-- argument and result shapes.


{-| A task that reads the terminal on stdout as `( colorDepth, columns, rows )`,
or `Nothing` when stdout is not a terminal.
-}
kGetConfiguration : Task Never (Maybe ( Int, Int, Int ))
kGetConfiguration =
    Eco.Kernel.Terminal.getConfiguration


{-| Produces a task that switches stdin into raw mode or back to its original
mode.
-}
kSetStdInRawMode : Bool -> Task Never ()
kSetStdInRawMode =
    Eco.Kernel.Terminal.setStdInRawMode


{-| Produces a task that writes the title escape sequence to stdout when it is a
terminal.
-}
kSetTitle : String -> Task Never ()
kSetTitle =
    Eco.Kernel.Terminal.setTitle



-- JS-only kernel, used by the effect manager above; it has no C++ counterpart.


{-| Produces a task that never completes and, until its process is killed, runs
the task the given function makes from the new `( columns, rows )` on each
`SIGWINCH` for which a size can be read.
-}
kAttachResizeListener : (( Int, Int ) -> Task Never ()) -> Task Never ()
kAttachResizeListener =
    Eco.Kernel.Terminal.attachResizeListener
