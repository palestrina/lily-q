#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <pthread.h>
#include <alsa/asoundlib.h>
#include <sys/time.h>

#include "LuaSource/lua.h"
#include "LuaSource/lualib.h"
#include "LuaSource/lauxlib.h"

typedef int	bool;
#define true 1
#define false 0


#define die(str, args...) do { \
        perror(str); \
        exit(EXIT_FAILURE); \
    } while(0)

#define EV_KEY          0x01
#define KEY_PRESS 1
#define KEY_RELEASE 0

#define dirSize 2048

pthread_mutex_t myMutex = PTHREAD_MUTEX_INITIALIZER;

__u16 myExitCode;

int stop = 0;
bool stillGoing = true;
bool leftShift, rightShift;
unsigned char midiMessage[4];
int messageCounter = 0;
int bytesExpected = 0;
lua_Number epoch;
lua_Number eventTime = 0;
static bool	noDataInBuffer = true;
static bool gapBetweenKeystrokes;
int lookupTableStackPosition = -2;
lua_State* L;
lua_State* MIDIstack;
int fdo, fdi, fdiAux;
struct uinput_user_dev uidev;
struct input_event ev, syncEv, outEv;
snd_rawmidi_t  *handle_in = 0;
snd_rawmidi_t  *handle_out = 0;

struct schedule_struct {
    lua_Number time;
    int ref;
};

/* Keycodes that will get hooked and not sent on immediately */

lua_Integer numericCodes[] = {
    KEY_F9, 9,
    KEY_F10, 10,
    KEY_F11, 11,
    KEY_F12, 12,

    KEY_F16, 9,
    KEY_F17, 10,
    KEY_F18, 11,
    KEY_F19, 12,
    
    KEY_NUMLOCK, 'C',
    KEY_KPEQUAL, '=',
    KEY_KPSLASH, '/',
    KEY_KPASTERISK, '*',
    KEY_KPMINUS, '-',
    KEY_KPPLUS, '+',
    KEY_KPENTER, 'E',
    KEY_KPDOT, '.',
    KEY_KP0, '0',
    KEY_KP1, '1',
    KEY_KP2, '2',
    KEY_KP3, '3',
    KEY_KP4, '4',
    KEY_KP5, '5',
    KEY_KP6, '6',
    KEY_KP7, '7',
    KEY_KP8, '8',
    KEY_KP9, '9',
    0, 0
};

/*
static void PrintStack(lua_State * L)
{
    int i;
    int n = lua_gettop(L);
    for (i = -n; i < 0; i++) {
        printf("%d %s\n", i, lua_typename(L, lua_type(L, i)));
    }
    printf("\n");
}
*/

static lua_Number getTimer()
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (lua_Number) tv.tv_sec - epoch + (lua_Number) tv.tv_usec * 1.0e-6;
}

static int GetTime(lua_State * L)
{
	lua_pushnumber(L, getTimer());
	return 1;
}

static int DisableNumericKeypad(lua_State * L)
{
	if (lua_toboolean(L, -1))
	{
		printf("Numeric keypad disabled.\n");
		lookupTableStackPosition = -3;
	}
	else
	{
		printf("Numeric keypad enabled.\n");
		lookupTableStackPosition = -2;
	}
	return 0;
}

static void *DoEvent(void *twoArgs)
{
    struct timespec myGap;
    struct schedule_struct *args = twoArgs;
    lua_Number secs, nanos;

    lua_Number gap = args->time - getTimer();
    if (gap > 0) {
        nanos = modf(gap, &secs);
        nanos = nanos * 1.0e9;
    
        myGap.tv_sec = (time_t) secs;
        myGap.tv_nsec = (long) nanos;
    
        nanosleep(&myGap, NULL);
    }
    if (stillGoing) {
        pthread_mutex_lock(&myMutex);
        lua_getglobal(L, "DoScheduledEvent");
        lua_rawgeti(L, LUA_REGISTRYINDEX, args->ref);
        lua_call(L, 1, 0);
        luaL_unref(L, LUA_REGISTRYINDEX, args->ref);
        pthread_mutex_unlock(&myMutex);
        myGap.tv_sec = 0;
        myGap.tv_nsec = rand() % 500000000;
        nanosleep(&myGap, NULL);
    }
  
    pthread_exit(NULL);
    return NULL;
}

static int ScheduleEvent(lua_State * L)
{
	// The scheduled event comes in a table: add it to the registry
	int rc;
	bool flag;
	pthread_t doEventThread;
	
	luaL_checktype(L, 1, LUA_TNUMBER);
	luaL_checktype(L, 2, LUA_TTABLE);
	lua_settop(L, 2);
	struct schedule_struct *myArgs = malloc(sizeof *myArgs);
	
	myArgs->ref = luaL_ref(L, LUA_REGISTRYINDEX);
	myArgs->time = luaL_checknumber(L, 1);
 
    rc = pthread_create(&doEventThread, NULL, &DoEvent, myArgs);
    if (rc) {
        printf("Error creating event thread, error no %d\n", rc);
        return 1;
    }
    return 0;
}


static int SleepUntil(lua_State * L)
{
	int micros;
	lua_Number	startSleep = getTimer();
	lua_Number	endSleep = lua_tonumber(L, 1);
	if (startSleep < endSleep) {
		micros = (int)((endSleep - startSleep) * 1000000.0);
		usleep(micros);
	}
	return 0;
}


static int SendMidiData(lua_State * L)
// The data is in the form of a lua string
{
	size_t length;
	const char *sendData;

	if (lua_isnumber(L, 1))
		printf("Error, MIDI data should be a string!\n");
	else if (lua_isstring(L, 1)) {
		sendData = lua_tolstring(L, 1, &length);
		snd_rawmidi_write(handle_out, sendData, length);
	}
	
	return 0;
}

void sendMIDIToLua(int b)
{
	int length;
	unsigned char c;
	unsigned char *message;
	//lua_Number timer;
	if (b == -1) {
		length = messageCounter;
		messageCounter = 0;
		message = midiMessage;
	} else {
		//send a single byte straight away
			length = 1;
		c = (unsigned char)b;
		message = &c;
	}

    pthread_mutex_lock(&myMutex);
  
	lua_getglobal(MIDIstack, "MidiPacketReceive");
	//lua_pushnumber(MIDIstack, getTimer());
	lua_pushlstring(MIDIstack, message, length);
	if (lua_pcall(MIDIstack, 1, 0, 0) != 0) {
		printf("%s\n", lua_tostring(MIDIstack, -1));
	}
	noDataInBuffer = true;
    pthread_mutex_unlock(&myMutex);
}

void addToBuffer(unsigned char b)
{
    //printf("%02X ", b);
	unsigned char firstNybble = b >> 4;
	if (b < 0x80) {
		//it is a data byte
			if (bytesExpected > 0) {
			//add it to the buffer
				midiMessage[messageCounter++] = b;
			if (--bytesExpected == 0) {
				sendMIDIToLua(-1);
			}
		} else if (bytesExpected < 0) {
			//add it to the sysex buffer
		}
	} else {
		switch (firstNybble) {
		case 0xf:
			switch (b) {
			case 0xf2:
				messageCounter = 1;
				bytesExpected = 2;
				midiMessage[0] = b;
				break;
			case 0xf1:
			case 0xf3:
				messageCounter = 1;
				bytesExpected = 1;
				midiMessage[0] = b;
				break;
			case 0xf0:
				//start exclusive
					bytesExpected = -1;
				//add 0xf0 to the sysex buffer
					break;
			case 0xf7:
				if (bytesExpected < 0) {
					bytesExpected = 0;
					//add 0xf7 to sysex buffer and send it
				}
				break;
			default:
				sendMIDIToLua((int)b);
			}
			break;
		case 0xc:
		case 0xd:
			messageCounter = 1;
			bytesExpected = 1;
			midiMessage[0] = b;
			break;
		default:
			messageCounter = 1;
			bytesExpected = 2;
			midiMessage[0] = b;
			break;
		}
	}
}

static void * KeypadInput()
{
    int i, j;
    char keyStroke[2] = { 0, 0 };
    const char * deviceName;
    const char * auxDeviceName;
    bool fixFunctionKeys;
    bool auxDevice=false;
    fd_set read_fds; 

    /* When the program is launched from the terminal, it can grab the 
     * input before the return button is released, which Linux 
     * interprets as the return key on repeat. This waits for the return
     *  key to be released.
    */
    sleep(1);
    
    memset(&ev, 0, sizeof(syncEv));
    syncEv.type = EV_SYN;

    pthread_mutex_lock(&myMutex);
    lua_getglobal(L, "deviceName");
    deviceName = luaL_checkstring(L, -1);
    lua_pop(L, 1);
    
    lua_getglobal(L, "fixFunctionKeys");
    fixFunctionKeys = lua_toboolean(L, -1);
    lua_pop(L, 1);
    
    lua_getglobal(L, "gapBetweenKeystrokes");
    gapBetweenKeystrokes = lua_toboolean(L, -1);
    lua_pop(L, 1);

    pthread_mutex_unlock(&myMutex);

    fdo = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if(fdo < 0) die("/dev/uinput error: open");
    
    fdi = open(deviceName, O_RDONLY);
    if(fdi < 0) {
	    printf("failed %s\n",deviceName);
	    die("fdi error: open");
	    }

    lua_getglobal(L,"auxDeviceName");
    if(lua_isnil(L,-1)==0){
      auxDevice=true;
      auxDeviceName = luaL_checkstring(L,-1);
      printf("Using %s as aux input device\n",auxDeviceName);
      lua_pop(L,1);
      }

    if(auxDevice){
        fdiAux = open(auxDeviceName, O_RDONLY);
        if(fdiAux < 0) {
    	    printf("failed to open %s\n",auxDeviceName);
    	    auxDevice=false;
    	    }
	else if(ioctl(fdiAux, EVIOCGRAB, 1) < 0) die("error: ioctl 354 on aux input");
        }

    if(ioctl(fdi, EVIOCGRAB, 1) < 0) die("error: ioctl 354");

    if(ioctl(fdo, UI_SET_EVBIT, EV_SYN) < 0) die("error: ioctl 356");
    if(ioctl(fdo, UI_SET_EVBIT, EV_KEY) < 0) die("error: ioctl 357");
    //if(ioctl(fdo, UI_SET_EVBIT, EV_MSC) < 0) die("error: ioctl 41");
    for(i = 0; i < KEY_MAX; ++i)
        if(ioctl(fdo, UI_SET_KEYBIT, i) < 0) die("error: ioctl");

    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "uinput-sample");
    uidev.id.bustype = BUS_USB;
    uidev.id.vendor  = 0x1;
    uidev.id.product = 0x1;
    uidev.id.version = 1;

    if(write(fdo, &uidev, sizeof(uidev)) < 0) die("error: write");
    if(ioctl(fdo, UI_DEV_CREATE) < 0) die("error: ioctl");

    pthread_mutex_lock(&myMutex);
    lua_getglobal(L, "AppleExtendedKeyboard");
    i = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (i) { // does the keyboard go up to F19?
        i = 4; // omit keycodes for F9-F12
        myExitCode = KEY_F15;
        }
    else {
        myExitCode = KEY_F8;
    }
    j = i;
 
    lua_newtable(L); // Table of key values to use when LilyQuick disabled
    while (i < 15) {
        lua_pushinteger(L, numericCodes[i++]);
        lua_pushinteger(L, numericCodes[i++]);
        lua_settable(L, -3);
	}
         
    lua_newtable(L);
    while (numericCodes[j] != 0) {
        lua_pushinteger(L, numericCodes[j++]);
        lua_pushinteger(L, numericCodes[j++]);
        lua_settable(L, -3);
    }
    pthread_mutex_unlock(&myMutex);
    
    while(stillGoing)
    {
	if(auxDevice){
            FD_ZERO(&read_fds);
            FD_SET(fdi,&read_fds);
            FD_SET(fdiAux,&read_fds);
            select(FD_SETSIZE,&read_fds,NULL,NULL,NULL);
            if(FD_ISSET(fdi,&read_fds)){
              if(read(fdi, &ev, sizeof(struct input_event)) < 0)
    	          die("error: read");
            }
	    else if(FD_ISSET(fdiAux,&read_fds)){
    	            if(read(fdiAux, &ev, sizeof(struct input_event)) < 0)
                        die("error: read aux");
                  }
         } else {
    	      if(read(fdi, &ev, sizeof(struct input_event)) < 0)
    	          die("error: read");
	 }
        ev.time.tv_sec = 0;
        ev.time.tv_usec = 0;

        if (ev.code == myExitCode) {
            stillGoing = false;
            break;
        }
        if (ev.type == EV_KEY && (ev.value == 0 || ev.value == 1)) {
            // printf("%d %d %d\n", ev.type, ev.value, ev.code);
            pthread_mutex_lock(&myMutex);
            lua_pushinteger(L, (int) ev.code);
            lua_gettable(L, lookupTableStackPosition);
             /* Not the numeric keypad? Send it on */
            /* Also pass it on if LilyQuick is diabled */
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);
                if (ev.code == KEY_RIGHTSHIFT)
                {
                    rightShift = (bool) ev.value;
                }
                if (ev.code == KEY_LEFTSHIFT)
                {
                    leftShift = (bool) ev.value;
                }
                /* I like to use F2, but Debian insists it's monitor brightness.
                   TODO: fix other function keys
                */
                if (fixFunctionKeys) {
                    if (ev.code == KEY_BRIGHTNESSUP)
                        ev.code = KEY_F2;
                }
                
                
                write(fdo, &ev, sizeof(ev));
                write(fdo, &syncEv, sizeof(syncEv));
            }
            else if (ev.value == 1) { /* only send key presses to Lua */
                keyStroke[0] = (unsigned char) lua_tointeger(L, -1);
                lua_pop(L, 1);
                lua_getglobal(L, "KeystrokeReceived");
                lua_pushlstring(L, keyStroke, 1);
                lua_pushboolean(L, leftShift || rightShift);
                lua_call(L, 2, 0);
            }
            else
            {
                lua_pop(L, 1); // clean up the stack
            }
            pthread_mutex_unlock(&myMutex);
        }
    }
    
    
    if(ioctl(fdo, UI_DEV_DESTROY) < 0) die("error: ioctl 74");

    close(fdi);
    close(fdo);
    pthread_exit(NULL);
    return NULL;
}

static int SendKeystroke(lua_State * L) {
    int ret;
    bool shift;
    bool gap;
    __u16 keyCode;
    
    /* This function expects a key code and whether it should be shifted */
    keyCode = (__u16) luaL_checkinteger(L, 1);
    shift = lua_toboolean(L, 2);
    /* and now whether there should be a gap in case of long sequences */
    gap = lua_toboolean(L, 3);
    
    if (shift) {
        memset(&outEv, 0, sizeof(outEv));
        outEv.type = EV_KEY;
        outEv.code = KEY_LEFTSHIFT;
        outEv.value = KEY_PRESS;
        ret = write(fdo, &outEv, sizeof(outEv));
        ret = write(fdo, &syncEv, sizeof(syncEv));
    }
    
    memset(&outEv, 0, sizeof(outEv));
    outEv.type = EV_KEY;
    outEv.code = keyCode;
    outEv.value = KEY_PRESS;
    ret = write(fdo, &outEv, sizeof(outEv));
    ret = write(fdo, &syncEv, sizeof(syncEv));
    
    memset(&outEv, 0, sizeof(outEv));
    outEv.type = EV_KEY;
    outEv.code = keyCode;
    outEv.value = KEY_RELEASE;
    ret = write(fdo, &outEv, sizeof(outEv));
    ret = write(fdo, &syncEv, sizeof(syncEv));

    if (shift) {
        memset(&outEv, 0, sizeof(outEv));
        outEv.type = EV_KEY;
        outEv.code = KEY_LEFTSHIFT;
        outEv.value = KEY_RELEASE;
        ret = write(fdo, &outEv, sizeof(outEv));
        ret = write(fdo, &syncEv, sizeof(syncEv));
    }
    if (gap) {
        usleep(12000);
    }
    return 0;
}

// This routine is for arrow keys, etc.
// The first x arguments are key codes of keys (eg shift, alt, control) that need to be held down
// The final argument is the key code actually "pressed"

static int SendKeyCombo(lua_State * L) {
    int stackSize;
    __u16 keyCode;
    int slot;
    int ret;
    
    stackSize = lua_gettop(L);
    if (stackSize < 1) {
        printf("No arguments to SendKeyCombo!\n");
        return 0;
    }
    for (slot = 1; slot<stackSize; slot++) {
        keyCode = (__u16) luaL_checkinteger(L, slot);
        memset(&outEv, 0, sizeof(outEv));
        outEv.type = EV_KEY;
        outEv.code = keyCode;
        outEv.value = KEY_PRESS;
        ret = write(fdo, &outEv, sizeof(outEv));
        ret = write(fdo, &syncEv, sizeof(syncEv));
    }
    
    usleep(12000);
    
    keyCode = (__u16) luaL_checkinteger(L, stackSize);
    memset(&outEv, 0, sizeof(outEv));
    outEv.type = EV_KEY;
    outEv.code = keyCode;
    outEv.value = KEY_PRESS;
    ret = write(fdo, &outEv, sizeof(outEv));
    ret = write(fdo, &syncEv, sizeof(syncEv));

    memset(&outEv, 0, sizeof(outEv));
    outEv.type = EV_KEY;
    outEv.code = keyCode;
    outEv.value = KEY_RELEASE;
    ret = write(fdo, &outEv, sizeof(outEv));
    ret = write(fdo, &syncEv, sizeof(syncEv));
    
    usleep(12000);
    
    for (slot = 1; slot<stackSize; slot++) {
        keyCode = (__u16) luaL_checkinteger(L, slot);
        memset(&outEv, 0, sizeof(outEv));
        outEv.type = EV_KEY;
        outEv.code = keyCode;
        outEv.value = KEY_RELEASE;
        ret = write(fdo, &outEv, sizeof(outEv));
        ret = write(fdo, &syncEv, sizeof(syncEv));
    }
    return 0;
}


void *MIDIInput()
{
	int err;
	int i;
	char buffer[1];
	int status;

	const char * device_in;
	char key[] = "My Unique Registry Key (no, really!)";

	pthread_mutex_lock(&myMutex);
	lua_pushstring(L, key);
	MIDIstack = lua_newthread(L);
	 // store the thread in registry to avoid GC
	lua_settable(L, LUA_REGISTRYINDEX);
    lua_getglobal(MIDIstack, "AlsaMIDIDeviceID");
    device_in = luaL_checkstring(MIDIstack, -1);
    lua_pop(MIDIstack, 1);
    lua_getglobal(MIDIstack, "LinuxOpenSynth"); // open the synth
    lua_call(MIDIstack, 0, 0);
	pthread_mutex_unlock(&myMutex);

	err = snd_rawmidi_open(&handle_in, NULL, device_in, SND_RAWMIDI_NONBLOCK);
	if (err) {
		printf("snd_rawmidi_open %s failed: %d\n", device_in, err);
		printf("Error %i (%s)\n", err, snd_strerror(err));
		die("Unable to open midi device");
	} else {
	        //printf("%s opened!\n", device_in);
	}
	
	err = snd_rawmidi_open(NULL, &handle_out, "virtual", SND_RAWMIDI_SYNC);
	if (err) {
		printf("snd_rawmidi_open virtual failed: %d\n", err);
		printf("Error %i (%s)\n", err, snd_strerror(err));
		return NULL;
	} else {
	        //printf("Virtual MIDI opened!\n", device_in);
	}
	
	for (i=1; i<=20; i++) { // try twenty times (20 seconds)
	    usleep(500000);
	    pthread_mutex_lock(&myMutex);
	    lua_getglobal(MIDIstack, "LinuxAconnect");
	    lua_call(MIDIstack, 0, 1);
	    if (lua_toboolean(MIDIstack, -1)) {
	        lua_pop(MIDIstack, 1);
	        // The synth is connected, play the opening flourish
	        lua_getglobal(MIDIstack, "PlayFlourish");
            lua_call(MIDIstack, 0, 0);
	        pthread_mutex_unlock(&myMutex);
	        break;
	    }
	    lua_pop(MIDIstack, 1);
	    pthread_mutex_unlock(&myMutex);
	}
	
	status = 0;
 	while ((status != EAGAIN) && stillGoing) {
	    status = snd_rawmidi_read(handle_in, buffer, 1);
        if ((status < 0) && (status != -EBUSY) && (status != -EAGAIN)) {
            printf("Problem reading MIDI input.");
        }
        else if (status >= 0) {
            addToBuffer((unsigned char) buffer[0]);
        }
    }

    printf("Finishing MIDI thread.\n"); // probably will never get here, but ok if it does

    pthread_exit(NULL);
    return NULL;
}

int main(int argc, char* argv[])
{
    int i, rc;
    char *myDir;
    char *workingDir;
    
    pthread_t keypadThread;
    pthread_t MIDIThread;

	struct timeval	tv;
	gettimeofday(&tv, NULL);
	epoch = (lua_Number) tv.tv_sec;
	
    L = luaL_newstate();
    luaL_openlibs(L);
	lua_pushcfunction(L, SendMidiData);
	lua_setglobal(L, "SendMidiData");
	lua_pushcfunction(L, SleepUntil);
	lua_setglobal(L, "SleepUntil");
	lua_pushcfunction(L, SendKeystroke);
	lua_setglobal(L, "SendKeystroke");
	lua_pushcfunction(L, SendKeyCombo);
	lua_setglobal(L, "SendKeyCombo");
	lua_pushcfunction(L, GetTime);
	lua_setglobal(L, "GetTime");
	lua_pushcfunction(L, ScheduleEvent);
	lua_setglobal(L, "ScheduleEvent");
	lua_pushcfunction(L, DisableNumericKeypad);
	lua_setglobal(L, "DisableNumericKeypad");
	
	myDir = (char *) malloc(dirSize);
 	workingDir = (char *) malloc(dirSize);
 	memset(workingDir, 0, dirSize);
    getcwd(myDir, dirSize);
    if (myDir == NULL) {
        printf("getcwd failed\n");
        return 1;
    }
    lua_pushstring(L, myDir);
    lua_setglobal(L, "ROOT");
    lua_newtable(L);
    for (i=0; i<argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_seti(L, -2, (lua_Integer) i);
    }
    lua_setglobal(L, "args");
    
    strcpy(workingDir, myDir);
    if (luaL_dofile(L, strcat(workingDir, "/LilyQuick.lua")))
        printf("%s\n", lua_tostring(L, -1));
	
    memset(workingDir, 0, dirSize);
    strcpy(workingDir, myDir);
    if (luaL_dofile(L, strcat(workingDir, "/Linux.lua")))
        printf("%s\n", lua_tostring(L, -1));
	i = lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (i) {
		return 1;
	}
    free(workingDir);
    free(myDir);
//*
    rc = pthread_create(&keypadThread, NULL, &KeypadInput, NULL);
    if (rc) {
        printf("Error creating keypadThread, error no %d\n", rc);
        return 1;
    }
//*/
    rc = pthread_create(&MIDIThread, NULL, &MIDIInput, NULL);
    if (rc) {
        printf("Error creating MIDIThread, error no %d\n", rc);
        return 1;
    }
    
    pthread_join(keypadThread, NULL);
    // pthread_join(MIDIThread, NULL);

/*  This code had been moved from the end of the MIDI thread. If that thread
    isn’t joined, it should quit after the main thread quits
*/

    pthread_mutex_lock(&myMutex);
    lua_getglobal(L, "AllNotesOff");
    lua_call(L, 0, 0);
	pthread_mutex_unlock(&myMutex);

    snd_rawmidi_close(handle_in);
    snd_rawmidi_close(handle_out);

	// Quit synthesizer if needed
	pthread_mutex_lock(&myMutex);
	lua_getglobal(L, "QuitSynth");
	if (lua_isfunction(L, -1)) {
		lua_call(L, 0, 0);
	}
	else {
	    lua_pop(L, 1);
	}
	pthread_mutex_unlock(&myMutex);
    return 0;
}

