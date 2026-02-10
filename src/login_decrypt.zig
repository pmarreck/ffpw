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
