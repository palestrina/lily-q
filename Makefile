# Don’t look at this makefile. If you know anything about Make it will make your eyes bleed.

all:
	cd LuaSource && make linux
	rm LuaSource/*.o
	rm LuaSource/lua
	rm LuaSource/luac
	gcc -ILuaSource -LLuaSource -o lq LilyQuick.c -ldl -lm \
		-llua -lpthread -lasound
	rm LuaSource/liblua.a

