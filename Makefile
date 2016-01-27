all: ./testing/gmock/.git ./testing/gtest/.git ./third_party/icu/.git ./tools/gyp/.git projects compile

./testing/gmock/.git ./testing/gtest/.git ./third_party/icu/.git ./tools/gyp/.git:
	git submodule update --init

./allowed:
	mkdir allowed

projects:
	build/gyp_chromium --depth=. sandbox_test/sandbox_test.gyp

compile:
	ninja -C out/Debug sb_test

run: ./allowed
	./out/Debug/sb_test

clean:
	rm -rf ./out

