const std = @import("std");
const sqlite = @import("sqlite");
const crypto = @import("crypto.zig");
const der = @import("der.zig");

pub const KeyStore = struct {
    master_key: [crypto.key_len]u8,

    /// Open key4.db and extract the master decryption key.
    /// `master_password` is typically "" (empty) for profiles without a master password.
    pub fn open(allocator: std.mem.Allocator, profile_path: []const u8, master_password: []const u8) !KeyStore {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const key4_path = try std.fs.path.join(a, &.{ profile_path, "key4.db" });
        const path_z = try a.dupeZ(u8, key4_path);

        var db = sqlite.Db.init(.{
            .mode = .{ .File = path_z },
        }) catch return error.Key4OpenFailed;
        defer db.deinit();

        // Step 1: Get global salt and password-check blob from metadata table.
        const MetaRow = struct { item1: []const u8, item2: []const u8 };
        const meta = (db.oneAlloc(MetaRow, a,
            "SELECT item1, item2 FROM metadata WHERE id = 'password'", .{}, .{})
            catch return error.MissingPasswordEntry) orelse return error.MissingPasswordEntry;

        const global_salt = meta.item1;

        // Step 2: Verify the master password.
        //   Decrypt the password-check blob and verify plaintext == "password-check".
        const check_params = der.parsePbes2(meta.item2) catch return error.InvalidPasswordBlob;
        const check_key = crypto.deriveKey(global_salt, master_password, check_params.entry_salt, check_params.iterations) catch return error.InvalidPasswordBlob;

        if (check_params.iv.len != crypto.block_len) return error.InvalidIvLength;
        const check_iv: [crypto.block_len]u8 = check_params.iv[0..crypto.block_len].*;

        var check_buf: [256]u8 = undefined;
        const ct_len = check_params.ciphertext.len;
        if (ct_len == 0 or ct_len > check_buf.len) return error.InvalidPasswordBlob;
        @memcpy(check_buf[0..ct_len], check_params.ciphertext);

        const check_pt_len = crypto.aes256CbcDecrypt(check_buf[0..ct_len], check_iv, check_key) catch
            return error.WrongMasterPassword;

        if (!std.mem.eql(u8, check_buf[0..check_pt_len], "password-check"))
            return error.WrongMasterPassword;

        // Step 3: Extract the master key from nssPrivate.
        //   key4.db may contain multiple key entries (legacy 3DES + AES-256).
        //   Try each in descending size order; AES-256 keys have larger blobs.
        var stmt = db.prepare("SELECT a11 FROM nssPrivate ORDER BY length(a11) DESC") catch
            return error.MissingPrivateKey;
        defer stmt.deinit();

        const PrivRow = struct { a11: []const u8 };
        var iter = stmt.iterator(PrivRow, .{}) catch return error.MissingPrivateKey;

        var found_any = false;
        while (iter.nextAlloc(a, .{}) catch null) |priv| {
            found_any = true;
            const master_key = extractMasterKey(global_salt, master_password, priv.a11) catch continue;
            return KeyStore{ .master_key = master_key };
        }

        return if (found_any) error.InvalidMasterKey else error.MissingPrivateKey;
    }

    fn extractMasterKey(
        global_salt: []const u8,
        master_password: []const u8,
        a11: []const u8,
    ) ![crypto.key_len]u8 {
        const key_params = try der.parsePbes2(a11);
        const mk_key = crypto.deriveKey(global_salt, master_password, key_params.entry_salt, key_params.iterations) catch return error.InvalidMasterKey;

        if (key_params.iv.len != crypto.block_len) return error.InvalidIvLength;
        const mk_iv: [crypto.block_len]u8 = key_params.iv[0..crypto.block_len].*;

        var mk_buf: [512]u8 = undefined;
        const mk_ct_len = key_params.ciphertext.len;
        if (mk_ct_len == 0 or mk_ct_len > mk_buf.len) return error.InvalidPrivateKeyBlob;
        @memcpy(mk_buf[0..mk_ct_len], key_params.ciphertext);

        const mk_pt_len = try crypto.aes256CbcDecrypt(mk_buf[0..mk_ct_len], mk_iv, mk_key);
        if (mk_pt_len < crypto.key_len) return error.InvalidMasterKey;

        return mk_buf[0..crypto.key_len].*;
    }
};


// ── Tests ──────────────────────────────────────────────────────────────
//
// Regression guard for a Zig 0.16 comptime mis-lowering in the vendored
// zig-sqlite high-level query API: query.zig `getQuery()` returned a slice into
// a by-value comptime struct field, which 0.16 mis-lowered to all-spaces, so
// every `prepare()` failed with EmptyQuery. This opens a temp in-memory DB and
// runs the exact `KeyStore.open` nssPrivate query, asserting it returns the real
// stored bytes — the load-bearing sqlite path CI was silently not exercising.

const testing = std.testing;

test "sqlite high-level prepare runs the nssPrivate query and returns real bytes" {
    const allocator = testing.allocator;

    // In-memory temp DB; the load-bearing path we exercise is `prepare`/`exec`'s
    // comptime query string, identical to the read-only file path KeyStore.open
    // uses. Write+create here only so the fixture table can be populated.
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try db.exec("CREATE TABLE nssPrivate (a11 BLOB)", .{}, .{});

    const known = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 };
    try db.exec("INSERT INTO nssPrivate (a11) VALUES (?)", .{}, .{sqlite.Blob{ .data = &known }});

    // The exact load-bearing query string from KeyStore.open (step 3).
    var stmt = try db.prepare("SELECT a11 FROM nssPrivate ORDER BY length(a11) DESC");
    defer stmt.deinit();

    const PrivRow = struct { a11: sqlite.Blob };
    var iter = try stmt.iterator(PrivRow, .{});
    const row = (try iter.nextAlloc(allocator, .{})) orelse return error.NoRowReturned;
    defer allocator.free(row.a11.data);

    try testing.expectEqualSlices(u8, &known, row.a11.data);
}

// ── End-to-end fixture: forge a synthetic key4.db and decrypt it ──────────
//
// The query-path test above proves `prepare` works; this proves the WHOLE
// product path (sqlite → DER → key derivation → AES-CBC → master key) against
// an EXTERNAL ORACLE: a master key we choose, encrypt into Firefox-format
// blobs, and must get back byte-for-byte. This is the test that would have
// caught the 2026-05 toolchain-drift regression end to end.
//
// OIDs mirror der.zig; if they drift, parsePbes2 rejects the blob and the test
// fails loudly — so the duplication is self-checking, not a hidden assumption.
const t_oid_pbes2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
const t_oid_pbkdf2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
const t_oid_hmac_sha256 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 };
const t_oid_aes256_cbc = &[_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };

const TlvWriter = struct {
    buf: []u8,
    len: usize = 0,
    fn tlv(self: *TlvWriter, tag: u8, value: []const u8) void {
        self.buf[self.len] = tag;
        self.len += 1;
        if (value.len < 128) {
            self.buf[self.len] = @intCast(value.len);
            self.len += 1;
        } else {
            self.buf[self.len] = 0x81; // long form, 1 length byte (value.len < 256)
            self.len += 1;
            self.buf[self.len] = @intCast(value.len);
            self.len += 1;
        }
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.len += value.len;
    }
    fn slice(self: *TlvWriter) []u8 {
        return self.buf[0..self.len];
    }
};

fn derInteger(buf: *[5]u8, v: u32) []u8 {
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, v, .big);
    var start: usize = 0;
    while (start < 3 and be[start] == 0) start += 1;
    var n: usize = 0;
    if (be[start] & 0x80 != 0) {
        buf[n] = 0x00; // leading zero so the INTEGER stays positive
        n += 1;
    }
    @memcpy(buf[n..][0 .. 4 - start], be[start..]);
    return buf[0 .. n + (4 - start)];
}

/// Build a Firefox-style PBES2 blob:
///   SEQUENCE { AlgId(PBES2{PBKDF2(salt,iter,hmacSHA256), AES256CBC(iv)}), OCTET STRING ct }
fn buildPbes2Blob(out: []u8, entry_salt: []const u8, iterations: u32, iv: []const u8, ciphertext: []const u8) []u8 {
    var prf_buf: [16]u8 = undefined;
    var prf = TlvWriter{ .buf = &prf_buf };
    prf.tlv(0x06, t_oid_hmac_sha256);

    var p2p_buf: [128]u8 = undefined;
    var p2p = TlvWriter{ .buf = &p2p_buf }; // PBKDF2-params
    p2p.tlv(0x04, entry_salt);
    var int_buf: [5]u8 = undefined;
    p2p.tlv(0x02, derInteger(&int_buf, iterations));
    p2p.tlv(0x30, prf.slice());

    var kdf_buf: [160]u8 = undefined;
    var kdf = TlvWriter{ .buf = &kdf_buf };
    kdf.tlv(0x06, t_oid_pbkdf2);
    kdf.tlv(0x30, p2p.slice());

    var enc_buf: [64]u8 = undefined;
    var enc = TlvWriter{ .buf = &enc_buf }; // encryptionScheme
    enc.tlv(0x06, t_oid_aes256_cbc);
    enc.tlv(0x04, iv);

    var params_buf: [256]u8 = undefined;
    var params = TlvWriter{ .buf = &params_buf }; // PBES2-params
    params.tlv(0x30, kdf.slice());
    params.tlv(0x30, enc.slice());

    var algid_buf: [288]u8 = undefined;
    var algid = TlvWriter{ .buf = &algid_buf };
    algid.tlv(0x06, t_oid_pbes2);
    algid.tlv(0x30, params.slice());

    var outer_buf: [320]u8 = undefined;
    var outer = TlvWriter{ .buf = &outer_buf };
    outer.tlv(0x30, algid.slice());
    outer.tlv(0x04, ciphertext);

    var w = TlvWriter{ .buf = out };
    w.tlv(0x30, outer.slice());
    return w.slice();
}

test "end-to-end: KeyStore.open decrypts a synthetic key4.db to the known master key" {
    const a = testing.allocator;
    const global_salt = "global-salt-20-bytes"; // 20 bytes
    const entry_salt_1 = "metadata-salt-16"; // 16
    const entry_salt_2 = "nssprivate-salt1"; // 16
    var iv1: [16]u8 = undefined;
    @memcpy(&iv1, "iv-metadata-1234"[0..16]);
    var iv2: [16]u8 = undefined;
    @memcpy(&iv2, "iv-nssprivate-12"[0..16]);
    var expected_master_key: [32]u8 = undefined;
    @memcpy(&expected_master_key, "MASTER-KEY-32-bytes-exactly-1234"[0..32]);

    // metadata.item2 = encrypt("password-check"); nssPrivate.a11 = encrypt(master key).
    const key1 = try crypto.deriveKey(global_salt, "", entry_salt_1, 1);
    var ct1: [64]u8 = undefined;
    const ct1_len = try crypto.aes256CbcEncrypt(&ct1, "password-check", iv1, key1);

    const key2 = try crypto.deriveKey(global_salt, "", entry_salt_2, 1);
    var ct2: [64]u8 = undefined;
    const ct2_len = try crypto.aes256CbcEncrypt(&ct2, &expected_master_key, iv2, key2);

    var blob1_buf: [256]u8 = undefined;
    const blob1 = buildPbes2Blob(&blob1_buf, entry_salt_1, 1, &iv1, ct1[0..ct1_len]);
    var blob2_buf: [320]u8 = undefined;
    const blob2 = buildPbes2Blob(&blob2_buf, entry_salt_2, 1, &iv2, ct2[0..ct2_len]);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // KeyStore.open hands the path to sqlite's C layer, so a cwd-relative path is
    // fine; tmpDir created `.zig-cache/tmp/<sub_path>` under the test's cwd.
    const dir_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer a.free(dir_path);
    const key4_path = try std.fs.path.join(a, &.{ dir_path, "key4.db" });
    defer a.free(key4_path);
    const key4_pathz = try a.dupeZ(u8, key4_path);
    defer a.free(key4_pathz);

    {
        var db = try sqlite.Db.init(.{
            .mode = .{ .File = key4_pathz },
            .open_flags = .{ .write = true, .create = true },
        });
        defer db.deinit();
        try db.exec("CREATE TABLE metadata (id TEXT, item1 BLOB, item2 BLOB)", .{}, .{});
        try db.exec("INSERT INTO metadata (id, item1, item2) VALUES ('password', ?, ?)", .{}, .{ sqlite.Blob{ .data = global_salt }, sqlite.Blob{ .data = blob1 } });
        try db.exec("CREATE TABLE nssPrivate (a11 BLOB)", .{}, .{});
        try db.exec("INSERT INTO nssPrivate (a11) VALUES (?)", .{}, .{sqlite.Blob{ .data = blob2 }});
    }

    // The real load-bearing path: open read-only and extract the master key.
    const ks = try KeyStore.open(a, dir_path, "");
    try testing.expectEqualSlices(u8, &expected_master_key, &ks.master_key);

    // Wrong password must be rejected, never silently mis-decrypt.
    try testing.expectError(error.WrongMasterPassword, KeyStore.open(a, dir_path, "wrong-password"));
}
