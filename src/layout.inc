# Memory layout, shared by every file. `mem` is one static block; offsets match the wasm
# client so the two implementations can be read side by side.
#   0x0100 session uuid (36)   0x0140 operation uuid (36)   0x0180 digit scratch (to 0x1a0)
#   0x01c0 raw uuid bytes      0x0400 string constants
#   0x1000 HPACK/HTTP2 state (see h2.s)   0x11000 OUT text buffer (64 KiB)
#   0x21000 STAGE: the request is assembled here, 5 bytes in, for the gRPC prefix
#   0x121000 HDRBLK: outgoing HPACK block, then incoming header block fragments (64 KiB)
	.set MEM_SIZE,   0x131000
	.set SESSION,    0x100
	.set OPID,       0x140
	.set DIGITS,     0x180
	.set DIGITS_END, 0x1a0
	.set UUIDRAW,    0x1c0
	.set OUT,        0x11000
	.set OUT_CAP,    0xFF00
	.set STAGE,      0x21000
	.set REQ,        0x21005
	.set HDRBLK,     0x121000
	.set HEAP_SIZE,  0x40000000

# HTTP/2 and HPACK regions
	.set HUFF_TREE,  0x2000       # 256 internal nodes x {left, right} (i32 each; leaf = 0x80000000|sym)
	.set DYN_TABLE,  0x3000       # 128 entries x 32 bytes: name ptr(8) value ptr(8) name len(4) value len(4)
	.set ARENA_A,    0x4000
	.set ARENA_B,    0x6000
	.set NAME_BUF,   0x8000
	.set NAME_CAP,   0x400
	.set VAL_BUF,    0x8400
	.set VAL_CAP,    0x2c00
	.set FRAME_BUF,  0xB000
	.set FRAME_HDR,  0x10000
	.set SETTINGS,   0x10040
	.set WINUPD,     0x10060
	.set STATIC_REC, 0x10080
	.set AUTHORITY,  0x10100
	.set PREFACE,    0x10200

# dynamic table entry
	.set E_NAME, 0
	.set E_VAL, 8
	.set E_NLEN, 16
	.set E_VLEN, 20

# field record (64 bytes) for the Arrow reader
	.set F_NAME, 0        # name ptr (8)
	.set F_NLEN, 8        # name len
	.set F_TT, 12         # type_type
	.set F_P0, 16
	.set F_P1, 20
	.set F_VALID, 24      # validity ptr (8), 0 = no nulls
	.set F_BUFA, 32       # data or offsets (8)
	.set F_BUFB, 40       # var-length data (8)
	.set F_NKIDS, 48
	.set F_LEN, 52
	.set F_KIDS, 56       # ptr to array of child record ptrs (8 each)
	.set F_SIZE, 64
