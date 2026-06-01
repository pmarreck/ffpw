const std = @import("std");
const crypto = @import("crypto.zig");
const der = @import("der.zig");

/// Decrypt a base64-encoded login field using the master key from key4.db.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn decryptLoginField(allocator: std.mem.Allocator, encoded: []const u8, master_key: [crypto.key_len]u8) ![]u8 {
    // Base64 decode.
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);

    // Parse ASN.1 envelope: { keyId, { OID, IV }, ciphertext }.
    const envelope = try der.parseLoginEnvelope(decoded);

    if (envelope.iv.len != crypto.block_len) return error.InvalidIvLength;
    const iv: [crypto.block_len]u8 = envelope.iv[0..crypto.block_len].*;

    // Decrypt ciphertext with AES-256-CBC.
    var buf: [4096]u8 = undefined;
    const ct_len = envelope.ciphertext.len;
    if (ct_len == 0 or ct_len > buf.len) return error.CiphertextTooLarge;
    @memcpy(buf[0..ct_len], envelope.ciphertext);

    const pt_len = try crypto.aes256CbcDecrypt(buf[0..ct_len], iv, master_key);

    return allocator.dupe(u8, buf[0..pt_len]);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn appendBytes(buf: []u8, i: *usize, src: []const u8) void {
    @memcpy(buf[i.*..][0..src.len], src);
    i.* += src.len;
}

// Build a base64-encoded login envelope around `ciphertext`, returning the
// encoded length written into `out`.
fn buildEncodedEnvelope(out: []u8, iv: [crypto.block_len]u8, ciphertext: []const u8) []const u8 {
    var der_buf: [256]u8 = undefined;
    var n: usize = 0;
    // keyId OCTET STRING (4 bytes)
    appendBytes(&der_buf, &n, &[_]u8{ 0x04, 0x04, 'k', 'i', 'd', '0' });
    // AlgorithmIdentifier SEQUENCE { OID, OCTET STRING iv(16) } — body = 7 + 18 = 25 (0x19)
    appendBytes(&der_buf, &n, &[_]u8{ 0x30, 0x19, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x07, 0x04, 0x10 });
    appendBytes(&der_buf, &n, &iv);
    // ciphertext OCTET STRING
    appendBytes(&der_buf, &n, &[_]u8{ 0x04, @intCast(ciphertext.len) });
    appendBytes(&der_buf, &n, ciphertext);

    var envelope: [256]u8 = undefined;
    envelope[0] = 0x30;
    envelope[1] = @intCast(n);
    @memcpy(envelope[2..][0..n], der_buf[0..n]);

    return std.base64.standard.Encoder.encode(out, envelope[0 .. n + 2]);
}

test "decryptLoginField round-trips a known AES-256-CBC login field" {
    const allocator = testing.allocator;
    const key: [crypto.key_len]u8 = [_]u8{0x11} ** crypto.key_len;
    const iv: [crypto.block_len]u8 = [_]u8{0x22} ** crypto.block_len;

    var ct_buf: [64]u8 = undefined;
    const ct_len = try crypto.aes256CbcEncrypt(&ct_buf, "hi", iv, key);
    try testing.expectEqual(@as(usize, crypto.block_len), ct_len);

    var enc_buf: [512]u8 = undefined;
    const encoded = buildEncodedEnvelope(&enc_buf, iv, ct_buf[0..ct_len]);

    const pt = try decryptLoginField(allocator, encoded, key);
    defer allocator.free(pt);
    try testing.expectEqualStrings("hi", pt);
}

test "decryptLoginField rejects invalid base64 without panicking" {
    const key: [crypto.key_len]u8 = [_]u8{0x11} ** crypto.key_len;
    try testing.expectError(error.InvalidCharacter, decryptLoginField(testing.allocator, "!!!not-base64!!!", key));
}

test "decryptLoginField with the wrong key fails cleanly (no panic)" {
    const allocator = testing.allocator;
    const key: [crypto.key_len]u8 = [_]u8{0x11} ** crypto.key_len;
    const wrong: [crypto.key_len]u8 = [_]u8{0x99} ** crypto.key_len;
    const iv: [crypto.block_len]u8 = [_]u8{0x22} ** crypto.block_len;

    var ct_buf: [64]u8 = undefined;
    const ct_len = try crypto.aes256CbcEncrypt(&ct_buf, "secret", iv, key);

    var enc_buf: [512]u8 = undefined;
    const encoded = buildEncodedEnvelope(&enc_buf, iv, ct_buf[0..ct_len]);

    // Wrong key yields either a padding error or garbage plaintext — never a crash.
    if (decryptLoginField(allocator, encoded, wrong)) |pt| {
        defer allocator.free(pt);
        try testing.expect(!std.mem.eql(u8, pt, "secret"));
    } else |_| {}
}
