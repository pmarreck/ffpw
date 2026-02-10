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
        const check_key = crypto.deriveKey(global_salt, master_password, check_params.entry_salt, check_params.iterations);

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
        const mk_key = crypto.deriveKey(global_salt, master_password, key_params.entry_salt, key_params.iterations);

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
