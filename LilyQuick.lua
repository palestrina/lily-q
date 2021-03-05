VERSION = "1.01"
if _VERSION ~= "Lua 5.3" then
    print("Error, running " .. _VERSION .. ", it should be Lua 5.3")
    return true
end

local gmatch = string.gmatch
local byte = string.byte
local remove = table.remove
local char = string.char
local floor = math.floor
local math_abs = math.abs
local string_rep = string.rep
local lastNote = 60 -- assume middle C
local lastNoteName = "c"
local lastRhythm = false
local savedRhythm = "4"
local lastChord = false
local dataEntry = false
local enteringTuplet = false
local tupletRatio
local hasRhythmNumberBeenSent = false
local ProcessEvent = {}
local NotesCurrentlyOn = {}
eventsSent = { n = 0 }
local keyNoteSent = false
keyNoteOffTime = math.huge
local sendStraightThrough = false
local melismaOn = true
local longRest = "R1*"
local auxiliaryKeystroke = false
local rhythmMultiplier = 1.0
local cumulativeNoteLength = 0.0
local deleteOneChar = "()\127 "
local currentUndo
local maxUndos = 10
local isNote
local bracketStack = {}
local barLength
local barLengthNumber = 1.0
local recentNewLine = true
local isNewLine = false
local isDisabled = false

-- ROOT has been pushed by the C caller
dofile(ROOT .. "/Auxillary_stuff.lua")
dofile(ROOT .. "/LQconfig.lua")

-- LQExtraSettings.lua is my personal file so I can have my own settings
do
 local F = io.open(ROOT .. "/LQExtraSettings.lua", "r")
 if F then
  F:close()
  dofile(ROOT .. "/LQExtraSettings.lua")
 end
end

local key = defaultKey or 0

do
    local t = noteNamesInternational.nederlands
    if useAesEes then
        t[5] = "aeses"
        t[6] = "eeses"
        t[12] = "aes"
        t[13] = "ees"
    end
end

inputLanguage = inputLanguage or "nederlands"
local noteNames = noteNamesInternational[inputLanguage] or noteNamesInternational.nederlands
local namesToNumbers = {}
for i, name in ipairs(noteNames) do
    namesToNumbers[name] = i
end

local MyMIDIOutputChannel
if MIDIOutputChannel then 
    MIDIOutputChannel = MIDIOutputChannel - 1
    MyMIDIOutputChannel = MIDIOutputChannel
end

local OutputVelocity = OutputVelocity
local WeirdDamperPedal = WeirdDamperPedal
if args[1] then
    deviceName = args[1]
end

local function AddToTable(t, ...)
    for i = 1, select("#", ...) do
        t[#t+1] = select(i, ...)
    end
end

local function ListNoteOns()
    local t = {}
    for k, v in pairs(NotesCurrentlyOn) do
        if v then
            t[#t+1] = k
        end
    end
    table.sort(t)
    return t
end

local function IsClose(a, b, tolerance)
    tolerance = tolerance or 1.0e-6
    return math_abs(a-b) < tolerance
end

local function CheckPowerTwo(n)
    n = tonumber(n)
    if n then
        local l = math.log(n, 2)
        if l == math.floor(l) then
            return n
        end  
    end
    return false
end

local myDotValue
local dotSuffix = {
    [0] = "",
    [584963] = ".",
    [807355] = "..",
    [906891] = "...",
}
local function DurationToValue(d)
    d = d * 2048.0 -- avoid negative log results (problematic)
    local value, dots = math.modf(math.log(d, 2))
    local i = math.floor(dots * 1.0e6 + 0.5)
    dots = dotSuffix[math.floor(dots * 1.0e6 + 0.5)]
    value = value - 11.0
    if value < 1 then
        value = tostring(math.floor(2^-value+0.5))
    elseif value == 1.0 then
        value = "\\breve"
    elseif value == 2.0 then
        value = "\\longa"
    end
    return dots and value .. dots
end

local function ValueToDuration(value)
    local main, dots = value:match("([^%.]+)(%.*)")
    local dotValue
    if main == "\\breve" then
        value = 2.0
        dotValue = 1.0
    elseif main == "\\longa" then
        value = 4.0
        dotValue = 2.0
    else
        value = 1.0 / tonumber(main)
        dotValue = value * 0.5
    end
    for i = 1, #dots do
        value = value + dotValue
        dotValue = dotValue * 0.5
    end
    return value
end

local function ChangeKey(newKey)
    local oldKey = key
    key = newKey
    if key > 7 then
        key = 7
    elseif key < -7 then
        key = -7
    end
    SendMidiEvent(0x90 + MyMIDIOutputChannel, keyNotes[key], 0x40)
    ScheduleEvent(GetTime() + 0.618033989, { SendMidiEvent, 0x80 + MyMIDIOutputChannel, keyNotes[key], 0x40 })
end

local myModifier
local function ChangingKey(c)
    if c == "-" then
        myModifier = -myModifier
    elseif c:match("[0-7]") then
        local k = tonumber(c) * myModifier
        local plural = "s"
        if math.abs(k) == 1 then
            plural = ""
        end
        ChangeKey(k)
        local m
        if k < 0 then
            m = "New key: " .. -k .. " flat" .. plural .. "."
        elseif k > 0 then
            m = "New key: " .. k .. " sharp" .. plural .. "."
        else
            m = "New key: no sharps or flats."
        end
        print(m)
        auxiliaryKeystroke = false
    else
        print("Valid keys are from -7 to 7")
    end
end

function InitChangeKey()
    auxiliaryKeystroke = ChangingKey
    myModifier = 1
end

function Alternate(t)
    local n = t.n or 1
    local code = t[n] or "Error- invalid index in Alternate table"
    n = n + 1
    if not(t[n]) then
        n = 1
    end
    t.n = n
    SendString(code)
end

-- Delete (undo) whatever has just been typed
local function DeleteString(s)
    --go through the UTF-8 codepoints in the string in reverse
    local l = utf8.len(s)
    if l then
         for p = l, 1, -1 do
            local c = utf8.codepoint(s, utf8.offset(s, p))
            --print(c)
            if c == 10 then -- "\n"
                SendKeyCombos("()END (S)HOME ()BACKSPACE ()BACKSPACE")
            else
                SendKeyCombos("()BACKSPACE")
            end
        end
    end
end

function PerformUndo()
    local n = eventsSent.n
    local myUndo = eventsSent[n]
    --print("Undo events: " .. n)
    if myUndo then
        eventsSent[n] = nil
        eventsSent.n = eventsSent.n - 1
        DeleteString(myUndo.stringSent)
        lastNote = myUndo.lastNote
        lastNoteName = myUndo.lastNoteName
        lastRhythm = myUndo.lastRhythm
        cumulativeNoteLength = myUndo.cumulativeNoteLength
        tupletRatio = myUndo.tupletRatio
        myDotValue = myUndo.myDotValue
        rhythmMultiplier = myUndo.rhythmMultiplier
        hasRhythmNumberBeenSent = myUndo.hasRhythmNumberBeenSent
        -- recentNewLine will soon be set to isNewLine anyway
        isNewLine = myUndo.recentNewLine
        bracketStack[#bracketStack+1] = myUndo.bracketStack -- may well be nil
    end
end

local barCheck = " |\n"
function EnterKey(_, shifted)
    if explicitRhythmsByLine then
        lastRhythm = false
    end
    cumulativeNoteLength = 0.0
    myDotValue = false
    isNewLine = true
    if shifted then
        SendString("") -- when shifted this just resets the bar's rhythmic values
    else
        SendString(barCheck)
    end
end

function AddDot()
    if lastRhythm and next(eventsSent) then
        local lineEndingSuffix = ""
        if rhythmCounting then
            local thisLength = myDotValue
            local total = cumulativeNoteLength + thisLength
            if IsClose(total, barLengthNumber) then -- end of a bar
                lineEndingSuffix = " |\n"
                cumulativeNoteLength = 0.0
                myDotValue = false
            elseif total < barLengthNumber then -- a tie is intended
                cumulativeNoteLength = total
            else
                return false
            end
            myDotValue = thisLength * 0.5
        end
        lastRhythm = lastRhythm .. "."
        savedRhythm = lastRhythm
        if hasRhythmNumberBeenSent then
            SendString(".")
        else
            SendString(lastRhythm)
            hasRhythmNumberBeenSent = true
        end
        SendString(lineEndingSuffix)
    end
    return true
end

local spaceBeforeArticulations = spaceBeforeArticulations or ""

local articulationsSent = {}
local emptyEvent = {}

function Articulation(a)
    local spaceBeforeArticulations = spaceBeforeArticulations or ""
    local myArt
    if type(a) == "table" then
        local prev = articulationsSent[a]
        if prev then
            local n = 1
            while (not myArt) and n <= #a do
                if prev == a[n] then
                    myArt = a[n+1] or a[1]
                end
                n = n + 1
            end
        else
            myArt = a[1]
        end
        articulationsSent[a] = myArt
    elseif type(a) == "string" then
        myArt = a
    end
    if myArt then
        if myArt:match("^[%-%^%_]") then
            spaceBeforeArticulations = ""
        end
        local lastEvent = eventsSent[eventsSent.n] or emptyEvent
        local before, after
        local s = lastEvent.stringSent or ""
        local border = s:find("[^%_%-%^]%|") -- avoid staccatissimo "-|"
        if border then
            before = s:sub(1, border)
            after = s:sub(border + 1)
            while before:match(".-%s$") do
                after = before:sub(-1) .. after
                before = before:sub(1, -2)
            end
         else
            before = s
            after = ""
        end
        if (not border) or leftArticulations[myArt] then -- no barcheck/newline sent
            SendString(spaceBeforeArticulations .. myArt)
        else
            lastEvent.stringSent = before
            DeleteString(after)
            SendString(spaceBeforeArticulations .. myArt .. after)
        end
    else
        print("Error- articulation not specified")
    end
end


function EnharmonicChange()
    local n = eventsSent.n
    local lastEvent = eventsSent[n]
    if lastEvent then
        local preamble, noteName, theRest = string.match(lastEvent.stringSent, "(%A*)(%a+)(.*)")
        if preamble and noteName and theRest then 
            local note = namesToNumbers[noteName]
            if note then -- make sure a note has actually been sent
                note = note + 12
                if note > 35 then
                    note = ((note - 1) % 12) + 1
                end
                noteName = preamble .. noteNames[note] .. theRest
                DeleteString(lastEvent.stringSent)
                SendString(noteName, true)
                --lastEvent.lastNoteName = noteName
                lastEvent.stringSent = noteName
            end
        end
    end
end

local absoluteOffsets = {
    [noteNames[2]] = 1, -- add one octave for ceses
    [noteNames[9]] = 1, -- ces
    [noteNames[28]] = -1, -- bis
    [noteNames[35]] = -1, -- bisis
 }
setmetatable(absoluteOffsets,
    { __index = function(t, k) rawset(t, k, 0) return 0 end })
    
local waitingForNote = true
local function FindNoteName(note, lastNote, lastNoteName)
    -- in relative mode, never put octave indications on the first note
    if waitingForNote then
        lastNote = note
        waitingForNote = false
    end
    local relative = (note - keyNotes[key]) % 12
    local name = noteNames[ 16 + key + offsets[relative] ]
    local stepDiff = (steps[name:sub(1,1)] + 7 - steps[lastNoteName:sub(1,1)]) % 7
    if stepDiff > 3 then
        stepDiff = stepDiff - 7
    end
    local octaves
    if AbsoluteMode then
        octaves = (note // 12) - 4 + absoluteOffsets[name]
    else
        local expected = offsetsToIntervals[namesToNumbers[name] - namesToNumbers[lastNoteName]]
        octaves = (expected - (lastNote - note)) // 12
    end
    
    local suffix = ""
    if octaves > 0 then
        suffix = string.rep("'", octaves)
    elseif octaves < 0 then
        suffix = string.rep(",", -octaves)
    end
    return name, suffix
end

local function AdjustOctave(adjustment)
    local top = eventsSent.n
    if top then
        local p = top
        local event = eventsSent[p]
        local toDelete = ""
        while event and event.isNote == nil do
            toDelete = toDelete .. event.stringSent
            p = p - 1
            event = eventsSent[p]
        end
         if event then
            local note, octaves, rest = event.stringSent:match("(%s*%l+)([%,%']*)(.*)")
            if note then
                DeleteString(octaves .. rest .. toDelete)
                local myOctave = #octaves
                if octaves:sub(1,1) == "," then
                    myOctave = -myOctave
                end
                myOctave = myOctave + adjustment
                local marker = "'"
                if myOctave < 0 then
                    marker = ","
                    myOctave = -myOctave
                end
                octaves = string_rep(marker, myOctave)
                SendString(octaves .. rest .. toDelete, true)
                event.stringSent = note .. octaves .. rest
            end    
        end
    end
end

local function AdjustingOctaves(c)
	auxiliaryKeystroke = false
	if c == "+" then
		AdjustOctave(1)
	elseif c == "-" then
		AdjustOctave(-1)
	end
end

function AdjustingOctavesInit()
	auxiliaryKeystroke = AdjustingOctaves
end

local function AddingWholeBarRests(c)
    if c == "E" then
        lastRhythm = false
        myDotValue = false
        cumulativeNoteLength = 0.0
        SendString("\n") -- maybe " |\n" if you prefer a bar check
        isNewLine = true
        auxiliaryKeystroke = false
    elseif c:match("%d") then
        SendString(c)
    end
end

function AddWholeBarRestsInit()
    SendString(longRest)
    auxiliaryKeystroke = AddingWholeBarRests
end

local function RevertRhythm(ratio)
    rhythmMultiplier = rhythmMultiplier / ratio
    if IsClose(rhythmMultiplier, 1.0) then
        rhythmMultiplier = 1.0
    end
end

local myTupletString = "\\tuplet "
local function EnteringTuplets(c)
    if c:match("[%d%/]") then
        tupletRatio = tupletRatio .. c
        SendString(c)
    elseif c == "E" then -- enter key
        local ratio = 1.0
        local num, den = tupletRatio:match("(%d+)%/(%d+)")
        if num then
            ratio = tonumber(den) / tonumber(num)
            rhythmMultiplier = ratio
        end
        bracketStack[#bracketStack+1] = { f = RevertRhythm, a = ratio }
        SendString(" {")
        auxiliaryKeystroke = false
    elseif c == "C" then -- clear key
        if #tupletRatio > 0 then
            tupletRatio = tupletRatio:sub(1, -2) -- chop off the last character
            SendString("\127")
        else
            SendString(string_rep("\127", #myTupletString))
            auxiliaryKeystroke = false
        end
    end
end

function Tuplets(ratio)
    if ratio then
        ratio = ratio:match("%d+%/%d+")
    end
    if not recentNewLine then
		SendString(" ")
    end
    SendString(myTupletString)
    myDotValue = false
    if ratio then
        tupletRatio = ratio
        SendString(ratio)
        EnteringTuplets("E") -- simulate the Enter key
    else
        auxiliaryKeystroke = EnteringTuplets
        tupletRatio = ""
    end
end

myEndBracket = " }"
function CloseBrackets()
    if bracketStack[1] then
        local t = bracketStack[#bracketStack]
        currentUndo.bracketStack = t
        bracketStack[#bracketStack] = nil
        t.f(t.a)
    end
    SendString(myEndBracket)
end

local function EnteringBarLength(c)
    if c:match("[%d%/%.]") then
        barLength = barLength .. c
    elseif c == "+" then
        barLength = barLength .. "\\breve"
    elseif c == "E" then
        fullRest = barLength
        print("Bar length entered: " .. fullRest)
        fullRest = fullRest:gsub("%\\breve", "B") -- would have used 0.5 but dots are confusing
        if fullRest:match("%d+%/[%d+B]+") then
            local num, den, dots = fullRest:match("(%d+)%/([B%d]+)(%.*)")
            if den == "B" then
                den = 0.5
            else
                den = CheckPowerTwo(den)
            end
            if den then
                den = 1.0 / den
                local dot = den * 0.5
                for i = 1, #dots do
                    barLengthNumber = barLengthNumber + dot
                    dot = dot * 0.5
                end
                barLengthNumber = tonumber(num) * den
            end
         else
            local value, dots = fullRest:match("([%d+B])(%.*)")
            if value then
                if value == "B" then
                    value = 0.5
                else
                    value = CheckPowerTwo(value)
                end
                if value then
                    barLengthNumber = 1.0 / value
                    local dot = barLengthNumber * 0.5
                    for i = 1, #dots do
                        barLengthNumber = barLengthNumber + dot
                        dot = dot * 0.5
                    end
                end
            end
        end
        barLength = barLength:gsub("%/", "*")
        longRest = "R" .. barLength .. "*"
        auxiliaryKeystroke = false
        fullRest = barLength
        cumulativeNoteLength = 0.0
    end
end

function SetBarLength()
    barLength = ""
    auxiliaryKeystroke = EnteringBarLength
end

function AddNote(value, isShifted)
    local lineEndingSuffix = ""
    local eraseLineCode = ""
    value = value or savedRhythm
    if rhythmCounting then
        local thisLength = ValueToDuration(value) * rhythmMultiplier
        local total = cumulativeNoteLength + thisLength
        myDotValue = thisLength * 0.5
        if IsClose(total, barLengthNumber) then -- end of a bar
            lineEndingSuffix = " |\n"
            isNewLine = true
            eraseLineCode = eraseLine
            cumulativeNoteLength = 0.0
            myDotValue = false
        elseif total > barLengthNumber then -- a tie is intended
            lineEndingSuffix = "~ |\n"
            isNewLine = true
            eraseLineCode = eraseLine
            value = DurationToValue(barLengthNumber - cumulativeNoteLength) or value
            cumulativeNoteLength = 0.0
            myDotValue = false
        else
            cumulativeNoteLength = total
        end
    end
    local name, suffix, chordHash
    local notes = ListNoteOns()
    -- first get its name according to the key
    local note = notes[1]
    if notes[2] then
        chordHash = table.concat(notes, " ")
    else
        lastChord = false
    end
    if (value == lastRhythm) and (not explicitRhythms) then
        value = ""
        hasRhythmNumberBeenSent = false
    else
        lastRhythm = value
        hasRhythmNumberBeenSent = true
    end
    local leadingSpace = " "
    --print(recentNewLine)
    if recentNewLine then
		leadingSpace = ""
    end
    if note then
        isNote = true
        name, suffix = FindNoteName(note, lastNote, lastNoteName)
        lastNote = note
        lastNoteName = name
        name = leadingSpace .. name .. suffix .. value
        if chordHash then
            if chordHash == lastChord then
                name = leadingSpace .. "q" .. value
            else
                local lastNoteInChord, lastNoteNameInChord = lastNote, lastNoteName
                -- strip suffix of first note so it doesn't get doubled
                name = name:gsub("[%'%,]", "")
                -- work out all the notes of the chord
                name = name:match("[a-g][eis]*[%'%,]*")
                name = { leadingSpace, "<", name, suffix } -- will be concatenated later
                for i = 2, #(notes) do
                    local n, s = FindNoteName(notes[i], lastNoteInChord, lastNoteNameInChord)
                    AddToTable(name, " ", n, s)
                    lastNoteInChord = notes[i]
                    lastNoteNameInChord = n
                end
                AddToTable(name, ">", value)
                name = table.concat(name)
                lastChord = chordHash
            end
        end
    else
        if isShifted then
            name = leadingSpace .. "s" .. value
        else
            name = leadingSpace .. "r" .. value
        end
    end
    lastChord = lastChord or false
    savedRhythm = lastRhythm
    if explicitRhythmsByLine and lineEndingSuffix:match("%s%|") then
        lastRhythm = false
    end
    -- close triplet brackets if it is the end of a line
    -- (this doesn’t allow for tuplets over barlines)
    SendString(name)
    if lineEndingSuffix ~= "" then
        while bracketStack[1] do
            CloseBrackets()
        end
        SendString(lineEndingSuffix)
    end
        return
end

-- these note lengths don’t change through different layouts
-- (except for the Denemo layout), and are reachable through a metatable
local defaultNoteLengths = { 
    ["0"] = false,
    ["1"] = "8",
    ["4"] = "4",
    ["5"] = "2",
}

local defaultNoteLengthMeta = { __index = defaultNoteLengths }

local noteLengths = {
    ["5"] = {
        ["6"] = "64",
        ["3"] = "32",
        ["2"] = "16",
    },
    ["6"] = {
        ["6"] = "1",
        ["3"] = "32",
        ["2"] = "16",
    },
    ["3"] = {
        ["6"] = "1",
        ["3"] = "\\breve",
        ["2"] = "16",
    },
    ["2"] = {
        ["6"] = "1",
        ["3"] = "\\breve",
        ["2"] = "\\longa",
    },
    ["0"] = {   -- Denemo mode
        ["0"] = "1",
        ["1"] = "2",
        ["2"] = "4",
        ["3"] = "8",
        ["4"] = "16",
        ["5"] = "32",
        ["6"] = "64",
    },
}   

local keysZeroToSix = {}

local function SettingNoteLengths(c)
    local t = noteLengths[c]
    if t then
        chosenNoteLengths = c
        setmetatable(t, defaultNoteLengthMeta)
        for n = 0, 6 do
            local numKey = tostring(n)
            local length = t[numKey]
            keysZeroToSix[numKey] = { AddNote, length }
        end
    end
    print("Numeric keys and note lengths:")
    local k = keysZeroToSix["0"][2]
    if k then
        print("0: " .. k)
    end
    for i = 1, 6 do
        print(i .. ": " .. keysZeroToSix[tostring(i)][2])
    end
    
    auxiliaryKeystroke = false
end

function InitSetNoteLengths()
    print("Enter longest note- 2: \\longa, 3: \\breve, 6: 1, 5: 2")
    print("Or 0: Denemo layout")
    auxiliaryKeystroke = SettingNoteLengths
end

do
    local longNoteToNum = {
        ["\\longa"] = "2",
        ["\\breve"] = "3",
        ["1"] = "6",
        ["2"] = "5",
        ["D"] = "0",
    }
    local longestNoteOnKeypad = longestNoteOnKeypad or "1"
    chosenNoteLengths = longNoteToNum[longestNoteOnKeypad] or "6"
end

if fullRest then
    longRest = "R" .. fullRest .. "*"
end

local firstAbsRel = true
function ToggleAbsoluteRelative()
    AbsoluteMode = not(AbsoluteMode or firstAbsRel)
    firstAbsRel = false
    if AbsoluteMode then
        print("Absolute mode selected.")
    else
        print("Relative mode selected.")
        waitingForNote = true
    end
end

function ToggleMidiOnly()
    midiOnly = not midiOnly
    if midiOnly then
        print("Notes from midi only with last rhythm")
    else
        print("Notes from midi and keypad")
    end
end

function ToggleRhythmCounting()
    rhythmCounting = not rhythmCounting
    if rhythmCounting then
        print("Rhythm counting on")
        EnterKey(true) -- reset the start of the bar
    else
        print("Rhythm counting off")
    end
end

function ToggleDisabled()
	isDisabled = not isDisabled
	if isDisabled then
		auxiliaryKeystroke = false
	end
	DisableNumericKeypad(isDisabled)
end

-- NO KEYBOARD FUNCTION INITIALISERS BELOW HERE
dofile(ROOT .. "/LQkeyboardEvents.lua")
if type(LQCustomKeyboardEvents) == "table" then
 for k, v in pairs(LQCustomKeyboardEvents) do
  keystrokesInward[k] = v
 end
end

setmetatable(keystrokesInward, { __index = keysZeroToSix })

local function ParseForMIDIEvents(packet)
--    print(type(packet), string.byte(packet, 1, -1))
    local noteOnsReceived = false
    -- new code, using string.gmatch
    -- process the packet in the following order: note offs, control changes
    -- (which might include bank selection), patch changes, note ons
    
    -- note off
    for midiMessage in gmatch(packet, "[\x90-\x9f][\x00-\x7f]\x00") do -- zero velocity note on
        ProcessEvent.NOTE_OFF(byte(midiMessage, 1, 3))
    end
    for midiMessage in gmatch(packet, "[\x80-\x8f][\x00-\x7f][\x00-\x7f]") do
        ProcessEvent.NOTE_OFF(byte(midiMessage, 1, 3))
    end
 
    -- control changes
    for midiMessage in gmatch(packet, "[\xb0-\xbf][\x00-\x7f][\x00-\x7f]") do
        ProcessEvent.CONTROLLER(byte(midiMessage, 1, 3))
    end
    
--[[
    -- patch changes  
    for midiMessage in gmatch(packet, "[\xc0-\xcf][\x00-\x7f]") do
        ProcessEvent.PROGRAM_CHANGE(byte(midiMessage, 1, 2))
    end
--]]
    -- note ons
    for midiMessage in gmatch(packet, "[\x90-\x9f][\x00-\x7f][\x01-\x7f]") do
        ProcessEvent.NOTE_ON(byte(midiMessage, 1, 3))
        noteOnsReceived = true
    end
    return noteOnsReceived
end

local DamperOn = false
local NoteOffQueue = {}
function ProcessEvent.CONTROLLER(channel, controller, value)
    if MyMIDIOutputChannel then
        channel = 0xb0 + MyMIDIOutputChannel
    else    
        channel = 0xb0 + (channel % 16)
    end
    if controller == 0x40 then
        local isOn = value >= 64
        if WeirdDamperPedal then
            isOn = not isOn
            value = 127 - value
        end
        DamperOn = isOn
        if not isOn then
            for pitch, _ in pairs(NoteOffQueue) do
                NotesCurrentlyOn[pitch] = nil
                NoteOffQueue[pitch] = nil 
            end
        end
    elseif controller == 0x01 then
        value = preferredModulationValue or value
    end
    SendMidiEvent(channel, controller, value)
end

function ProcessEvent.NOTE_OFF(channel, pitch, velocity)
    if DamperOn then
        NoteOffQueue[pitch] = true
    else
        NotesCurrentlyOn[pitch] = nil
    end
    if MyMIDIOutputChannel then
        channel = 0x80 + MyMIDIOutputChannel
    else    
        channel = 0x80 + (channel % 16)
    end
    SendMidiEvent(channel, pitch, 64)
end

function ProcessEvent.NOTE_ON(channel, pitch, velocity)
    if MyMIDIOutputChannel then
        channel = 0x90 + MyMIDIOutputChannel
    end
    -- key = key or (pitch % 12)
    NotesCurrentlyOn[pitch] = true
    if OutputVelocity then
        velocity = OutputVelocity
    else
        velocity = floor((velocity - 1) / (126/40) + 65)
    end
   if midiOnly then
	   AddNote(savedRhythm)
   end
    SendMidiEvent(channel, pitch, velocity)
end

function MidiPacketReceive(packet)
    --[[
    local t = { string.byte(packet, 1, -1) }
    for i, v in ipairs(t) do
        t[i] = string.format("%02X ", v)
    end
    print(table.concat(t))
    --]]
    
    local noteOns = ParseForMIDIEvents(packet)
end

function KeystrokeReceived(c, shiftOn)
    isNote = nil
    isNewLine = false
    if auxiliaryKeystroke then
        auxiliaryKeystroke(c)
        return false
    end
    if shiftOn and byte(c) < 20 then
        c = "SHIFT " .. c
    end
    local params = keystrokesInward[c]
    if params then
        myKeyStrokesSent = {}
        currentUndo = { -- prepare the undo
            lastNote = lastNote,
            lastNoteName = lastNoteName,
            lastRhythm = lastRhythm,
            cumulativeNoteLength = cumulativeNoteLength,
            tupletRatio = tupletRatio,
            myDotValue = myDotValue,
            rhythmMultiplier = rhythmMultiplier,
            recentNewLine = recentNewLine,
            hasRhythmNumberBeenSent = hasRhythmNumberBeenSent,           
        }
        if type(params) == "table" then
            params[1](params[2], shiftOn)
        else
            --print(params)
            SendString(params)
            hasRhythmNumberBeenSent = false
        end
        currentUndo.hasRhythmNumberBeenSent = hasRhythmNumberBeenSent       
        recentNewLine = isNewLine
        if myKeyStrokesSent[1] then
            currentUndo.stringSent = table.concat(myKeyStrokesSent)
            currentUndo.isNote = isNote
            local n = eventsSent.n + 1
            eventsSent[n] = currentUndo
            eventsSent.n = n
            currentUndo = nil
            eventsSent[n - maxUndos] = nil
        end
        return true
    else
        return false
    end
    return false
end

--]===] 
do
    print("Welcome to LilyQuick version " .. VERSION)
    local f = "F8"
    if AppleExtendedKeyboard then
        f = "F15"
    end
    print("Press " .. f .. " to exit.") 
    VERSION = nil
    SettingNoteLengths(chosenNoteLengths)
    chosenNoteLengths = nil
end

function PlayFlourish()
    local t = GetTime()
    local chords = {
        { 0.6, 0xc0, 1 },
        { 0.605, 0xb0, 1, 0 },
        { 0.611635, 159, 53, 75 },
        { 0.80585, 159, 59, 77 },
        { 0.922082, 159, 63, 71 },
        { 1.002133, 159, 68, 82 },
        { 2.168721, 143, 68, 64 },
        { 2.170743, 143, 63, 64 },
        { 2.192312, 143, 53, 64 },
        { 2.202704, 143, 59, 64 },
    }
    for i, chord in ipairs(chords) do
        chord[2] = (chord[2] & 0xf0) | MIDIOutputChannel 
        local message = string.char(table.unpack(chord, 2))
        ScheduleEvent(t + chord[1], { SendMidiData, message })
    end
    PlayFlourish = nil
end

return false

