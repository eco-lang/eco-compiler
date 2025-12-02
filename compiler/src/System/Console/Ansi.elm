module System.Console.Ansi exposing
    ( BlinkSpeed(..)
    , Color(..)
    , ColorIntensity(..)
    , ConsoleIntensity(..)
    , ConsoleLayer(..)
    , SGR(..)
    , Underlining(..)
    )

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
