// Bootstrap Service
//
// A genesis service that can create and manage other JAM services.
// Installed at service ID 1000 in the genesis state.
//
// Work item payload format (instruction-based protocol):
// Each instruction is: [opcode: u8][instruction_data...]
// Multiple instructions can be concatenated in a single payload.
//
// Opcodes:
//   0x01 CreateService:
//     [code_hash: 32 bytes]       -- blake2b-256 of the .jam blob (pre-computed by submitter)
//     [code_len: u32 LE]          -- length of the code blob
//     [min_acc_gas: u64 LE]       -- minimum accumulate gas for the new service
//     [min_memo_gas: u64 LE]      -- minimum on-transfer gas
//     [endowment: u64 LE]         -- tokens to transfer to the new service
//     [flags: u8]                 -- bit 0: desired_id present, bit 1: gratis_offset present
//     if flags & 0x01:
//       [desired_id: u32 LE]      -- specific service ID to assign (registrar only for < S)
//     if flags & 0x02:
//       [gratis_offset: u64 LE]   -- free storage deposit offset (manager only)
//
//   0x02 Transfer:
//     [dest_service_id: u32 LE]
//     [amount: u64 LE]
//     [gas_limit: u64 LE]
//     [memo: 128 bytes]
//
//   0x03 Upgrade (self):
//     [code_hash: 32 bytes]       -- new code hash
//     [min_acc_gas: u64 LE]
//     [min_memo_gas: u64 LE]
//
//   0x04 Store (write to own storage):
//     [key_len: u16 LE]
//     [key: key_len bytes]
//     [val_len: u32 LE]
//     [value: val_len bytes]
//
// Refine: passes payload through as output (unchanged).
// Accumulate: decodes instructions from refine output, executes them.
//
// Storage keys written by the service:
//   "last_created"  -> u32 LE (most recently created service ID)
//   "created_count" -> u32 LE (total services created)

module bootstrap;

import jam::types;
import jam::service;
import jam::storage;
import jam::host;
import jam::log;

// ============================================================================
// Opcodes
// ============================================================================

const char OP_CREATE_SERVICE  = 0x01;
const char OP_TRANSFER        = 0x02;
const char OP_UPGRADE         = 0x03;
const char OP_STORE           = 0x04;

// ============================================================================
// Refine: pass-through
// ============================================================================

fn void refine(types::RefineArgs* args) @export("refine")
{
    log::info("boot", "Bootstrap refine");
    service::return_to_host(args.work_payload, (usz)args.work_payload_len);
}

// ============================================================================
// Accumulate: decode and dispatch instructions
// ============================================================================

fn void accumulate(types::AccumulateArgs* args) @export("accumulate")
{
    log::info("boot", "Bootstrap accumulate");

    // Fetch the items blob (contains refine outputs from all work items)
    char[65536] buf;
    usz len = service::fetch_inputs(&buf, 65536) ?? 0;
    if (len == 0) {
        log::warn("boot", "No inputs");
        return;
    }

    // The items blob format:
    //   varint(item_count) || item_0 || item_1 || ...
    // Each work-item operand starts with discriminator 0x00:
    //   0x00 || package_hash(32) || exports_root(32) || authorizer_hash(32) ||
    //   payload_hash(32) || varint(acc_gas) || result_encoding
    // Result success: 0x00 || varint(data_len) || data[data_len]
    //
    // Transfer items have discriminator 0x01 (152 bytes).
    usz pos = 0;

    // Decode item count (varint)
    uint item_count = 0;
    usz vl = decode_varint(&buf, pos, len, &item_count);
    if (vl == 0) {
        log::warn("boot", "Bad count");
        return;
    }
    pos += vl;

    // Process each item
    for (uint idx = 0; idx < item_count; idx++) {
        if (pos >= len) break;
        char disc = buf[pos];
        pos++;

        if (disc == 0x01) {
            // Transfer item: 4+4+8+128+8 = 152 bytes
            pos += 152;
            continue;
        }
        if (disc != 0x00) {
            log::warn("boot", "Unknown disc");
            continue;
        }

        // Work-item operand: skip 4 hashes (128 bytes)
        pos += 128;

        // Skip accumulate_gas varint
        uint acc_gas;
        vl = decode_varint(&buf, pos, len, &acc_gas);
        if (vl == 0) break;
        pos += vl;

        // Read result status
        if (pos >= len) break;
        char result_status = buf[pos];
        pos++;

        if (result_status == 0x02) {
            // Panic result - skip
            log::warn("boot", "Panicked");
            continue;
        }
        if (result_status != 0x00) {
            log::warn("boot", "Bad result");
            continue;
        }

        // Success: varint(data_len) + data
        uint data_len;
        vl = decode_varint(&buf, pos, len, &data_len);
        if (vl == 0) break;
        pos += vl;

        if (pos + data_len > len) {
            log::warn("boot", "Truncated");
            break;
        }

        // Process instructions from the refine output
        dispatch_instructions(&buf[pos], data_len);
        pos += data_len;
    }
}

// ============================================================================
// Instruction dispatcher
// ============================================================================

fn void dispatch_instructions(char* data, usz data_len)
{
    usz pos = 0;

    while (pos < data_len) {
        if (pos >= data_len) return;
        char opcode = data[pos];
        pos++;

        switch (opcode) {
            case OP_CREATE_SERVICE:
                pos = do_create_service(data, pos, data_len);
            case OP_TRANSFER:
                pos = do_transfer(data, pos, data_len);
            case OP_UPGRADE:
                pos = do_upgrade(data, pos, data_len);
            case OP_STORE:
                pos = do_store(data, pos, data_len);
            default:
                log::warn("boot", "Unknown op");
                return;
        }

        if (pos == 0) return;  // error sentinel
    }
}

// ============================================================================
// 0x01 CreateService
// ============================================================================

fn usz do_create_service(char* data, usz pos, usz len)
{
    // [code_hash: 32][code_len: u32][min_acc_gas: u64][min_memo_gas: u64][endowment: u64][flags: u8]
    // Optional trailing fields based on flags bits.
    if (pos + 61 > len) return 0;

    types::Hash code_hash;
    mem_copy((char*)&code_hash, &data[pos], 32);
    pos += 32;

    uint code_len      = read_u32_le(data, pos); pos += 4;
    ulong min_acc_gas  = read_u64_le(data, pos); pos += 8;
    ulong min_memo_gas = read_u64_le(data, pos); pos += 8;
    ulong endowment    = read_u64_le(data, pos); pos += 8;
    uint flags         = (uint)(char)data[pos] & 0xFF; pos += 1;

    // Parse optional desired_id (default: >= S to trigger auto-assign)
    // Per GP eq 4543-4545: if caller is registrar and i < S, the ID is used literally.
    // To get auto-assigned hash-based ID, pass i >= S (65536).
    ulong desired_id = 65536; // S = 2^16 — triggers auto-assign by default
    if (flags & 0x01) {
        if (pos + 4 > len) return 0;
        desired_id = (ulong)read_u32_le(data, pos); pos += 4;
    }

    // Parse optional gratis_offset (default: 0 = no free storage)
    // Per GP: f != 0 requires caller to be manager service
    ulong gratis_offset = 0;
    if (flags & 0x02) {
        if (pos + 8 > len) return 0;
        gratis_offset = read_u64_le(data, pos); pos += 8;
    }

    log::info("boot", "Creating service");

    // Create the new service account via raw host call
    ulong ret = host::host_new(
        (char*)&code_hash,
        (ulong)code_len,
        min_acc_gas,
        min_memo_gas,
        gratis_offset,
        desired_id
    );
    if (ret >= types::HOST_NONE) {
        log::warn("boot", "new_service failed");
        return 0;
    }
    types::ServiceId new_id = (types::ServiceId)ret;

    log::info("boot", "Created svc");

    // Store the new service ID in our storage
    char[4] id_buf;
    write_u32_le(&id_buf, (uint)new_id);
    if (catch err = storage::kv_write("last_created", 12, &id_buf, 4)) {
        log::warn("boot", "kv_write last_created failed");
    }

    // Increment created count
    char[4] count_buf;
    uint count = 0;
    usz rd = storage::kv_read("created_count", 13, &count_buf, 0, 4) ?? 0;
    if (rd == 4) {
        count = read_u32_le(&count_buf, 0);
    }
    count++;
    write_u32_le(&count_buf, count);
    if (catch err = storage::kv_write("created_count", 13, &count_buf, 4)) {
        log::warn("boot", "kv_write count failed");
    }

    // Transfer endowment to the new service (if > 0)
    if (endowment > 0) {
        types::Memo memo;
        // Zero-init memo
        for (usz i = 0; i < 128; i++) {
            ((char*)&memo)[i] = 0;
        }
        // Write "bootstrap" into memo
        char[9] msg = {'b','o','o','t','s','t','r','a','p'};
        mem_copy((char*)&memo, &msg, 9);

        if (catch err = service::transfer(new_id, endowment, min_memo_gas, &memo)) {
            log::warn("boot", "transfer failed");
        } else {
            log::info("boot", "Funded svc");
        }
    }

    // Create a checkpoint so we don't lose progress on later failures
    service::checkpoint();

    return pos;
}

// ============================================================================
// 0x02 Transfer
// ============================================================================

fn usz do_transfer(char* data, usz pos, usz len)
{
    // [dest: u32][amount: u64][gas_limit: u64][memo: 128]
    if (pos + 148 > len) return 0;

    uint dest       = read_u32_le(data, pos); pos += 4;
    ulong amount    = read_u64_le(data, pos); pos += 8;
    ulong gas_limit = read_u64_le(data, pos); pos += 8;

    types::Memo memo;
    mem_copy((char*)&memo, &data[pos], 128);
    pos += 128;

    log::info("boot", "Transfer");
    if (catch err = service::transfer((types::ServiceId)dest, amount, gas_limit, &memo)) {
        log::warn("boot", "transfer failed");
        return 0;
    }

    return pos;
}

// ============================================================================
// 0x03 Upgrade
// ============================================================================

fn usz do_upgrade(char* data, usz pos, usz len)
{
    // [code_hash: 32][min_acc_gas: u64][min_memo_gas: u64]
    if (pos + 48 > len) return 0;

    types::Hash code_hash;
    mem_copy((char*)&code_hash, &data[pos], 32);
    pos += 32;

    ulong min_acc_gas  = read_u64_le(data, pos); pos += 8;
    ulong min_memo_gas = read_u64_le(data, pos); pos += 8;

    log::info("boot", "Upgrade");
    if (catch err = service::upgrade(&code_hash, min_acc_gas, min_memo_gas)) {
        log::warn("boot", "upgrade failed");
        return 0;
    }

    return pos;
}

// ============================================================================
// 0x04 Store
// ============================================================================

fn usz do_store(char* data, usz pos, usz len)
{
    // [key_len: u16][key: key_len][val_len: u32][value: val_len]
    if (pos + 6 > len) return 0;

    uint key_len = read_u16_le(data, pos); pos += 2;
    if (pos + key_len + 4 > len) return 0;

    char* key = &data[pos]; pos += key_len;

    uint val_len = read_u32_le(data, pos); pos += 4;
    if (pos + val_len > len) return 0;

    char* val = &data[pos]; pos += val_len;

    log::info("boot", "Store KV");
    if (catch err = storage::kv_write(key, key_len, val, val_len)) {
        log::warn("boot", "kv_write failed");
        return 0;
    }

    return pos;
}

// ============================================================================
// Utility functions
// ============================================================================

fn void mem_copy(char* dst, char* src, usz n)
{
    for (usz i = 0; i < n; i++) {
        dst[i] = src[i];
    }
}

fn ulong read_u64_le(char* data, usz pos)
{
    ulong v = 0;
    for (usz i = 0; i < 8; i++) {
        v |= ((ulong)((uint)(char)data[pos + i] & 0xFF)) << (i * 8);
    }
    return v;
}

fn uint read_u32_le(char* data, usz pos)
{
    uint v = 0;
    for (usz i = 0; i < 4; i++) {
        v |= ((uint)(char)data[pos + i] & 0xFF) << (i * 8);
    }
    return v;
}

fn uint read_u16_le(char* data, usz pos)
{
    return ((uint)(char)data[pos] & 0xFF) | (((uint)(char)data[pos + 1] & 0xFF) << 8);
}

fn void write_u32_le(char* buf, uint v)
{
    buf[0] = (char)(v & 0xFF);
    buf[1] = (char)((v >> 8) & 0xFF);
    buf[2] = (char)((v >> 16) & 0xFF);
    buf[3] = (char)((v >> 24) & 0xFF);
}

// Decode JAM varint (natural number encoding, Appendix C).
// Returns bytes consumed (0 on error), writes decoded value to *out.
fn usz decode_varint(char* buf, usz pos, usz len, uint* out)
{
    if (pos >= len) return 0;
    uint first = (uint)(char)buf[pos] & 0xFF;

    if (first < 128) {
        *out = first;
        return 1;
    }
    if (first < 192) {
        if (pos + 2 > len) return 0;
        uint lo = (uint)(char)buf[pos + 1] & 0xFF;
        *out = ((first & 0x3F) << 8) | lo;
        return 2;
    }
    if (first < 224) {
        if (pos + 3 > len) return 0;
        uint lo = (uint)(char)buf[pos + 1] & 0xFF;
        uint hi = (uint)(char)buf[pos + 2] & 0xFF;
        *out = ((first & 0x1F) << 16) | (hi << 8) | lo;
        return 3;
    }
    if (first < 240) {
        if (pos + 4 > len) return 0;
        *out = ((first & 0x0F) << 24)
             | (((uint)(char)buf[pos + 3] & 0xFF) << 16)
             | (((uint)(char)buf[pos + 2] & 0xFF) << 8)
             | ((uint)(char)buf[pos + 1] & 0xFF);
        return 4;
    }
    return 0;
}
