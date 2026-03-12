// Example: Storage Demo JAM Service
// Demonstrates reading/writing to on-chain key-value storage.
module storage_demo;

import jam::types;
import jam::service;
import jam::storage;
import jam::codec;
import jam::log;

// ---------------------------------------------------------------------------
// Refine
// Receives a work payload containing a number, doubles it, returns result.
// ---------------------------------------------------------------------------

fn void refine(types::RefineArgs* args) @export("refine")
{
    log::info("storage", "Refine: processing work item");

    if (args.work_payload == null || args.work_payload_len == 0)
    {
        log::warn("storage", "Refine: empty payload");
        return;
    }

    codec::DecodeCtx ctx = codec::decode_ctx_init(args.work_payload, args.work_payload_len);

    ulong value;
    ulong? decoded = codec::decode_u64(&ctx);
    if (catch decoded)
    {
        log::err("storage", "Refine: failed to decode payload");
        return;
    }
    value = decoded;

    ulong result = value * 2;
    char[8] out_buf;
    if (catch codec::encode_u64(&out_buf, 8, result))
    {
        log::err("storage", "Refine: failed to encode result");
        return;
    }
    log::debug_u64("storage", "Refine: result", result);
    service::return_to_host(&out_buf, 8);
}

// ---------------------------------------------------------------------------
// Accumulate
// Stores a counter in KV storage, incrementing each time.
// ---------------------------------------------------------------------------

fn void accumulate(types::AccumulateArgs* args) @export("accumulate")
{
    log::info("storage", "Accumulate: entry");

    char[4] key = { 'c', 'n', 't', 'r' };
    char[8] val_buf;
    ulong counter = 0;

    ulong? maybe_bytes = storage::kv_read(&key, 4, &val_buf, 0, 8);
    if (try bytes_read = maybe_bytes)
    {
        codec::DecodeCtx ctx = codec::decode_ctx_init(&val_buf, bytes_read);
        ulong? maybe_v = codec::decode_u64(&ctx);
        if (try v = maybe_v)
        {
            counter = v;
        }
    }

    counter++;

    char[8] out_buf;
    if (catch codec::encode_u64(&out_buf, 8, counter))
    {
        log::err("storage", "Accumulate: failed to encode counter");
        return;
    }

    if (catch storage::kv_write(&key, 4, &out_buf, 8))
    {
        log::err("storage", "Accumulate: failed to write counter");
        return;
    }

    log::debug_u64("storage", "Accumulate: counter", counter);
}
