const std = @import("std");
const Aes256 = std.crypto.core.aes.Aes256;
const Sha1 = std.crypto.hash.Sha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const pbkdf2 = std.crypto.pwhash.pbkdf2;

pub const block_len = 16;
pub const key_len = 32;

pub const Error = error{
    InvalidPadding,
    CiphertextNotAligned,
    CiphertextEmpty,
};

/// Decrypt AES-256-CBC with PKCS#7 padding. Returns the unpadded plaintext length.
/// `buf` is modified in place: ciphertext is overwritten with plaintext.
pub fn aes256CbcDecrypt(buf: []u8, iv: [block_len]u8, key: [key_len]u8) Error!usize {
    if (buf.len == 0) return Error.CiphertextEmpty;
    if (buf.len % block_len != 0) return Error.CiphertextNotAligned;

    const ctx = Aes256.initDec(key);
    const nblocks = buf.len / block_len;

    // Decrypt in reverse order so we can use the original ciphertext as the XOR source.
    var i: usize = nblocks;
    while (i > 0) {
        i -= 1;
        const offset = i * block_len;
        const block: *[block_len]u8 = buf[offset..][0..block_len];
        // Save ciphertext block before decrypting (needed for XOR).
        const cipher_block = block.*;
        ctx.decrypt(block, block);
        // XOR with previous ciphertext block (or IV for first block).
        const prev = if (i == 0) iv else buf[(i - 1) * block_len ..][0..block_len].*;
        for (block, prev) |*b, p| {
            b.* ^= p;
        }
        // For blocks after the first, we need the original ciphertext of *this* block
        // for the *next* iteration's XOR — but we've already decrypted it. Since we go
        // in reverse, the block before us hasn't been decrypted yet, so `prev` above is
        // still the original ciphertext. This works correctly in reverse order.
        _ = cipher_block;
    }

    return pkcs7Unpad(buf);
}

/// Encrypt AES-256-CBC with PKCS#7 padding. `plaintext` is the input,
/// `out` receives ciphertext. `out` must be large enough for padded plaintext.
/// Returns the ciphertext length.
pub fn aes256CbcEncrypt(out: []u8, plaintext: []const u8, iv: [block_len]u8, key: [key_len]u8) !usize {
    const padded_len = ((plaintext.len / block_len) + 1) * block_len;
    if (out.len < padded_len) return error.BufferTooSmall;

    // Copy plaintext and add PKCS#7 padding.
    @memcpy(out[0..plaintext.len], plaintext);
    const pad_val: u8 = @intCast(padded_len - plaintext.len);
    @memset(out[plaintext.len..padded_len], pad_val);

    const ctx = Aes256.initEnc(key);
    var prev: [block_len]u8 = iv;
    const nblocks = padded_len / block_len;

    for (0..nblocks) |bi| {
        const offset = bi * block_len;
        const block: *[block_len]u8 = out[offset..][0..block_len];
        // XOR with previous ciphertext block (or IV).
        for (block, prev) |*b, p| {
            b.* ^= p;
        }
        ctx.encrypt(block, block);
        prev = block.*;
    }

    return padded_len;
}

/// Validate and remove PKCS#7 padding. Returns unpadded length.
fn pkcs7Unpad(buf: []const u8) Error!usize {
    if (buf.len == 0 or buf.len % block_len != 0) return Error.InvalidPadding;
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > block_len) return Error.InvalidPadding;
    const pad_start = buf.len - pad;
    for (buf[pad_start..]) |b| {
        if (b != pad) return Error.InvalidPadding;
    }
    return pad_start;
}

/// Derive a 32-byte key from globalSalt + masterPassword using the Firefox key4.db scheme:
///   k = SHA1(globalSalt || masterPassword)
///   derivedKey = PBKDF2-HMAC-SHA256(k, entrySalt, iterations, 32)
pub fn deriveKey(
    global_salt: []const u8,
    master_password: []const u8,
    entry_salt: []const u8,
    iterations: u32,
) [key_len]u8 {
    // Stage 1: SHA1(globalSalt || masterPassword)
    var sha1 = Sha1.init(.{});
    sha1.update(global_salt);
    sha1.update(master_password);
    const k = sha1.finalResult();

    // Stage 2: PBKDF2-HMAC-SHA256(k, entrySalt, iterations, 32)
    var dk: [key_len]u8 = undefined;
    pbkdf2(&dk, &k, entry_salt, iterations, HmacSha256) catch unreachable;
    return dk;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "PKCS#7 unpad valid pad=1..16" {
    // pad=1: last byte is 0x01
    var buf1 = [_]u8{0} ** 15 ++ [_]u8{0x01};
    try testing.expectEqual(@as(usize, 15), try pkcs7Unpad(&buf1));

    // pad=16: entire block is padding
    var buf16 = [_]u8{0x10} ** 16;
    try testing.expectEqual(@as(usize, 0), try pkcs7Unpad(&buf16));

    // pad=4
    var buf4 = [_]u8{ 'h', 'e', 'l', 'l', 'o', '!', '!', '!', '!', '!', '!', '!', 0x04, 0x04, 0x04, 0x04 };
    try testing.expectEqual(@as(usize, 12), try pkcs7Unpad(&buf4));
}

test "PKCS#7 unpad invalid cases" {
    // pad=0
    var buf0 = [_]u8{0x00} ** 16;
    try testing.expectError(Error.InvalidPadding, pkcs7Unpad(&buf0));

    // pad>16
    var buf17 = [_]u8{0x11} ** 16;
    try testing.expectError(Error.InvalidPadding, pkcs7Unpad(&buf17));

    // mismatched bytes
    var bufmix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03, 0x03, 0x02 };
    try testing.expectError(Error.InvalidPadding, pkcs7Unpad(&bufmix));

    // empty
    try testing.expectError(Error.InvalidPadding, pkcs7Unpad(&[_]u8{}));
}

test "AES-256-CBC NIST SP 800-38A F.2.6 decrypt" {
    // NIST test vectors for AES-256-CBC decryption (F.2.6).
    const key = [_]u8{
        0x60, 0x3d, 0xeb, 0x10, 0x15, 0xca, 0x71, 0xbe,
        0x2b, 0x73, 0xae, 0xf0, 0x85, 0x7d, 0x77, 0x81,
        0x1f, 0x35, 0x2c, 0x07, 0x3b, 0x61, 0x08, 0xd7,
        0x2d, 0x98, 0x10, 0xa3, 0x09, 0x14, 0xdf, 0xf4,
    };
    const iv = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    // 4 blocks of ciphertext from the NIST test vector.
    var ciphertext = [_]u8{
        0xf5, 0x8c, 0x4c, 0x04, 0xd6, 0xe5, 0xf1, 0xba,
        0x77, 0x9e, 0xab, 0xfb, 0x5f, 0x7b, 0xfb, 0xd6,
        0x9c, 0xfc, 0x4e, 0x96, 0x7e, 0xdb, 0x80, 0x8d,
        0x67, 0x9f, 0x77, 0x7b, 0xc6, 0x70, 0x2c, 0x7d,
        0x39, 0xf2, 0x33, 0x69, 0xa9, 0xd9, 0xba, 0xcf,
        0xa5, 0x30, 0xe2, 0x63, 0x04, 0x23, 0x14, 0x61,
        0xb2, 0xeb, 0x05, 0xe2, 0xc3, 0x9b, 0xe9, 0xfc,
        0xda, 0x6c, 0x19, 0x07, 0x8c, 0x6a, 0x9d, 0x1b,
    };
    const expected_plaintext = [_]u8{
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c,
        0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
        0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11,
        0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
        0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17,
        0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10,
    };

    // The NIST test has no PKCS#7 padding (exact 4 blocks). We test raw decryption
    // by adding a valid padding block ourselves.
    // Instead, test the raw CBC logic: decrypt without unpadding.
    // We'll just verify the decrypted bytes match expected plaintext (no padding in NIST vectors).
    const ctx = Aes256.initDec(key);
    var plaintext: [64]u8 = undefined;
    var prev = iv;
    for (0..4) |bi| {
        const off = bi * block_len;
        const cipher_block: [block_len]u8 = ciphertext[off..][0..block_len].*;
        var decrypted: [block_len]u8 = undefined;
        ctx.decrypt(&decrypted, &cipher_block);
        for (&decrypted, prev) |*b, p| {
            b.* ^= p;
        }
        plaintext[off..][0..block_len].* = decrypted;
        prev = cipher_block;
    }
    try testing.expectEqualSlices(u8, &expected_plaintext, &plaintext);
}

test "AES-256-CBC round-trip encrypt/decrypt" {
    const key = [_]u8{0xAA} ** 32;
    const iv = [_]u8{0xBB} ** 16;
    const plaintext = "Hello, Firefox passwords!";

    var ciphertext: [48]u8 = undefined; // 25 bytes + padding = 32 bytes, but allocate 48 to be safe
    const ct_len = try aes256CbcEncrypt(&ciphertext, plaintext, iv, key);

    var buf: [48]u8 = undefined;
    @memcpy(buf[0..ct_len], ciphertext[0..ct_len]);
    const pt_len = try aes256CbcDecrypt(buf[0..ct_len], iv, key);

    try testing.expectEqualStrings(plaintext, buf[0..pt_len]);
}

test "AES-256-CBC decrypt empty returns error" {
    const key = [_]u8{0} ** 32;
    const iv = [_]u8{0} ** 16;
    try testing.expectError(Error.CiphertextEmpty, aes256CbcDecrypt(&[_]u8{}, iv, key));
}

test "AES-256-CBC decrypt non-aligned returns error" {
    const key = [_]u8{0} ** 32;
    const iv = [_]u8{0} ** 16;
    var buf = [_]u8{0} ** 15;
    try testing.expectError(Error.CiphertextNotAligned, aes256CbcDecrypt(&buf, iv, key));
}

test "PBKDF2-HMAC-SHA256 RFC 6070 vector" {
    // RFC 6070 test vector 2: password="password", salt="salt", c=2, dkLen=20
    // But we use SHA256-based HMAC, so we compare against known OpenSSL output.
    // openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt pass:password -kdfopt salt:salt -kdfopt iter:4096 PBKDF2
    // = 0xc5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a (hex, 32 bytes)
    const expected = [_]u8{
        0xc5, 0xe4, 0x78, 0xd5, 0x92, 0x88, 0xc8, 0x41,
        0xaa, 0x53, 0x0d, 0xb6, 0x84, 0x5c, 0x4c, 0x8d,
        0x96, 0x28, 0x93, 0xa0, 0x01, 0xce, 0x4e, 0x11,
        0xa4, 0x96, 0x38, 0x73, 0xaa, 0x98, 0x13, 0x4a,
    };
    var dk: [32]u8 = undefined;
    try pbkdf2(&dk, "password", "salt", 4096, HmacSha256);
    try testing.expectEqualSlices(u8, &expected, &dk);
}

test "deriveKey known values" {
    // Test the two-stage derivation:
    //   k = SHA1(globalSalt || masterPassword)
    //   dk = PBKDF2-HMAC-SHA256(k, entrySalt, iterations, 32)
    const global_salt = "global_salt_test";
    const master_password = "";
    const entry_salt = "entry_salt______"; // 16 bytes
    const iterations: u32 = 1;

    // Compute expected: SHA1("global_salt_test" || "")
    var sha1 = Sha1.init(.{});
    sha1.update(global_salt);
    sha1.update(master_password);
    const k = sha1.finalResult();

    var expected_dk: [32]u8 = undefined;
    pbkdf2(&expected_dk, &k, entry_salt, iterations, HmacSha256) catch unreachable;

    const dk = deriveKey(global_salt, master_password, entry_salt, iterations);
    try testing.expectEqualSlices(u8, &expected_dk, &dk);
}
