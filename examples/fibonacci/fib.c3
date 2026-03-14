// Example: Fibonacci JAM Service
module fib;

import jam::codec;
import jam::log;
import jam::service;
import jam::types;

fn void refine(types::RefineArgs* args) @export("refine") {
  log::debug_u64("fib", "Refine: entry, service: ", args.service_id);

  ulong value = 10;
  if (args.work_payload == null || args.work_payload_len == 0)
  {
    log::warn("fib", "Refine: empty payload. Calculating default value=10");
  } else {
    codec::DecodeCtx ctx = codec::decode_ctx_init(args.work_payload, args.work_payload_len);
    ulong? decoded = codec::decode_u8(&ctx);
    if (catch decoded)
    {
      log::warn("fib", "Refine: failed to decode payload. Calculating default value=10");
    } else {
      value = decoded;
    }
  }

  ulong result = fib(value);
  log::debug_u64("fib", "Refine: result ", result);

  char[8] buf;
  if (catch codec::encode_u64(&buf, 8, result)) {return;}
  service::return_to_host(&buf, 8);
}

fn void accumulate(types::AccumulateArgs* args) @export("accumulate") {}

fn ulong fib(ulong n) {
  ulong a;
  ulong b = 1;

  for (ulong i; i < n; i++) {
    ulong t = a + b;
    a = b;
    b = t;
  }

  return a;
}
