
maxUndos = 10

noteNamesInternational = {
    nederlands = {
        "feses", "ceses", "geses", "deses", "ases", "eses", "beses", -- double flats
        "fes", "ces", "ges", "des", "as", "es", "bes",
        "f", "c", "g", "d", "a", "e", "b",
        "fis", "cis", "gis", "dis", "ais", "eis", "bis",
        "fisis", "cisis", "gisis", "disis", "aisis", "eisis", "bisis",
    },
}

offsetsToIntervals = {
    [-12] = 0,
    [-11] = 5,
    [-10] = -2,
    [-9] = 3,
    [-8] = -4,
    [-7] = 1,
    [-6] = 6,
    [-5] = -1, --des to c is one semitone down
    [-4] = 4,
    [-3] = -3,
    [-2] = 2,
    [-1] = -5,
    [0] = 0,
    [1] = 5,
    [2] = -2,
    [3] = 3,
    [4] = -4,
    [5] = 1,
    [6] = -6,
    [7] = -1,
    [8] = 4,
    [9] = -3,
    [10] = 2,
    [11] = -5,
    [12] = 0
}

offsets = {
    [0] = 0,
    7, -- c# is plus 7
    2,
    -3,
    4,
    -1,
    6,
    1,
    8,
    3,
    -2,
    5,
}

keyNotes = {}
do
    local note = 11
    for i = -7, 7 do
        keyNotes[i] = (( note + 11 ) % 12 ) + 61
        note = ( note + 7 ) % 12
    end
end


steps = {
    c = 0,
    d = 1,
    e = 2,
    f = 3,
    g = 4, 
    a = 5,
    b = 6,
}

local char = string.char
local byte = string.byte
local tunpack = table.unpack

function RealSendMidiEvent(...)
    local s = ...
    if type(s) == "number" then
        s = char(...)
    end
    --print(GetTime(), s:byte(1,3))
    SendMidiData(s)
end

function SendMidiEvent(...)
    -- send patch first
    RealSendMidiEvent(char(0xc0 | MIDIOutputChannel, PreferredPatch))
    RealSendMidiEvent(...)
    SendMidiEvent = RealSendMidiEvent
    RealSendMidiEvent = nil
    MIDIOutputChannel = nil
end

-- this is sent as the program is exiting
function AllNotesOff() -- actually all sounds off
    for channel = 0, 15 do
        SendMidiEvent(0xb0 | channel, 120, 0)
    end
end

-- Keyboard output
local lower = string.lower
local shiftMask = 0x1000
local removeMask = shiftMask - 1

-- this is for US keyboard layouts (for '!', press shift and '1' for example)
-- Exceptions or special characters can be entered below
local shiftCodes = "~`!1@2#3$4%5^6&7*8(9)0_-+={[}]|\\:;\"'<,>.?/"

-- this table of keycodes is from /usr/include/linux/input.h

local keyCodes = {
    ["1"] = 2,
    ["2"] = 3,
    ["3"] = 4,
    ["4"] = 5,
    ["5"] = 6,
    ["6"] = 7,
    ["7"] = 8,
    ["8"] = 9,
    ["9"] = 10,
    ["0"] = 11,
    ["-"] = 12,
    ["="] = 13,
    ["\127"] = 14,
    ["\t"] =15,
    ["q"] = 16,
    ["w"] = 17,
    ["e"] = 18,
    ["r"] = 19,
    ["t"] = 20,
    ["y"] = 21,
    ["u"] = 22,
    ["i"] = 23,
    ["o"] = 24,
    ["p"] = 25,
    ["["] = 26,
    ["]"] = 27,
    ["\n"] = 28,
--    KEY_LEFTCTRL            29
    ["a"] = 30,
    ["s"] = 31,
    ["d"] = 32,
    ["f"] = 33,
    ["g"] = 34,
    ["h"] = 35,
    ["j"] = 36,
    ["k"] = 37,
    ["l"] = 38,
    [";"] = 39,
    ["'"] = 40,
    ["`"] = 41,
--    KEY_LEFTSHIFT           42
    ["\\"] = 43,
    ["z"] = 44,
    ["x"] = 45,
    ["c"] = 46,
    ["v"] = 47,
    ["b"] = 48,
    ["n"] = 49,
    ["m"] = 50,
    [","] = 51,
    ["."] = 52,
    ["/"] = 53,
    [" "] = 57,
}

setmetatable(keyCodes, {
    __index = function(t,c)
        local n
        if c:match("%u") then
            n = keyCodes[lower(c)]
        else
            n = keyCodes[shiftCodes:match("%" .. c .. "(.)")]
        end
        if n then
            n = n | shiftMask
            rawset(t, c, n) -- cache it
            return n
         end
         return false -- cause an error
    end })

local charpattern = utf8.charpattern

-- Keyboard exceptions can be used for special characters, or for characters
-- that don’t type properly on your local keyboard. To find your keyboard
-- layout type:
--
-- > setxkbmap -query
--
-- One line should say:
-- layout:     us,us
-- for example. The format for the keypresses is a set of parenthesis
-- (mandatory) with modifier keys -- () means no modifier. S = shift,
-- A = alt, C = control --(AC) is equivalent to AltGr. This is followed
-- by a single character (the key to be pressed), or one of the capital
-- words in extraKeys below.

keyboardExceptions = {
    ["us"] = {
        -- For right single quote, compose key, quote, shift dot (for '>') 
        ["’"] = "()COMPOSE ()' (S).",
    },
    ["de"] = {
        -- For double quotes on German keyboards, shift 2
        ["\""] = "(S)2",
        ["'"] = "(S)\\",
        ["{"] = "(G)7",
        ["}"] = "(G)0",
        ["/"] = "(S)7",
        ["\\"] = "(G)-",
        ["("] = "(S)8",
        [")"] = "(S)9",
    
    },
}

function SendString(s, deletingFlag)
    local myGap = gapBetweenKeystrokes or #s > 7
    if not deletingFlag then
        myKeyStrokesSent[#myKeyStrokesSent+1] = s
    end
    for c in s:gmatch(charpattern) do
        local ke = specialKeyboardLayout and keyboardExceptions[c]
        if ke then
            SendKeyCombos(ke)
        else
            local shift = false
            local code = keyCodes[c]
            if code then
                if code & shiftMask ~= 0 then
                    shift = true
                    code = code & removeMask
                end
                SendKeystroke(code, shift, myGap)
            end
        end
    end
	if (not deletingFlag) and currentUndo then
        lastStringSent = s
        --currentUndo.codeSent = s
        local n = eventsSent.n + 1
        eventsSent[n] = currentUndo
        eventsSent.n = n
        eventsSent[n - maxUndos] = nil
        currentUndo = nil
    end
end

--[[
function PrintMyTable()
    for k, v in pairs(MyTable) do
        print(k, v)
    end
end
--]]

function DoScheduledEvent(eventTable)
    local f = eventTable[1]
    if type(f) == "function" then
        f(tunpack(eventTable, 2))
    end
end

local modifierKeys = {
    S = 42, -- KEY_LEFTSHIFT
    A = 56, -- KEY_LEFTALT
    C = 29, -- KEY_LEFTCTRL
    G = 100, -- KEY_RIGHTALT
}

local extraKeys = {
    BACKSPACE = 14, -- left delete
    UP = 103,
    DOWN = 108,
    LEFT = 105,
    RIGHT = 106,
    DELETE = 111, -- right delete
    HOME = 102,
    END = 107,
    PAGEUP = 104,
    PAGEDOWN = 109,
    -- according to input.h, KEY_COMPOSE is 127. For me 127 is the menu key.
    -- if the compose key doesn’t work, perhaps try 127
    COMPOSE = 126,
    RETURN = 28, -- Enter key on the main keyboard
}

setmetatable(extraKeys, { __index = keyCodes })

-- This function takes a formatted string and converts it to raw key presses.
-- Each key press may be preceeded with shift, alt or control in brackets.
-- So "(AC)DOWN" sends the down arrow with alt and control pressed
-- Use () for no modifiers

function SendKeyCombos(s)
    for modifiers, key in s:gmatch("%((%u*)%)(.%u*)") do
        local codes = {}
        for m in modifiers:gmatch("%u") do
            codes[#codes+1] = modifierKeys[m]
        end
        codes[#codes+1] = extraKeys[key]
        if codes[1] then
            SendKeyCombo(table.unpack(codes))
        end
    end
end

