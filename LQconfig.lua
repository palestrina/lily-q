-- You should be able to find your computer keyboard somewhere in /dev/input
deviceName = "/dev/input/by-id/usb-Apple__Inc_Apple_Keyboard-event-kbd"

-- Something that identifies your MIDI keyboard (enough to be unique)
-- type amidi -l for a listing of MIDI devices
MIDIKeyboardName = "KeyStudio MIDI"

-- If the computer keyboard is an Apple Extended Keyboard, use F16-F19 instead of F9-F12
AppleExtendedKeyboard = true

-- Use false or nil for the output channel to stay the same as the input channel
-- Channel 16 is least likely to intefere with MIDI playback.
MIDIOutputChannel = 16

-- Use false or nil to retain the input velocity, a number to play at a standard velocity
OutputVelocity = false

-- Does the damper pedal emit 0 for ON and 127 for OFF? Mine does. Sometimes
WeirdDamperPedal = false

PreferredPatch = 1 -- Bright piano works nicely in Fluidsynth

-- Input in absolute mode or relative mode?
AbsoluteMode = false

-- add other languages to Auxillary_stuff.lua if needed
inputLanguage = "nederlands"

-- I prefer aes to as and ees to es
useAesEes = true

-- if this is set to true, the 3 key will produce \breve instead of 32
useLongValues = false

-- What a full bar rest looks like.
-- Use false for default values "1" or "\breve"
-- Otherwise "2." for example
fullRest = "1" 

-- Debian insists that F2 is monitor brightness. This makes it F2
FixFunctionKeys = true

