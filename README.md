# JAM SDK for C3

A complete SDK for writing [JAM](https://graypaper.com/) blockchain services in the [C3 programming language](https://c3-lang.org/).

Compiles C3 source code into `.jam` blobs that run on PolkaVM — the virtual machine powering JAM.

## Features

- All JAM protocol types (service IDs, hashes, balances, gas, chain params, etc.)
- 27 host function bindings (storage, transfers, logging, checkpointing, etc.)
- Variable-length natural number codec (Gray Paper Appendix C)
- High-level service API (key-value storage, gas queries, service creation, etc.)
- Entry point dispatch (refine, accumulate, is_authorized)
- Bare metal — no standard library, no libc
- Docker-based build tool that produces `.jam` files in one command

## Using the SDK in Your Project

Add the SDK as a C3 library dependency — your editor/LSP will provide full autocompletion for all `jam::` modules.

```bash
mkdir -p lib
git clone https://github.com/DrEverr/jamsdk.c3l.git lib/jamsdk.c3l
```

Then in your `project.json`:

```json
{
  "dependency-search-paths": ["lib"],
  "dependencies": ["jamsdk"],
  "sources": ["src/**"],
  "use-stdlib": false,
  "link-libc": false
}
```

You can now `import jam::types`, `import jam::service`, etc. with full IDE suggestions.

To update the SDK later:

```bash
cd lib/jamsdk.c3l && git pull
```

## Quick Start

### Prerequisites

- [Docker](https://www.docker.com/) (linux/amd64 — uses x86_64 toolchain)

### Build the Docker Image

```bash
docker build --platform=linux/amd64 -t jamsdk .
```

### Build a Service

```bash
docker run --rm --platform=linux/amd64 \
  -v ./my-service:/work \
  jamsdk my_service.c3
```

Output: `build/my_service.jam`

### Build an Authorizer

```bash
docker run --rm --platform=linux/amd64 \
  -v ./my-auth:/work \
  jamsdk --authorizer my_auth.c3
```

## Writing a Service

A JAM service implements two functions: `refine` (off-chain computation) and `accumulate` (on-chain state changes).

```c3
module my_service;

import jam::types;
import jam::service;
import jam::log;

fn void refine(types::RefineArgs* args) @export("refine")
{
    log::info("svc", "Hello from refine!");

    char[5] result = { 'h', 'e', 'l', 'l', 'o' };
    service::return_to_host(&result, 5);
}

fn void accumulate(types::AccumulateArgs* args) @export("accumulate")
{
    log::info("svc", "Hello from accumulate!");
}
```

### Using Storage

```c3
import jam::storage;
import jam::codec;

fn void accumulate(types::AccumulateArgs* args) @export("accumulate")
{
    char[4] key = { 'c', 'n', 't', 'r' };
    char[8] buf;
    ulong counter = 0;

    // Read existing counter
    ulong? maybe_bytes = storage::kv_read(&key, 4, &buf, 0, 8);
    if (try bytes_read = maybe_bytes)
    {
        codec::DecodeCtx ctx = codec::decode_ctx_init(&buf, bytes_read);
        ulong? maybe_v = codec::decode_u64(&ctx);
        if (try v = maybe_v)
        {
            counter = v;
        }
    }

    counter++;

    // Write updated counter
    char[8] out;
    if (catch codec::encode_u64(&out, 8, counter)) { return; }
    if (catch storage::kv_write(&key, 4, &out, 8)) { return; }

    log::info_u64("svc", "counter", counter);
}
```

### Writing an Authorizer

```c3
module my_auth;

import jam::types;
import jam::log;

fn void is_authorized(types::IsAuthorizedArgs* args) @export("is_authorized")
{
    log::info("auth", "Authorizing request");
}
```

Build with `--authorizer` flag.

## SDK Modules

| Module | Description |
|---|---|
| `jam::types` | All JAM protocol types: ServiceId, Hash, Balance, Gas, RefineArgs, AccumulateArgs, etc. |
| `jam::host` | Raw host function imports (27 functions: gas, read, write, info, transfer, etc.) |
| `jam::codec` | Natural number variable-length encoding/decoding (Gray Paper Appendix C), fixed-width LE codecs |
| `jam::service` | High-level API: gas_remaining, chain_params, service_info, transfer, checkpoint, new_service, etc. |
| `jam::storage` | Key-value storage: kv_read, kv_write, kv_delete |
| `jam::entry` | Entry point dispatch for refine and accumulate |
| `jam::entry_auth` | Entry point dispatch for is_authorized |
| `jam::log` | Logging with levels (error, warn, info, debug, trace) and integer formatting |
| `jam::result` | Fault definitions for error handling |

## Build Options

```
jam-build [options] <source.c3> [additional sources...]

Options:
  --sdk-dir <path>     Path to SDK jamsdk.c3l/ directory (default: auto-detect)
  --output <path>      Output .jam file path (default: build/<name>.jam)
  --authorizer         Build as authorizer instead of service
  --opt <level>        Optimization: O0, O1, O2, O3, Os, Oz (default: O0)
  --keep-intermediates Keep .elf and .polkavm files next to output
```

## Build Pipeline

The `jam-build` script runs a 5-step pipeline:

1. **c3c compile-only** — Compile C3 sources to RISC-V object files (rv64imac, int-only ABI)
2. **clang** — Compile `host_stubs.c` (PolkaVM import/export metadata sections)
3. **ld.lld** — Link all objects into a RISC-V ELF with relocations
4. **polkatool link** — Process ELF into a `.polkavm` binary with dispatch table
5. **polkavm-to-jam** — Convert `.polkavm` to final `.jam` format

## Project Structure

```
jamsdk.c3l/               SDK library (git submodule -> github.com/aspect-build/jamsdk.c3l)
  manifest.json           C3 library manifest
  types.c3                JAM protocol types
  codec.c3                Binary encoding/decoding
  host.c3                 Host function imports
  host_stubs.c            PolkaVM metadata (C glue for ELF sections)
  service.c3              High-level service API
  storage.c3              Key-value storage API
  entry.c3                Refine + accumulate entry points
  entry_authorizer.c3     is_authorized entry point
  log.c3                  Logging
  result.c3               Fault definitions
scripts/
  jam-build               Build script
tools/
  polkavm-to-jam/         Patched polkavm-to-jam converter
examples/
  hello-world/            Minimal service
  storage-demo/           KV storage counter service
  simple-auth/            Minimal authorizer
```

## Requirements

The Docker image bundles all tools. For reference, the toolchain consists of:

- [c3c](https://c3-lang.org/) v0.7.10 — C3 compiler
- [clang](https://clang.llvm.org/) — Cross-compiler for RISC-V host stubs
- [lld](https://lld.llvm.org/) — LLVM linker
- polkatool v0.29.0 — PolkaVM linker
- polkavm-to-jam — PolkaVM to JAM format converter (patched)

## License

See [LICENSE](LICENSE) for details.
