# spark-connect-asm

A [Spark Connect](https://spark.apache.org/docs/latest/spark-connect-overview.html)
SQL client in x86-64 assembly. GNU assembler, Linux syscalls, no libc, no libraries: the
binary speaks HTTP/2 and HPACK, frames gRPC, encodes the protobuf request, reads the Arrow
IPC stream and formats the result, all in about 4,000 lines of assembly. Statically linked,
it is 25176 bytes stripped.

It is a port of [spark-connect-wasm](../spark-connect-wasm), function for function, with
the same memory layout, so the two can be read side by side. The WebAssembly text format is
structured assembly over a linear memory, which is what made the port mechanical: each WAT
function became a label with the same locals in callee-saved registers, and every
`(i32.load (i32.const 0xB003))` became a `mem+0xB003(%rip)` operand.

```sh
make
./build/sparkc "SELECT id, CAST(id AS DOUBLE)/3 d, array(id, NULL) a FROM range(0, 3)"
```

```
id | d | a
0 | 0.0 | [0, NULL]
1 | 0.333333333333333 | [1, NULL]
2 | 0.666666666666667 | [2, NULL]
3 row(s)
```

Flags: `-r sc://host:port`, `--json` for one object per row, `--schema` and `--explain`
through AnalyzePlan. Names resolve without libc: dotted quads, `localhost`, `/etc/hosts`,
then one UDP A query to the first nameserver in `/etc/resolv.conf` (`--resolve name` shows
the answer). Plaintext only: TLS stays outside the binary, so Databricks needs something
terminating TLS in front, such as `stunnel`.

## Layout

| File | What |
|---|---|
| `src/sys.s` | syscalls, the static memory block, a bump allocator over one `mmap` |
| `src/out.s` | output buffer and every formatter: integers, decimals, doubles (SSE2), dates, timestamps, hex, JSON strings |
| `src/pb.s` | protobuf writer for ExecutePlan and AnalyzePlan requests, response walker, gRPC message framing |
| `src/arrow.s` | flatbuffers accessors, schema as a tree of field records, batch buffer assignment, value printing incl. list, struct and map |
| `src/hpack.s` | Huffman tree, static and dynamic tables, header block decoding, integer and string encoding |
| `src/h2.s` | frames: preface, SETTINGS, PING, HEADERS/CONTINUATION, DATA, RST_STREAM, GOAWAY; the request |
| `src/dns.s` | `/etc/hosts`, `/etc/resolv.conf`, a UDP DNS A query |
| `src/main.s` | argument parsing, socket, read loop, exit status |
| `src/hpack_tables.s` | generated from RFC 7541 by `scripts/gen-hpack-tables.mjs` |

## Tests

```sh
make test
```

All offline. The binary has two replay modes used only by the tests: `--grpc file` feeds
recorded gRPC messages to the decoder, and `--replay file "SQL"` drives the full HTTP/2
stack from recorded server bytes with sends discarded. `--fmt-test` runs the formatters.
Fixtures were recorded from Spark 4.2.0 by the wasm project's capture scripts; outputs are
diffed against `fixtures/*.expected`.

## Not supported

Dictionary-encoded or compressed Arrow batches, TLS, IPv6, and the DataFrame API (SQL
only, by design).
