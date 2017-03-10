VERSION = "0.91" .. utf8.char(0x3b2) -- beta

if _VERSION ~= "Lua 5.3" then
	print("Error, running " .. _VERSION .. ", it should be Lua 5.3")
	return true
end

local gmatch = string.gmatch
local byte = string.byte
local remove = table.remove
local char = string.char
local floor = math.floor

local lastNote = 60 -- assume middle C
local lastNoteName = "c"
local lastRhythm = false
local lastChord = false
local key = 0
local dataEntry = false
local enteringTuplet = false
local hasRhythmNumberBeenSent = false

local ProcessEvent = {}
local NotesCurrentlyOn = {}
eventsSent = {}
--local keysSent = {}
local keyNoteSent = false
keyNoteOffTime = math.huge

local sendStraightThrough = false
local melismaOn = true
local longRest = "R1*"

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


do
    local t = noteNamesInternational.nederlands
    if useAesEes then
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

local function TurnOffKeyNote()
    local t = GetTime()
    if t > keyNoteOffTime then   
        keyNoteOffTime = math.huge
        SendMidiEvent(0x80 + MyMIDIOutputChannel, keyNoteSent, 0x40)
        keyNoteSent = false
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

local function ChangeKey(modifier)
    key = key or 0
    local oldKey = key
    key = key + modifier
    if key > 7 then
        key = 7
    elseif key < -7 then
        key = -7
    end
    if oldKey ~= key then
        if keyNoteSent then
            -- cancel last note
            SendMidiEvent(0x80 + MyMIDIOutputChannel, keyNotes[oldKey], 0x40)
        end
        SendMidiEvent(0x90 + MyMIDIOutputChannel, keyNotes[key], 0x40)
        keyNoteOffTime = GetTime() + 1.5
        keyNoteSent = keyNotes[key]
    end
end

function AddSharp()
    ChangeKey(1)
end

function AddFlat()
    ChangeKey(-1)
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

function EnterKey()
    if dataEntry then -- The Enter key ends data entry
        if enteringTuplet then
            enteringTuplet = false
            SendString(" {") -- begin the tuplet bracket
            lastRhythm = false
        end
        dataEntry = false
    else
        SendString(" |\n")
    end
 end

function PerformUndo()
    local n = #(eventsSent)
    --print("Undo events: " .. n)
    if n > 0 then
        local myUndo = eventsSent[n]
        eventsSent[n] = nil
        local s = myUndo.codeSent
        SendString(string.rep("\127", #(myUndo.codeSent)), true)
        lastNote = myUndo.lastNote
        lastNoteName = myUndo.lastNoteName
        lastRhythm = myUndo.lastRhythm   
    end
end

function AddDot()
    if lastRhythm and eventsSent[1] then
        lastRhythm = lastRhythm .. "."
        if hasRhythmNumberBeenSent then
            SendString(".")
        else
            SendString(lastRhythm)
            hasRhythmNumberBeenSent = true
        end
    end
    return true
end

function EnharmonicChange()
    local n = #(eventsSent)
    if n > 0 then
        local lastEvent = eventsSent[n]
        local preamble, noteName, theRest = string.match(lastEvent.codeSent, "(%A*)(%a+)(.*)")
        if preamble and noteName and theRest then 
            local note = namesToNumbers[noteName]
            if note then -- make sure a note has actually been sent
                note = note + 12
                if note > 35 then
                    note = ((note - 1) % 12) + 1
                end
                noteName = preamble .. noteNames[note] .. theRest
                SendString(string.rep("\127", #(lastEvent.codeSent)) .. noteName, true)
                lastEvent.codeSent = noteName
            end
        end
    end
end

local absoluteOffsets = {
    [noteNames[2]] = 1, -- add one octave for ceses
    [noteNames[9]] = 1, -- ces
    [noteNames[28]] = -1, -- bis
    [noteNames[35]] = -1,
 }
setmetatable(absoluteOffsets,
    { __index = function(t, k) rawset(t, k, 0) return 0 end })
    

local function FindNoteName(note, lastNote, lastNoteName)
    local relative = (note - keyNotes[key]) % 12
    local name = noteNames[ 16 + key + offsets[relative] ]
    local stepDiff = (steps[name:sub(1,1)] + 7 - steps[lastNoteName:sub(1,1)]) % 7
    if stepDiff > 3 then
        stepDiff = stepDiff - 7
    end
    local octaves
    if AbsoluteMode then
        octaves = (floor(note / 12)) - 4 + absoluteOffsets[name]
    else
        local expected = offsetsToIntervals[namesToNumbers[name] - namesToNumbers[lastNoteName]]
        octaves = (expected - (lastNote - note)) / 12
    end
    
    local suffix = ""
    if octaves > 0 then
        suffix = string.rep("'", octaves)
    elseif octaves < 0 then
        suffix = string.rep(",", -octaves)
    end
    return name, suffix
end

function AddWholeBarRests()
	SendString(longRest)
    dataEntry = true
	lastRhythm = false
end

function Tuplets()
    SendString(" \\tuplet ")
    dataEntry = true
    enteringTuplet = true
end

function AddNote(value)
    value = value or lastRhythm
    local name, suffix, chordHash
    local notes = ListNoteOns()
    -- first get its name according to the key
    local note = notes[1]
    if notes[2] then
        chordHash = table.concat(notes, " ")
    end
    if value == lastRhythm then
        value = ""
        hasRhythmNumberBeenSent = false
    else
        lastRhythm = value
        hasRhythmNumberBeenSent = true
    end
    if note then
        name, suffix = FindNoteName(note, lastNote, lastNoteName)
        lastNote = note
        lastNoteName = name
        name = " " .. name .. suffix .. value
        if chordHash then
            if chordHash == lastChord then
                name = " q" .. value
            else
                local lastNoteInChord, lastNoteNameInChord = lastNote, lastNoteName
                -- strip suffix of first note so it doesn't get doubled
                name = name:gsub("[%'%,]", "")
                -- work out all the notes of the chord
                name = name:match("[a-g][eis]*[%'%,]*")
                name = { " <", name, suffix } -- will be concatenated later
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
        name = " r" .. value
    end
    lastChord = lastChord or false
    SendString(name)
    return hasRhythmNumberBeenSent
end

dofile(ROOT .. "/LQkeyboardEvents.lua")

if useLongValues then
	keystrokesInward["3"][2] = "\\breve"
	longRest = "R\\breve*"
end

if fullRest then
	longRest = "R" .. fullRest .. "*"
end

if type(LQCustomKeyboardEvents) == "table" then
	for k, v in pairs(LQCustomKeyboardEvents) do
		keystrokesInward[k] = v
	end
end

local function ParseForMIDIEvents(packet)
--    print(type(packet), string.byte(packet, 1, -1))
    local noteOnsReceived = false
    -- new code, using string.gmatch
    -- process the packet in the following order: note offs, control changes (which might include bank selection), patch changes, note ons
    
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
    
    TurnOffKeyNote()
    local noteOns = ParseForMIDIEvents(packet)
end

function KeystrokeReceived(c, shiftOn)
    TurnOffKeyNote()
    if dataEntry and c:match("[%d%p]") then
        SendString(c)
        return false
    end
    local params = keystrokesInward[c]
    if params then
        currentUndo = currentUndo or { -- prepare the undo
            lastNote = lastNote,
            lastNoteName = lastNoteName,
            lastRhythm = lastRhythm,
        }
        if type(params) == "table" then
            hasRhythmNumberBeenSent = params[1](params[2])
        else
            --print(params)
            SendString(params)
            hasRhythmNumberBeenSent = false
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
    print("Press " .. f .. " and a key on the MIDI keyboard to exit.") 
    VERSION = nil 
end

return false


