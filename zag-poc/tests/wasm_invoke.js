#!/usr/bin/env node
// Node.js WASM host fallback when wasmtime/cargo host is unavailable.
// Prefer: tests/wasmtime_run.sh (wasmtime + env::print_* stubs).
// Usage: node wasm_invoke.js <file.wasm> <expected-i32-return>
'use strict';
const fs = require('fs');
const path = process.argv[2];
const expect = Number(process.argv[3]);
if (!path || Number.isNaN(expect)) {
  process.stderr.write('usage: wasm_invoke.js <file.wasm> <expected-i32>\n');
  process.exit(2);
}
const wasm = fs.readFileSync(path);
const imports = {
  env: {
    print_i32: () => {},
    print_u64: () => {},
    print_i64: () => {},
  },
};
WebAssembly.instantiate(wasm, imports)
  .then(({ instance }) => {
    if (typeof instance.exports.main !== 'function') {
      process.stderr.write('missing export: main\n');
      process.exit(1);
    }
    const got = instance.exports.main() | 0;
    if (got !== (expect | 0)) {
      process.stderr.write(`main() returned ${got}, expected ${expect}\n`);
      process.exit(1);
    }
    process.exit(0);
  })
  .catch((err) => {
    process.stderr.write(String(err) + '\n');
    process.exit(1);
  });