AS = as
LD = ld
SRCS = src/sys.s src/out.s src/main.s src/pb.s src/arrow.s src/hpack.s src/h2.s src/dns.s src/hpack_tables.s
OBJS = $(SRCS:src/%.s=build/%.o)

all: build/sparkc

build/%.o: src/%.s src/layout.inc | build
	$(AS) --64 -g -o $@ $<

build/sparkc: $(OBJS)
	$(LD) -static -nostdlib -o $@ $(OBJS)
	@ls -l $@ | awk '{print "build/sparkc: " $$5 " bytes"}'

# formatter self-test binary: links the stubs instead of the protocol files
build/sparkc-fmt: build/sys.o build/out.o build/main.o build/pb.o build/arrow.o build/dns.o build/stubs.o
	$(LD) -static -nostdlib -o $@ $^

build/stubs.o: test/stubs.s | build
	$(AS) --64 -o $@ $<

build:
	mkdir -p build

test: build/sparkc
	node test/run.mjs

clean:
	rm -rf build
.PHONY: all test clean
