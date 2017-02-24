--[[

How the incoming numeric keypad keystrokes are handled. There are two forms:
a plain string is just typed, and if a table is passed, the first entry is a 
function to be called, with the other entry to passed as parameters. To pass 
multiple paramaters, send a table (see the function Alternate below). If '
strings are passed, backslashes should be escaped (so that "\(" becomes "\\(" ).

--]]


keystrokesInward = {
    ["0"] = { AddNote, false }, 
    ["1"] = { AddNote, "8" },
    ["2"] = { AddNote, "16" }, 
    ["3"] = { AddNote, "32" },
    ["4"] = { AddNote, "4" },
    ["5"] = { AddNote, "2" },
    ["6"] = { AddNote, "1" },
	["7"] = { AddWholeBarRests },
	["8"] = { Tuplets }, 
    ["9"] = " }",
    ["\009"] = { AddSharp }, -- F9 or F16
    ["\010"] = { AddFlat }, -- F10 or F17
    ["\011"] = nil, -- F11 or F18
    ["\012"] = nil, -- F12 or F19
    ["C"] = { PerformUndo }, -- clear/Numlock
    ["="] = "~", 
    ["."] = { AddDot },
    ["+"] = { Alternate, { " ( ", " ) " } }, 
	["*"] = { EnharmonicChange },
	["-"] = "--", -- or your choice of articulation
    ["E"] = { EnterKey },
    ["/"] = "~",
}



