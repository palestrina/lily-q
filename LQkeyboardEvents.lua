--[[

How the incoming numeric keypad keystrokes are handled. There are two forms:
a plain string is just typed, and if a table is passed, the first entry is a 
function to be called, with the other entry to passed as parameters. To pass 
multiple paramaters, send a table (see the function Articulation below). If '
strings are passed, backslashes should be escaped (so that "\(" becomes "\\(" ).

--]]


keystrokesInward = {
    -- Note entry values (0-6 on the numeric keypad) are now taken care of
    -- in the initialization. (See LilyQuick.lua c. 581-667)
    -- The following (now commented) values of 0-6 may still be set and will
    -- override other settings (on a case by case basis). So if you want a stable 
    -- custom keypad layout, you may still want to set 0-6 here.
    
    --[[ begin commenting
    ["0"] = { AddNote, false }, 
    ["1"] = { AddNote, "8" },
    ["2"] = { AddNote, "16" }, 
    ["3"] = { AddNote, "32" },
    ["4"] = { AddNote, "4" },
    ["5"] = { AddNote, "2" },
    ["6"] = { AddNote, "1" },
    -- end commenting --]]
    
	["7"] = { AddWholeBarRestsInit },
	["8"] = { Tuplets },
	-- for fixed tuplets, use this line
	-- ["8"] = { Tuplets, "3/2" },
    ["9"] = { CloseBrackets },
    ["\009"] = { InitChangeKey }, -- F9 or F16
    ["SHIFT \009"] = { ToggleAbsoluteRelative },
    ["\010"] = { SetBarLength }, -- F10 or F17
    ["SHIFT \010"] = { InitSetNoteLengths },
    ["\011"] = { ToggleRhythmCounting },  -- F11 or F18.
    ["SHIFT \011"] = {ToggleMidiOnly },
    ["\012"] = { AdjustingOctavesInit }, -- F12 or F19
    ["SHIFT \012"] = { ToggleDisabled },
    ["C"] = { PerformUndo }, -- clear/Numlock
    ["="] = "~", 
    ["."] = { AddDot },
    ["+"] = { Articulation, { "(", ")" } }, 
	["*"] = { EnharmonicChange },
	["-"] = { Articulation,  { "\\startTrillSpan", "\\stopTrillSpan" } }, -- or your choice of articulation
	["SHIFT E"] = { EnterKey, true },
    ["E"] = { EnterKey },
    ["/"] = "~",
}



