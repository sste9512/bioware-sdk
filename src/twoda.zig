//! Bioware Aurora 2DA (Two-Dimensional Array) file format reader.
//!
//! Format overview:
//!   Line 1 – version header: "2DA V2.0"
//!   Line 2 – blank, or "DEFAULT: <value>"
//!   Line 3 – space-separated column names
//!   Lines 4+ – data rows; first token is the row index, remaining tokens are
//!              column values (one per column).  Values containing spaces must
//!              be wrapped in double-quotes.  The four-character sequence ****
//!              marks a blank / N/A entry.
const std = @import("std");

pub const BLANK_VALUE: []const u8 = "****";
pub const VERSION_HEADER: []const u8 = "2DA V2.0";

pub const ParseError = error{
    /// The data does not begin with the expected "2DA V2.0" header.
    InvalidVersion,
    /// The data is too short to contain all required header lines.
    InvalidFormat,
};

/// Outcome of a cell-read operation.
pub const ReadStatus = enum {
    /// A normal value was returned.
    ok,
    /// The cell contained **** (blank/N/A).  String returns ""; numeric returns 0.
    blank,
    /// The row was out of bounds and the file's DEFAULT value was substituted.
    default_value,
    /// The row or column was out of bounds and no DEFAULT is defined.
    out_of_bounds,
};

/// A parsed Bioware Aurora 2DA file.
///
/// Call `init`, then `parse` once per instance.  Clean up with `deinit`.
pub const TwoDA = struct {
    allocator: std.mem.Allocator,
    /// The optional DEFAULT value declared on line 2, owned.
    default: ?[]u8,
    /// Owned column name strings, in order.
    column_names: std.ArrayList([]u8),
    /// Owned row data.  rows.items[r][c] is the cell at row r, column c.
    rows: std.ArrayList([][]u8),

    pub fn init(allocator: std.mem.Allocator) TwoDA {
        return .{
            .allocator = allocator,
            .default = null,
            .column_names = .empty,
            .rows = .empty,
        };
    }

    pub fn deinit(self: *TwoDA) void {
        for (self.column_names.items) |col| self.allocator.free(col);
        self.column_names.deinit(self.allocator);

        for (self.rows.items) |row| {
            for (row) |cell| self.allocator.free(cell);
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);

        if (self.default) |d| self.allocator.free(d);
    }

    /// Parse `data` (the full contents of a .2da file) into this instance.
    /// Must only be called once on a freshly `init`-ed TwoDA.
    pub fn parse(self: *TwoDA, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');

        // Line 1 – version header
        const line1 = trimCR(lines.next() orelse return error.InvalidFormat);
        if (!std.mem.eql(u8, line1, VERSION_HEADER)) return error.InvalidVersion;

        // Line 2 – blank or DEFAULT
        const line2 = trimCR(lines.next() orelse return error.InvalidFormat);
        if (std.mem.startsWith(u8, line2, "DEFAULT:")) {
            const after = std.mem.trimStart(u8, line2["DEFAULT:".len..], " \t");
            self.default = try self.allocator.dupe(u8, firstToken(after));
        }

        // Line 3 – column names
        const line3 = trimCR(lines.next() orelse return error.InvalidFormat);
        var col_tok = Tokenizer.init(line3);
        while (col_tok.next()) |name| {
            try self.column_names.append(self.allocator, try self.allocator.dupe(u8, name));
        }
        const num_cols = self.column_names.items.len;

        // Lines 4+ – data rows
        while (lines.next()) |raw| {
            const line = trimCR(raw);
            if (line.len == 0) continue;

            var cells: std.ArrayList([]u8) = .empty;
            errdefer {
                for (cells.items) |c| self.allocator.free(c);
                cells.deinit(self.allocator);
            }

            var tok = Tokenizer.init(line);
            _ = tok.next(); // discard row index

            for (0..num_cols) |_| {
                const value = tok.next() orelse BLANK_VALUE;
                try cells.append(self.allocator, try self.allocator.dupe(u8, value));
            }

            const row = try cells.toOwnedSlice(self.allocator);
            errdefer {
                for (row) |c| self.allocator.free(c);
                self.allocator.free(row);
            }
            try self.rows.append(self.allocator, row);
        }
    }

    /// Number of named columns.
    pub fn columnCount(self: *const TwoDA) usize {
        return self.column_names.items.len;
    }

    /// Number of data rows.
    pub fn rowCount(self: *const TwoDA) usize {
        return self.rows.items.len;
    }

    /// Returns the zero-based index of the column named `name`, or null.
    pub fn columnIndex(self: *const TwoDA, name: []const u8) ?usize {
        for (self.column_names.items, 0..) |col, i| {
            if (std.mem.eql(u8, col, name)) return i;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // String accessors
    // -----------------------------------------------------------------------

    /// Read the string value at row `row`, column `col` (zero-based).
    /// `out` is set to the cell value, or "" on blank/out-of-bounds.
    pub fn getString(self: *const TwoDA, row: usize, col: usize, out: *[]const u8) ReadStatus {
        const cell = self.rawCell(row, col) orelse {
            if (self.default) |d| {
                out.* = d;
                return .default_value;
            }
            out.* = "";
            return .out_of_bounds;
        };
        if (std.mem.eql(u8, cell, BLANK_VALUE)) {
            out.* = "";
            return .blank;
        }
        out.* = cell;
        return .ok;
    }

    /// Same as `getString` but addresses the column by name.
    pub fn getStringByName(self: *const TwoDA, row: usize, col_name: []const u8, out: *[]const u8) ReadStatus {
        const col = self.columnIndex(col_name) orelse {
            out.* = "";
            return .out_of_bounds;
        };
        return self.getString(row, col, out);
    }

    // -----------------------------------------------------------------------
    // Integer accessors
    // -----------------------------------------------------------------------

    /// Read the integer value at row `row`, column `col`.
    /// Returns 0 for blank or out-of-bounds cells.
    pub fn getInt(self: *const TwoDA, row: usize, col: usize, out: *i32) ReadStatus {
        var s: []const u8 = undefined;
        const status = self.getString(row, col, &s);
        switch (status) {
            .blank, .out_of_bounds => {
                out.* = 0;
                return status;
            },
            .ok, .default_value => {
                out.* = std.fmt.parseInt(i32, s, 10) catch 0;
                return status;
            },
        }
    }

    /// Same as `getInt` but addresses the column by name.
    pub fn getIntByName(self: *const TwoDA, row: usize, col_name: []const u8, out: *i32) ReadStatus {
        const col = self.columnIndex(col_name) orelse {
            out.* = 0;
            return .out_of_bounds;
        };
        return self.getInt(row, col, out);
    }

    // -----------------------------------------------------------------------
    // Float accessors
    // -----------------------------------------------------------------------

    /// Read the 32-bit float value at row `row`, column `col`.
    /// Returns 0.0 for blank or out-of-bounds cells.
    pub fn getFloat(self: *const TwoDA, row: usize, col: usize, out: *f32) ReadStatus {
        var s: []const u8 = undefined;
        const status = self.getString(row, col, &s);
        switch (status) {
            .blank, .out_of_bounds => {
                out.* = 0.0;
                return status;
            },
            .ok, .default_value => {
                out.* = std.fmt.parseFloat(f32, s) catch 0.0;
                return status;
            },
        }
    }

    /// Same as `getFloat` but addresses the column by name.
    pub fn getFloatByName(self: *const TwoDA, row: usize, col_name: []const u8, out: *f32) ReadStatus {
        const col = self.columnIndex(col_name) orelse {
            out.* = 0.0;
            return .out_of_bounds;
        };
        return self.getFloat(row, col, out);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    fn rawCell(self: *const TwoDA, row: usize, col: usize) ?[]u8 {
        if (row >= self.rows.items.len) return null;
        const r = self.rows.items[row];
        if (col >= r.len) return null;
        return r[col];
    }
};

// ---------------------------------------------------------------------------
// File-level helpers
// ---------------------------------------------------------------------------

fn trimCR(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

fn firstToken(s: []const u8) []const u8 {
    var t = Tokenizer.init(s);
    return t.next() orelse "";
}

/// Splits a 2DA line into tokens, honouring double-quoted strings.
const Tokenizer = struct {
    buf: []const u8,
    pos: usize,

    fn init(buf: []const u8) Tokenizer {
        return .{ .buf = buf, .pos = 0 };
    }

    fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.buf.len and isWs(self.buf[self.pos])) self.pos += 1;
        if (self.pos >= self.buf.len) return null;

        if (self.buf[self.pos] == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.buf.len and self.buf[self.pos] != '"') self.pos += 1;
            const tok = self.buf[start..self.pos];
            if (self.pos < self.buf.len) self.pos += 1; // skip closing "
            return tok;
        }

        const start = self.pos;
        while (self.pos < self.buf.len and !isWs(self.buf[self.pos])) self.pos += 1;
        return self.buf[start..self.pos];
    }

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t';
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse minimal 2da" {
    const gpa = std.testing.allocator;

    const data =
        \\2DA V2.0
        \\
        \\label   value
        \\0       foo   42
        \\1       bar   7
    ;

    var tda = TwoDA.init(gpa);
    defer tda.deinit();

    try tda.parse(data);
    try std.testing.expectEqual(@as(usize, 2), tda.columnCount());
    try std.testing.expectEqual(@as(usize, 2), tda.rowCount());

    var s: []const u8 = undefined;
    try std.testing.expectEqual(ReadStatus.ok, tda.getStringByName(0, "label", &s));
    try std.testing.expectEqualStrings("foo", s);

    var n: i32 = undefined;
    try std.testing.expectEqual(ReadStatus.ok, tda.getIntByName(1, "value", &n));
    try std.testing.expectEqual(@as(i32, 7), n);
}

test "parse blank entry (****)" {
    const gpa = std.testing.allocator;

    const data =
        \\2DA V2.0
        \\
        \\name cost
        \\0    ****  10
        \\1    sword ****
    ;

    var tda = TwoDA.init(gpa);
    defer tda.deinit();

    try tda.parse(data);

    var s: []const u8 = undefined;
    try std.testing.expectEqual(ReadStatus.blank, tda.getStringByName(0, "name", &s));
    try std.testing.expectEqualStrings("", s);

    var n: i32 = undefined;
    try std.testing.expectEqual(ReadStatus.blank, tda.getIntByName(1, "cost", &n));
    try std.testing.expectEqual(@as(i32, 0), n);
}

test "parse DEFAULT line" {
    const gpa = std.testing.allocator;

    const data =
        \\2DA V2.0
        \\DEFAULT: none
        \\label value
        \\0     hello 1
    ;

    var tda = TwoDA.init(gpa);
    defer tda.deinit();

    try tda.parse(data);

    var s: []const u8 = undefined;
    try std.testing.expectEqual(ReadStatus.default_value, tda.getStringByName(99, "label", &s));
    try std.testing.expectEqualStrings("none", s);
}

test "parse quoted string" {
    const gpa = std.testing.allocator;

    const data =
        \\2DA V2.0
        \\
        \\description
        \\0            "hello world"
    ;

    var tda = TwoDA.init(gpa);
    defer tda.deinit();

    try tda.parse(data);

    var s: []const u8 = undefined;
    try std.testing.expectEqual(ReadStatus.ok, tda.getStringByName(0, "description", &s));
    try std.testing.expectEqualStrings("hello world", s);
}

test "invalid version returns error" {
    const gpa = std.testing.allocator;
    const data = "2DA V1.0\n\nfoo\n0 bar\n";
    var tda = TwoDA.init(gpa);
    defer tda.deinit();
    try std.testing.expectError(error.InvalidVersion, tda.parse(data));
}
