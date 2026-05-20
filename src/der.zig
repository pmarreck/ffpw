const std = @import("std");

pub const Error = error{
    InvalidDer,
    UnexpectedOid,
    MissingField,
};

/// Parse a DER length field starting at `idx`. Advances `idx` past the length.
pub fn derLen(bytes: []const u8, idx: *usize) Error!usize {
    if (idx.* >= bytes.len) return Error.InvalidDer;
    const first = bytes[idx.*];
    idx.* += 1;
    if (first < 0x80) return first;

    const nbytes: usize = first & 0x7f;
    if (nbytes == 0 or nbytes > 4) return Error.InvalidDer;
    if (idx.* + nbytes > bytes.len) return Error.InvalidDer;

    var len: usize = 0;
    for (bytes[idx.*..idx.* + nbytes]) |b| {
        len = (len << 8) | b;
    }
    idx.* += nbytes;
    return len;
}

/// Return the first child TLV of a SEQUENCE.
pub fn derFirstChild(seq_der: []const u8) Error![]const u8 {
    if (seq_der.len < 2 or seq_der[0] != 0x30) return Error.InvalidDer;
    var i: usize = 1;
    const seq_len = try derLen(seq_der, &i);
    if (i + seq_len > seq_der.len) return Error.InvalidDer;

    const child_start = i;
    if (child_start >= seq_der.len) return Error.InvalidDer;
    i += 1; // child tag
    const child_len = try derLen(seq_der, &i);
    const child_total = (i - child_start) + child_len;
    if (child_start + child_total > seq_der.len) return Error.InvalidDer;

    return seq_der[child_start..child_start + child_total];
}

/// Iterate over children of a SEQUENCE, calling `f` for each.
pub fn derForEachChild(
    seq_der: []const u8,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), idx: usize, child_der: []const u8) void,
) Error!void {
    if (seq_der.len < 2 or seq_der[0] != 0x30) return Error.InvalidDer;
    var i: usize = 1;
    const seq_len = try derLen(seq_der, &i);
    if (i + seq_len > seq_der.len) return Error.InvalidDer;
    const end = i + seq_len;

    var child_idx: usize = 0;
    while (i < end) : (child_idx += 1) {
        const start = i;
        if (i >= seq_der.len) return Error.InvalidDer;
        _ = seq_der[i];
        i += 1;
        const len = try derLen(seq_der, &i);
        const total = (i - start) + len;
        if (start + total > seq_der.len) return Error.InvalidDer;
        f(ctx, child_idx, seq_der[start..start + total]);
        i = start + total;
    }
}

/// Extract the value portion of a TLV.
pub fn derValue(tlv_der: []const u8) Error![]const u8 {
    if (tlv_der.len < 2) return Error.InvalidDer;
    var i: usize = 1;
    const len = try derLen(tlv_der, &i);
    if (i + len > tlv_der.len) return Error.InvalidDer;
    return tlv_der[i..i + len];
}

/// Skip a TLV and return bytes consumed.
fn skipTlv(data: []const u8, pos: usize) Error!usize {
    if (pos >= data.len) return Error.InvalidDer;
    var i = pos + 1; // skip tag
    const len = try derLen(data, &i);
    if (i + len > data.len) return Error.InvalidDer;
    return i + len;
}

/// Read a TLV starting at `pos`, return the value and advance past it.
fn readTlvValue(data: []const u8, pos: *usize, expected_tag: u8) Error![]const u8 {
    if (pos.* >= data.len) return Error.InvalidDer;
    if (data[pos.*] != expected_tag) return Error.InvalidDer;
    pos.* += 1;
    const len = try derLen(data, pos);
    if (pos.* + len > data.len) return Error.InvalidDer;
    const val = data[pos.*..pos.* + len];
    pos.* += len;
    return val;
}

/// Enter a SEQUENCE: validate the tag, read length, return the content range.
fn enterSequence(data: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* >= data.len or data[pos.*] != 0x30) return Error.InvalidDer;
    pos.* += 1;
    const len = try derLen(data, pos);
    if (pos.* + len > data.len) return Error.InvalidDer;
    const content = data[pos.*..pos.* + len];
    pos.* += len;
    return content;
}

// Well-known OIDs (DER-encoded, without tag+length prefix).
const oid_pbes2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d }; // 1.2.840.113549.1.5.13
const oid_pbkdf2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c }; // 1.2.840.113549.1.5.12
const oid_hmac_sha256 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 }; // 1.2.840.113549.2.9
const oid_aes256_cbc = &[_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a }; // 2.16.840.1.101.3.4.1.42

pub const Pbes2Params = struct {
    entry_salt: []const u8,
    iterations: u32,
    iv: []const u8,
    ciphertext: []const u8,
};

/// Parse a PBES2-encoded blob from key4.db (the a11 column).
/// Structure:
///   SEQUENCE {
///     SEQUENCE {                           -- AlgorithmIdentifier
///       OID 1.2.840.113549.1.5.13         -- PBES2
///       SEQUENCE {                         -- PBES2-params
///         SEQUENCE {                       -- keyDerivationFunc (PBKDF2)
///           OID 1.2.840.113549.1.5.12     -- PBKDF2
///           SEQUENCE {
///             OCTET STRING entrySalt
///             INTEGER iterations
///             SEQUENCE {                   -- PRF (hmacWithSHA256)
///               OID 1.2.840.113549.2.9
///             }
///           }
///         }
///         SEQUENCE {                       -- encryptionScheme (AES-256-CBC)
///           OID 2.16.840.1.101.3.4.1.42
///           OCTET STRING iv
///         }
///       }
///     }
///     OCTET STRING ciphertext
///   }
pub fn parsePbes2(data: []const u8) (Error || error{Overflow})!Pbes2Params {
    // We walk through the DER byte-by-byte.
    var pos: usize = 0;

    // Outer SEQUENCE
    if (pos >= data.len or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const outer_len = try derLen(data, &pos);
    if (pos + outer_len > data.len) return Error.InvalidDer;
    const outer_end = pos + outer_len;

    // Child 1: AlgorithmIdentifier SEQUENCE
    if (pos >= outer_end or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const algid_len = try derLen(data, &pos);
    if (pos + algid_len > outer_end) return Error.InvalidDer;
    const algid_end = pos + algid_len;

    // OID: must be PBES2
    const pbes2_oid = try readTlvValue(data, &pos, 0x06);
    if (!std.mem.eql(u8, pbes2_oid, oid_pbes2)) return Error.UnexpectedOid;

    // PBES2-params SEQUENCE
    if (pos >= algid_end or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const pbes2_params_len = try derLen(data, &pos);
    if (pos + pbes2_params_len > algid_end) return Error.InvalidDer;
    const pbes2_params_end = pos + pbes2_params_len;

    // keyDerivationFunc SEQUENCE (PBKDF2)
    if (pos >= pbes2_params_end or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const kdf_len = try derLen(data, &pos);
    if (pos + kdf_len > pbes2_params_end) return Error.InvalidDer;
    const kdf_end = pos + kdf_len;

    // OID: must be PBKDF2
    const pbkdf2_oid = try readTlvValue(data, &pos, 0x06);
    if (!std.mem.eql(u8, pbkdf2_oid, oid_pbkdf2)) return Error.UnexpectedOid;

    // PBKDF2-params SEQUENCE
    if (pos >= kdf_end or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const pbkdf2_params_len = try derLen(data, &pos);
    if (pos + pbkdf2_params_len > kdf_end) return Error.InvalidDer;
    const pbkdf2_params_end = pos + pbkdf2_params_len;

    // OCTET STRING entrySalt
    const entry_salt = try readTlvValue(data, &pos, 0x04);

    // INTEGER iterations
    const iter_bytes = try readTlvValue(data, &pos, 0x02);
    if (iter_bytes.len == 0 or iter_bytes.len > 4) return Error.InvalidDer;
    var iterations: u32 = 0;
    for (iter_bytes) |b| {
        iterations = try std.math.mul(u32, iterations, 256);
        iterations = try std.math.add(u32, iterations, b);
    }

    // Optional: PRF AlgorithmIdentifier SEQUENCE (hmacWithSHA256)
    // Some blobs may omit this if it's the default. If present, validate it.
    if (pos < pbkdf2_params_end and data[pos] == 0x30) {
        pos += 1;
        const prf_len = try derLen(data, &pos);
        if (pos + prf_len > pbkdf2_params_end) return Error.InvalidDer;

        const prf_oid = try readTlvValue(data, &pos, 0x06);
        if (!std.mem.eql(u8, prf_oid, oid_hmac_sha256)) return Error.UnexpectedOid;

        // Skip any remaining PRF parameters (e.g. NULL)
        pos = pos + (prf_len - (prf_oid.len + 2)); // approximate; let's just jump to end
    }
    pos = pbkdf2_params_end;
    pos = kdf_end;

    // encryptionScheme SEQUENCE (AES-256-CBC)
    if (pos >= pbes2_params_end or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const enc_len = try derLen(data, &pos);
    if (pos + enc_len > pbes2_params_end) return Error.InvalidDer;
    const enc_end = pos + enc_len;

    const aes_oid = try readTlvValue(data, &pos, 0x06);
    if (!std.mem.eql(u8, aes_oid, oid_aes256_cbc)) return Error.UnexpectedOid;

    // IV: Firefox key4.db stores the IV as an OCTET STRING with only 14 bytes
    // of value. NSS uses the full DER TLV (tag 04 + length 0E + 14 value bytes
    // = 16 bytes total) as the AES-256-CBC IV. Handle both this encoding and
    // the standard 16-byte-value encoding.
    const iv_tlv_start = pos;
    const iv_raw = try readTlvValue(data, &pos, 0x04);
    const iv_full_tlv = data[iv_tlv_start..pos];
    const iv = if (iv_raw.len == 16)
        // Standard: 16-byte OCTET STRING value is the IV directly.
        iv_raw
    else if (iv_full_tlv.len == 16)
        // Firefox quirk: full TLV (04 0E + 14 bytes) is used as the 16-byte IV.
        iv_full_tlv
    else if (iv_raw.len > 16 and iv_raw[0] == 0x04) blk: {
        // Nested OCTET STRING: strip inner TLV header.
        var inner_pos: usize = 0;
        break :blk try readTlvValue(iv_raw, &inner_pos, 0x04);
    } else iv_raw;

    pos = enc_end;
    pos = pbes2_params_end;
    pos = algid_end;

    // Child 2: OCTET STRING ciphertext
    const ciphertext = try readTlvValue(data, &pos, 0x04);

    return Pbes2Params{
        .entry_salt = entry_salt,
        .iterations = iterations,
        .iv = iv,
        .ciphertext = ciphertext,
    };
}

pub const LoginEnvelope = struct {
    key_id: []const u8,
    iv: []const u8,
    ciphertext: []const u8,
};

/// Parse a base64-decoded login field ASN.1 envelope.
/// Structure:
///   SEQUENCE {
///     OCTET STRING keyId
///     SEQUENCE {                -- AlgorithmIdentifier
///       OID                    -- encryption algorithm
///       OCTET STRING iv
///     }
///     OCTET STRING ciphertext
///   }
pub fn parseLoginEnvelope(data: []const u8) Error!LoginEnvelope {
    var pos: usize = 0;

    // Outer SEQUENCE
    if (pos >= data.len or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const outer_len = try derLen(data, &pos);
    if (pos + outer_len > data.len) return Error.InvalidDer;

    // OCTET STRING keyId
    const key_id = try readTlvValue(data, &pos, 0x04);

    // AlgorithmIdentifier SEQUENCE
    if (pos >= data.len or data[pos] != 0x30) return Error.InvalidDer;
    pos += 1;
    const algid_len = try derLen(data, &pos);
    if (pos + algid_len > data.len) return Error.InvalidDer;
    const algid_end = pos + algid_len;

    // OID (we don't strictly validate which algorithm — the master key will be used)
    _ = try readTlvValue(data, &pos, 0x06);

    // IV: OCTET STRING
    const iv = try readTlvValue(data, &pos, 0x04);

    pos = algid_end;

    // OCTET STRING ciphertext
    const ciphertext = try readTlvValue(data, &pos, 0x04);

    return LoginEnvelope{
        .key_id = key_id,
        .iv = iv,
        .ciphertext = ciphertext,
    };
}

pub fn debugPrintHex(bytes: []const u8) void {
    for (bytes) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "derLen short form" {
    const data = [_]u8{0x05};
    var idx: usize = 0;
    try testing.expectEqual(@as(usize, 5), try derLen(&data, &idx));
    try testing.expectEqual(@as(usize, 1), idx);
}

test "derLen long form 1 byte" {
    const data = [_]u8{ 0x81, 0x80 };
    var idx: usize = 0;
    try testing.expectEqual(@as(usize, 128), try derLen(&data, &idx));
    try testing.expectEqual(@as(usize, 2), idx);
}

test "derLen long form 2 bytes" {
    const data = [_]u8{ 0x82, 0x01, 0x00 };
    var idx: usize = 0;
    try testing.expectEqual(@as(usize, 256), try derLen(&data, &idx));
    try testing.expectEqual(@as(usize, 3), idx);
}

test "derValue extracts value" {
    // Tag=0x04, Length=3, Value="abc"
    const data = [_]u8{ 0x04, 0x03, 'a', 'b', 'c' };
    const val = try derValue(&data);
    try testing.expectEqualStrings("abc", val);
}

test "derFirstChild returns first child of SEQUENCE" {
    // SEQUENCE { OCTET_STRING "hi", INTEGER 42 }
    const data = [_]u8{
        0x30, 0x07, // SEQUENCE, length 7
        0x04, 0x02, 'h', 'i', // OCTET STRING "hi"
        0x02, 0x01, 0x2a, // INTEGER 42
    };
    const child = try derFirstChild(&data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x02, 'h', 'i' }, child);
}

test "parsePbes2 crafted blob" {
    // Build a minimal PBES2 ASN.1 blob.
    const blob = buildTestPbes2Blob();
    const params = try parsePbes2(&blob);

    try testing.expectEqualSlices(u8, "saltsaltsaltsalt", params.entry_salt);
    try testing.expectEqual(@as(u32, 10000), params.iterations);
    // Firefox quirk: the full TLV (04 0E + 14 bytes) is returned as the 16-byte IV.
    try testing.expectEqual(@as(usize, 16), params.iv.len);
    try testing.expectEqual(@as(u8, 0x04), params.iv[0]);
    try testing.expectEqual(@as(u8, 0x0e), params.iv[1]);
    try testing.expectEqualSlices(u8, "iv_test_data__", params.iv[2..16]);
    try testing.expectEqualSlices(u8, "ciphertext______", params.ciphertext);
}

test "parseLoginEnvelope crafted blob" {
    // SEQUENCE {
    //   OCTET STRING keyId (16 bytes)
    //   SEQUENCE { OID (DES-EDE3-CBC = 1.2.840.113549.3.7), OCTET STRING iv (8 bytes) }
    //   OCTET STRING ciphertext (16 bytes)
    // }
    const blob = [_]u8{
        0x30, 0x31, //   SEQUENCE, length 49
        0x04, 0x10, //   OCTET STRING, length 16
        'k', 'e', 'y', '_', 'i', 'd', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_',
        0x30, 0x0f, //   SEQUENCE, length 15
        0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x07, //   OID 1.3.14.3.2.7 (des-cbc, placeholder)
        0x04, 0x06, 'i', 'v', 'i', 'v', 'i', 'v', //   OCTET STRING iv (6 bytes)
        0x04, 0x10, //   OCTET STRING, length 16
        'c', 'i', 'p', 'h', 'e', 'r', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_',
    };
    const env = try parseLoginEnvelope(&blob);
    try testing.expectEqualStrings("key_id__________", env.key_id);
    try testing.expectEqualStrings("iviviv", env.iv);
    try testing.expectEqualStrings("cipher__________", env.ciphertext);
}

/// Build a test PBES2 blob for testing.
fn buildTestPbes2Blob() [115]u8 {
    // This is a carefully crafted ASN.1 PBES2 blob.
    // Structure follows the parsePbes2 docstring exactly.
    //
    // Total emitted bytes:
    //   2 (outer hdr) + 2 (AlgID hdr) + 11 (PBES2 OID) +
    //   2 (PBES2-params hdr) + 49 (KDF SEQUENCE) +
    //   31 (encScheme SEQUENCE) + 18 (ciphertext) = 115
    //
    // Earlier revisions advertised 117 in the outer header but only
    // wrote 115 bytes, leaving two undefined bytes at the tail and
    // tripping `std.debug.assert(i == 117)` on every runtime that
    // actually executed the test (the prior CI only spawned the test
    // binary via Zig's `--listen=-` IPC, which suppressed the panic).
    var buf: [115]u8 = undefined;
    var i: usize = 0;

    // Outer SEQUENCE — payload = 113 bytes
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x71; // length 113 (= total 115 - 2-byte outer header)
    i += 1;

    // AlgorithmIdentifier SEQUENCE — payload = 93 bytes
    // (OID PBES2: 11) + (PBES2-params hdr: 2 + payload 80) = 93
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x5d; // length 93
    i += 1;

    // OID PBES2
    buf[i] = 0x06;
    i += 1;
    buf[i] = 0x09;
    i += 1;
    @memcpy(buf[i..i + 9], oid_pbes2);
    i += 9;

    // PBES2-params SEQUENCE — payload = 80 bytes
    // (KDF hdr: 2 + payload 47) + (encScheme hdr: 2 + payload 29) = 80
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x50; // length 80
    i += 1;

    // keyDerivationFunc SEQUENCE (PBKDF2)
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x2f; // length 47
    i += 1;

    // OID PBKDF2
    buf[i] = 0x06;
    i += 1;
    buf[i] = 0x09;
    i += 1;
    @memcpy(buf[i..i + 9], oid_pbkdf2);
    i += 9;

    // PBKDF2-params SEQUENCE
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x22; // length 34
    i += 1;

    // OCTET STRING entrySalt (16 bytes)
    buf[i] = 0x04;
    i += 1;
    buf[i] = 0x10;
    i += 1;
    @memcpy(buf[i..i + 16], "saltsaltsaltsalt");
    i += 16;

    // INTEGER iterations (10000 = 0x2710)
    buf[i] = 0x02;
    i += 1;
    buf[i] = 0x02;
    i += 1;
    buf[i] = 0x27;
    i += 1;
    buf[i] = 0x10;
    i += 1;

    // PRF SEQUENCE (hmacWithSHA256)
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x0a;
    i += 1;

    // OID hmacWithSHA256
    buf[i] = 0x06;
    i += 1;
    buf[i] = 0x08;
    i += 1;
    @memcpy(buf[i..i + 8], oid_hmac_sha256);
    i += 8;

    // end PBKDF2-params, end keyDerivationFunc

    // encryptionScheme SEQUENCE (AES-256-CBC)
    buf[i] = 0x30;
    i += 1;
    buf[i] = 0x1d; // length 29
    i += 1;

    // OID AES-256-CBC
    buf[i] = 0x06;
    i += 1;
    buf[i] = 0x09;
    i += 1;
    @memcpy(buf[i..i + 9], oid_aes256_cbc);
    i += 9;

    // IV as nested OCTET STRING: outer 04 10, inner 04 0e + 14 bytes
    buf[i] = 0x04;
    i += 1;
    buf[i] = 0x10; // 16 bytes total
    i += 1;
    buf[i] = 0x04;
    i += 1; // inner tag
    buf[i] = 0x0e;
    i += 1; // inner length = 14
    @memcpy(buf[i..i + 14], "iv_test_data__");
    i += 14;

    // end encryptionScheme, end PBES2-params, end AlgorithmIdentifier

    // OCTET STRING ciphertext (16 bytes)
    buf[i] = 0x04;
    i += 1;
    buf[i] = 0x10;
    i += 1;
    @memcpy(buf[i..i + 16], "ciphertext______");
    i += 16;

    std.debug.assert(i == 115);
    return buf;
}
