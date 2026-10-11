// Offline tests: recorded gRPC messages through the decoder, recorded HTTP/2 server bytes
// through the whole stack, and the formatter self-test. Diffs against fixtures/*.expected.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const update = process.argv.includes("--update");
const cases = {
  "fmt": ["--fmt-test"],
  "grpc-select1": ["--grpc", "fixtures/select1.grpc"],
  "grpc-types": ["--grpc", "fixtures/types.grpc"],
  "grpc-types-json": ["--json", "--grpc", "fixtures/types.grpc"],
  "grpc-decimal128": ["--grpc", "fixtures/decimal128.grpc"],
  "h2-select": ["--replay", "fixtures/select.s2c.bin", "SELECT 1"],
  "h2-error": ["--replay", "fixtures/error.s2c.bin", "SELECT 1"],
  "h2-schema": ["--schema", "--replay", "fixtures/schema.s2c.bin", "SELECT 1"],
  "h2-big": ["--replay", "fixtures/big.s2c.bin", "SELECT 1"],
};
let failed = 0;
for (const [name, args] of Object.entries(cases)) {
  const r = spawnSync("./build/sparkc", args, { encoding: "utf8", maxBuffer: 1 << 26 });
  const got = `exit ${r.status}\n--- stdout\n${r.stdout}--- stderr\n${r.stderr}`;
  const file = `fixtures/${name}.expected`;
  if (update || !existsSync(file)) { writeFileSync(file, got); console.log(`wrote ${file}`); continue; }
  if (readFileSync(file, "utf8") === got) console.log(`ok   ${name}`);
  else { failed++; console.log(`FAIL ${name}\n${got.slice(0, 800)}`); }
}
process.exit(failed ? 1 : 0);
