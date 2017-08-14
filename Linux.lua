-- Two Linux-specific routines

-- use this command to open your synthesizer. You may with to replace it with
-- a command with options for Fluidsynth

-- This line uses Lua long string format (between [[ and ]]), so quotes etc. don’t
-- need to be escaped.
-- see https://www.lua.org/manual/5.3/manual.html#3.1

local OpenSynthCommand = [[su -c "qsynth --midi-driver=alsa_seq &" vaughan]]
-- (replace vaughan with your username)

-- This runs Qsynth as user vaughan. Running as root may lose existing settings.
-- To run as root, a simpler alternative is:
-- local OpenSynthCommand = "qsynth --midi-driver=alsa_seq &"

LinuxOpenSynth = function()
	if quitSynthOnOpen then
		QuitSynth()
	end
    local success, message, code = os.execute(OpenSynthCommand)
	if not quitSynthOnClose then
		QuitSynth = nil -- will now not be called on quitting
	end
end

-- Routine to close Qsynth either before 

do
	local synth = "qsynth" -- change to fluidsynth if you don't use Qsynth
	local fail = false
	QuitSynth = function()
		local P = io.popen("pidof " .. synth)
		if P then
			local pid = P:read("a"):match("%d+")
			if pid then
				os.execute("kill " .. pid)
			end
		else
			print("LilyQuick - pidof failed!")
		end
	end
end

--[=[
Typical output for aconnect -i -o is as follows:

    0 'Timer           '
    1 'Announce        '
client 14: 'Midi Through' [type=kernel]
    0 'Midi Through Port-0'
client 24: 'KeyStudio' [type=kernel]
    0 'KeyStudio MIDI 1'
client 129: 'Client-129' [type=user]
    0 'Virtual RawMIDI '
client 130: 'FLUID Synth (4548)' [type=user]
    0 'Synth input port (4548:0)'
--]=]

-- These settings shouldn’t need to be changed, unless you have multiple RawMIDI ports
-- and need to specify one of them.
local RawMIDISearch = "Virtual RawMIDI"
local SynthInputSearch = "Synth input port"

local function Escape(s)
    s = s:gsub("%p",
        function(c)
            return "%" .. c
        end
    )
    return s:gsub("%s+", "%%s+")
end

RawMIDISearch = Escape(RawMIDISearch)
SynthInputSearch = Escape(SynthInputSearch)

-- Searches for a RawMIDI output and a FLUID Synth input and joins them up 
LinuxAconnect = function()
    local speedyOut, synthIn
    local A = io.popen("aconnect -i -o", "r")
    local line = A:read("l")
    while line do
        local clientNo = line:match("client%s+(%d+)%:")
        if clientNo then
            local l = A:read("l")
            if not l then
                break
            end
            local port = l:match("(%d).-" .. RawMIDISearch)
            if port then
                speedyOut = clientNo .. ":" .. port
            else
                port = l:match("(%d).-" .. SynthInputSearch)
                if port then
                    synthIn = clientNo .. ":" .. port
                end
            end
        end
        line = A:read("l")
        -- abort early if both have been found?
     end
     A:close()
     if speedyOut and synthIn then
        os.execute("aconnect " .. speedyOut .. " " .. synthIn)
        return true
     end
     return false
end

-- finally, derive the ALSA device ID
do
    MIDIKeyboardName = MIDIKeyboardName or "MIDI"
    MIDIKeyboardName = MIDIKeyboardName:gsub("%p", 
        function(c)
            return "%" .. c
        end)
    MIDIKeyboardName = MIDIKeyboardName:gsub("%s+", "%%s+")
    
    local A = io.popen("amidi -l", "r")
    local line = A:read("l")
    while line do
        local amdid = line:match("(hw%:%d+%,%d+%,?%d*).- " .. MIDIKeyboardName)
        if amdid then
            AlsaMIDIDeviceID = amdid
        end
        line = A:read("l")
    end
end

if not AlsaMIDIDeviceID then
    print("ALSA MIDI device not found!")
	return true
end

-- work out if any keyboard exceptions are relevant
--[[
do
    local K = io.popen("LANG=C && setxkbmap -query")
    local s = K:read("a")
    K:close()
    local l = s:match("layout%:%s+(%a%a)")
    if l and keyboardExceptions[l] then
        keyboardExceptions = keyboardExceptions[l]
    else
        keyboardExceptions = {}
    end
end
--]]
if specialKeyboardLayout and keyboardExceptions[specialKeyboardLayout] then
    keyboardExceptions = keyboardExceptions[specialKeyboardLayout]
else
    keyboardExceptions = {}
end


return false
--AlsaMIDIDeviceID = AlsaMIDIDeviceID or "hw:2,0,0"



