//! Converts PolkaVM blob format to the JAM PVM blob format.
//!
//! The key difference is that PolkaVM format stores RO/RW data without zero-padding,
//! while JAM format requires padding to the declared sizes.
//!
//! Patched version: handles missing RO_DATA/RW_DATA sections when their sizes are 0,
//! which polkatool 0.29+ omits. Also skips unknown trailing sections gracefully.

use std::env;
use std::fs;
use std::process;

const MAGIC: &[u8] = b"PVM\0";
const VERSION: u8 = 0;

const SECTION_MEM_CFG: u8 = 1;
const SECTION_RO_DATA: u8 = 2;
const SECTION_RW_DATA: u8 = 3;
const SECTION_IMPORTS: u8 = 4;
const SECTION_EXPORTS: u8 = 5;
const SECTION_CODE_AND_JUMP_TABLE: u8 = 6;

fn main() {
    let args: Vec<String> = env::args().collect();

    let (input_path, output_path) = match args.len() {
        2 => (&args[1], args[1].clone()),
        4 if args[2] == "-o" => (&args[1], args[3].clone()),
        _ => {
            eprintln!("Usage: {} <input.pvm> [-o <output.pvm>]", args[0]);
            eprintln!("Converts PolkaVM blob format to JAM format.");
            eprintln!("If -o is not specified, converts in-place.");
            process::exit(1);
        }
    };

    let data = fs::read(input_path).unwrap_or_else(|e| {
        eprintln!("Failed to read file: {}", e);
        process::exit(1);
    });

    let result = convert(&data).unwrap_or_else(|e| {
        eprintln!("Conversion failed: {}", e);
        process::exit(1);
    });

    fs::write(&output_path, &result).unwrap_or_else(|e| {
        eprintln!("Failed to write file: {}", e);
        process::exit(1);
    });
}

fn convert(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut cursor = data;

    // Check magic
    if cursor.len() < 4 || &cursor[..4] != MAGIC {
        return Err("Invalid magic bytes".into());
    }
    cursor = &cursor[4..];

    // Check version
    if cursor.is_empty() || cursor[0] != VERSION {
        return Err("Invalid version".into());
    }
    cursor = &cursor[1..];

    // Read data length (u64 LE)
    if cursor.len() < 8 {
        return Err("Missing data length".into());
    }
    let data_len = u64::from_le_bytes(cursor[..8].try_into().unwrap()) as usize;
    cursor = &cursor[8..];

    if data_len != data.len() {
        return Err(format!(
            "Data length mismatch: header says {} but file is {} bytes",
            data_len,
            data.len()
        ));
    }

    // Parse memory config section (required, must be first)
    let (ro_data_size, rw_data_size, stack_size, rest) = decode_memory_section(cursor)?;
    cursor = rest;

    // Parse RO data section (optional — polkatool may omit when ro_data_size == 0)
    let ro_data: &[u8];
    if !cursor.is_empty() && cursor[0] == SECTION_RO_DATA {
        let (data_slice, rest) = decode_generic_section(SECTION_RO_DATA, cursor)?;
        ro_data = data_slice;
        cursor = rest;
    } else {
        ro_data = &[];
    }

    // Parse RW data section (optional — polkatool may omit when rw_data_size == 0)
    let rw_data: &[u8];
    if !cursor.is_empty() && cursor[0] == SECTION_RW_DATA {
        let (data_slice, rest) = decode_generic_section(SECTION_RW_DATA, cursor)?;
        rw_data = data_slice;
        cursor = rest;
    } else {
        rw_data = &[];
    }

    // Skip imports section (4) if present
    if !cursor.is_empty() && cursor[0] == SECTION_IMPORTS {
        let (_, rest) = decode_skip_section(cursor)?;
        cursor = rest;
    }

    // Skip exports section (5) if present
    if !cursor.is_empty() && cursor[0] == SECTION_EXPORTS {
        let (_, rest) = decode_skip_section(cursor)?;
        cursor = rest;
    }

    // Parse code and jump table section (required)
    if cursor.is_empty() || cursor[0] != SECTION_CODE_AND_JUMP_TABLE {
        return Err(format!(
            "Expected code section (type {}), got type {} at remaining offset",
            SECTION_CODE_AND_JUMP_TABLE,
            if cursor.is_empty() {
                "EOF".to_string()
            } else {
                format!("{}", cursor[0])
            }
        ));
    }
    let (program, _rest) = decode_generic_section(SECTION_CODE_AND_JUMP_TABLE, cursor)?;
    // Remaining bytes are polkatool debug sections (128, 129, 130, etc.) — ignored.

    // Validate sizes
    if ro_data.len() > ro_data_size {
        return Err(format!(
            "RO data larger than declared size: {} > {}",
            ro_data.len(),
            ro_data_size
        ));
    }
    if rw_data.len() > rw_data_size {
        return Err(format!(
            "RW data larger than declared size: {} > {}",
            rw_data.len(),
            rw_data_size
        ));
    }

    // Build JAM format output
    let mut output = Vec::new();

    // Metadata prefix: varU32(0) = empty metadata (required by JAM service blob format)
    output.push(0x00);

    // SPI header: ro_data_size (u24), rw_data_size (u24), zero_pages (u16), stack_size (u24)
    output.extend_from_slice(&(ro_data_size as u32).to_le_bytes()[..3]); // u24
    output.extend_from_slice(&(rw_data_size as u32).to_le_bytes()[..3]); // u24
    output.extend_from_slice(&0u16.to_le_bytes()); // zero_pages = 0
    output.extend_from_slice(&(stack_size as u32).to_le_bytes()[..3]); // u24

    // RO data (padded to ro_data_size)
    output.extend_from_slice(ro_data);
    output.resize(output.len() + (ro_data_size - ro_data.len()), 0);

    // RW data (padded to rw_data_size)
    output.extend_from_slice(rw_data);
    output.resize(output.len() + (rw_data_size - rw_data.len()), 0);

    // Program length (u32) and program data
    output.extend_from_slice(&(program.len() as u32).to_le_bytes());
    output.extend_from_slice(program);

    Ok(output)
}

fn decode_memory_section(data: &[u8]) -> Result<(usize, usize, usize, &[u8]), String> {
    if data.is_empty() || data[0] != SECTION_MEM_CFG {
        return Err("Expected memory config section".into());
    }
    let cursor = &data[1..];

    // Section length (general integer)
    let (_section_len, rest) = decode_general_integer(cursor)?;
    let cursor = rest;

    // ro_data_size, rw_data_size, stack_size (all general integers)
    let (ro_data_size, rest) = decode_general_integer(cursor)?;
    let (rw_data_size, rest) = decode_general_integer(rest)?;
    let (stack_size, rest) = decode_general_integer(rest)?;

    Ok((
        ro_data_size as usize,
        rw_data_size as usize,
        stack_size as usize,
        rest,
    ))
}

fn decode_generic_section<'a>(
    expected_type: u8,
    data: &'a [u8],
) -> Result<(&'a [u8], &'a [u8]), String> {
    if data.is_empty() || data[0] != expected_type {
        return Err(format!(
            "Expected section type {}, got {}",
            expected_type,
            if data.is_empty() {
                "EOF".to_string()
            } else {
                format!("{}", data[0])
            }
        ));
    }
    let cursor = &data[1..];

    // Section length (general integer)
    let (len, rest) = decode_general_integer(cursor)?;
    let len = len as usize;

    if rest.len() < len {
        return Err(format!(
            "Section {} data truncated: need {} bytes but only {} remain",
            expected_type,
            len,
            rest.len()
        ));
    }

    Ok((&rest[..len], &rest[len..]))
}

/// Skip over a section, returning `((), rest)`.
fn decode_skip_section(data: &[u8]) -> Result<((), &[u8]), String> {
    if data.is_empty() {
        return Err("Unexpected EOF when expecting section".into());
    }
    let section_type = data[0];
    let cursor = &data[1..];

    let (len, rest) = decode_general_integer(cursor)?;
    let len = len as usize;

    if rest.len() < len {
        return Err(format!(
            "Section {} truncated: need {} bytes but only {} remain",
            section_type,
            len,
            rest.len()
        ));
    }

    Ok(((), &rest[len..]))
}

/// Decode a "general integer" as per GP definition 275.
fn decode_general_integer(data: &[u8]) -> Result<(u64, &[u8]), String> {
    if data.is_empty() {
        return Err("Missing general integer".into());
    }

    let prefix = data[0];
    let rest = &data[1..];

    if prefix == 0 {
        return Ok((0, rest));
    }

    if prefix < 128 {
        return Ok((prefix as u64, rest));
    }

    if prefix == 0xFF {
        if rest.len() < 8 {
            return Err("Truncated general integer (0xFF prefix needs 8 bytes)".into());
        }
        let value = u64::from_le_bytes(rest[..8].try_into().unwrap());
        return Ok((value, &rest[8..]));
    }

    let (l, m) = match prefix {
        128..=191 => (1, 128),
        192..=223 => (2, 192),
        224..=239 => (3, 224),
        240..=247 => (4, 240),
        248..=251 => (5, 248),
        252..=253 => (6, 252),
        254 => (7, 254),
        _ => return Err(format!("Invalid general integer prefix: {}", prefix)),
    };

    if rest.len() < l {
        return Err(format!(
            "Truncated general integer: need {} bytes but only {} remain",
            l,
            rest.len()
        ));
    }

    let m_val = (prefix - m) as u64;
    let mut v: u64 = 0;
    for i in 0..l {
        v |= (rest[i] as u64) << (8 * i);
    }
    v += m_val << (8 * l);

    Ok((v, &rest[l..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_general_integer() {
        assert_eq!(decode_general_integer(&[0]).unwrap(), (0, &[][..]));
        assert_eq!(decode_general_integer(&[1]).unwrap(), (1, &[][..]));
        assert_eq!(decode_general_integer(&[127]).unwrap(), (127, &[][..]));
        assert_eq!(
            decode_general_integer(&[0x80, 140]).unwrap(),
            (140, &[][..])
        );
        assert_eq!(
            decode_general_integer(&[0xFF, 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12])
                .unwrap(),
            (0x123456789ABCDEF0, &[][..])
        );
    }
}
