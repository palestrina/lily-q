
all:
	cd LuaSource && make linux
	rm LuaSource/*.o
	rm LuaSource/lua
	rm LuaSource/luac
	gcc -ILuaSource -LLuaSource -o lq LilyQuick.c -ldl -lm \
		-llua -lpthread -lasound
	rm LuaSource/liblua.a

