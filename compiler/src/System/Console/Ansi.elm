module System.Console.Ansi exposing
    ( Color(..), ColorIntensity(..), ConsoleLayer(..)
    , ConsoleIntensity(..), Underlining(..), BlinkSpeed(..)
    , SGR(..)
    )

{-| ANSI terminal control codes for text styling and coloring.

This module defines types representing ANSI escape sequence parameters for controlling
terminal text appearance. It provides SGR (Select Graphic Rendition) commands that can
be converted to ANSI escape codes for styling terminal output with colors, intensity,
underlining, and other text effects.


# Colors

@docs Color, ColorIntensity, ConsoleLayer


# Text Styling

@docs ConsoleIntensity, Underlining, BlinkSpeed


# SGR Commands

@docs SGR

-}

-- | ANSI colors: come in various intensities, which are controlled by 'ColorIntensity'


type Color
    = Black
    | Red
    | Green
    | Yellow
    | Blue
    | Magenta
    | Cyan
    | White



-- | ANSI colors come in two intensities


type ColorIntensity
    = Dull
    | Vivid



-- | ANSI colors can be set on two different layers


type ConsoleLayer
    = Foreground
    | Background



-- | ANSI blink speeds: values other than 'NoBlink' are not widely supported


type BlinkSpeed
    = SlowBlink -- ^ Less than 150 blinks per minute
    | RapidBlink -- ^ More than 150 blinks per minute
    | NoBlink



-- | ANSI text underlining


type Underlining
    = SingleUnderline
    | DoubleUnderline -- ^ Not widely supported
    | NoUnderline



-- | ANSI general console intensity: usually treated as setting the font style (e.g. 'BoldIntensity' causes text to be bold)


type ConsoleIntensity
    = BoldIntensity
    | FaintIntensity -- ^ Not widely supported: sometimes treated as concealing text
    | NormalIntensity



-- | ANSI Select Graphic Rendition command


type SGR
    = Reset
    | SetConsoleIntensity ConsoleIntensity
    | SetItalicized Bool -- ^ Not widely supported: sometimes treated as swapping foreground and background
    | SetUnderlining Underlining
    | SetBlinkSpeed BlinkSpeed
    | SetVisible Bool -- ^ Not widely supported
    | SetSwapForegroundBackground Bool
    | SetColor ConsoleLayer ColorIntensity Color
