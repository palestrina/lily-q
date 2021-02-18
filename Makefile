# Don’t look at this makefile. If you know anything about Make it will make your eyes bleed.
MYDIR := ${CURDIR}

app: 
	gcc   -ILuaSource -LLuaSource -o lq LilyQuick.c -lasound \
		-lpthread -llua -ldl -lm

lib: 
	cd LuaSource && make linux
	rm LuaSource/*.o
	rm LuaSource/lua
	rm LuaSource/luac
#	rm LuaSource/liblua.a



install:
	./installLQ.sh '${MYDIR}'


	

