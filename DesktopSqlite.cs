using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeSwitcher {
    public sealed class SqlCell {
        public string Name { get; set; }
        public int Type { get; set; }
        public string Value { get; set; }
    }
    public sealed class SqlRow { public SqlCell[] Cells { get; set; } }
    public static class DesktopSqlite {
        private const string Native = "winsqlite3.dll";
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_open_v2(byte[] name, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_close(IntPtr db);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int size, out IntPtr statement, IntPtr tail);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_step(IntPtr statement);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_column_count(IntPtr statement);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_name(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_column_type(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_column_bytes(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern long sqlite3_column_int64(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern double sqlite3_column_double(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_bind_int64(IntPtr statement, int column, long value);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_bind_double(IntPtr statement, int column, double value);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_bind_null(IntPtr statement, int column);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_bind_text(IntPtr statement, int column, byte[] value, int size, IntPtr destructor);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_bind_blob(IntPtr statement, int column, byte[] value, int size, IntPtr destructor);
        [DllImport(Native, CallingConvention=CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        private static readonly IntPtr Transient = new IntPtr(-1);
        public const string AuthPredicate = "host_key IN ('claude.ai','.claude.ai') AND name IN ('sessionKey','sessionKeyV2','sessionKeyV3','sessionKeyLC','sessionKeyV3LC','lastActiveOrg')";
        private static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }
        private static string ReadUtf8(IntPtr pointer, int length) {
            if (pointer == IntPtr.Zero) return "";
            if (length < 0) { length = 0; while (Marshal.ReadByte(pointer, length) != 0) length++; }
            byte[] bytes = new byte[length]; Marshal.Copy(pointer, bytes, 0, length); return Encoding.UTF8.GetString(bytes);
        }
        private static IntPtr Open(string path, bool write) {
            IntPtr db; int result = sqlite3_open_v2(Utf8(path), out db, write ? 2 : 1, IntPtr.Zero);
            if (result != 0) { if (db != IntPtr.Zero) sqlite3_close(db); throw new InvalidOperationException("Cannot open Desktop cookie database (SQLite code " + result + "). Close Claude Desktop first."); }
            sqlite3_busy_timeout(db, 2000); return db;
        }
        private static IntPtr Prepare(IntPtr db, string sql) {
            IntPtr statement; byte[] bytes = Utf8(sql);
            int result = sqlite3_prepare_v2(db, bytes, bytes.Length, out statement, IntPtr.Zero);
            if (result != 0) { if (statement != IntPtr.Zero) sqlite3_finalize(statement); throw new InvalidOperationException("Unsupported or locked Desktop cookie database (SQLite code " + result + ")."); }
            return statement;
        }
        private static void Execute(IntPtr db, string sql) {
            IntPtr statement = Prepare(db, sql);
            try { int result = sqlite3_step(statement); if (result != 101) throw new InvalidOperationException("Cookie database update failed (SQLite code " + result + ")."); }
            finally { sqlite3_finalize(statement); }
        }
        public static SqlRow[] Query(string path, string sql) {
            IntPtr db = Open(path, false);
            try {
                IntPtr statement = Prepare(db, sql);
                try {
                    List<SqlRow> rows = new List<SqlRow>(); int result;
                    while ((result = sqlite3_step(statement)) == 100) {
                        SqlCell[] cells = new SqlCell[sqlite3_column_count(statement)];
                        for (int i = 0; i < cells.Length; i++) {
                            int type = sqlite3_column_type(statement, i); string value = null;
                            switch (type) {
                                case 1: value = sqlite3_column_int64(statement, i).ToString(CultureInfo.InvariantCulture); break;
                                case 2: value = sqlite3_column_double(statement, i).ToString("R", CultureInfo.InvariantCulture); break;
                                case 3: value = ReadUtf8(sqlite3_column_text(statement, i), sqlite3_column_bytes(statement, i)); break;
                                case 4: byte[] blob = new byte[sqlite3_column_bytes(statement, i)]; if (blob.Length > 0) Marshal.Copy(sqlite3_column_blob(statement, i), blob, 0, blob.Length); value = Convert.ToBase64String(blob); break;
                            }
                            cells[i] = new SqlCell { Name = ReadUtf8(sqlite3_column_name(statement, i), -1), Type = type, Value = value };
                        }
                        rows.Add(new SqlRow { Cells = cells });
                    }
                    if (result != 101) throw new InvalidOperationException("Cannot read Desktop cookie database (SQLite code " + result + ").");
                    return rows.ToArray();
                } finally { sqlite3_finalize(statement); }
            } finally { sqlite3_close(db); }
        }
        public static void ReplaceAuthCookies(string path, SqlRow[] rows) {
            // Input cannot add arbitrary browser cookies or change table names.
            foreach (SqlRow row in rows) {
                string host = null, name = null;
                foreach (SqlCell cell in row.Cells) { if (cell.Name == "host_key") host = cell.Value; if (cell.Name == "name") name = cell.Value; }
                if ((host != "claude.ai" && host != ".claude.ai") || Array.IndexOf(new string[] { "sessionKey", "sessionKeyV2", "sessionKeyV3", "sessionKeyLC", "sessionKeyV3LC", "lastActiveOrg" }, name) < 0)
                    throw new InvalidOperationException("Snapshot contains an unsupported authentication cookie.");
            }
            IntPtr db = Open(path, true);
            try {
                Execute(db, "BEGIN IMMEDIATE");
                try {
                    Execute(db, "DELETE FROM cookies WHERE " + AuthPredicate);
                    foreach (SqlRow row in rows) {
                        List<string> columns = new List<string>(), placeholders = new List<string>();
                        foreach (SqlCell cell in row.Cells) { columns.Add("\"" + cell.Name.Replace("\"", "\"\"") + "\""); placeholders.Add("?"); }
                        IntPtr statement = Prepare(db, "INSERT INTO cookies (" + String.Join(",", columns) + ") VALUES (" + String.Join(",", placeholders) + ")");
                        try {
                            for (int i = 0; i < row.Cells.Length; i++) {
                                SqlCell cell = row.Cells[i]; int result;
                                switch (cell.Type) {
                                    case 1: result = sqlite3_bind_int64(statement, i+1, Int64.Parse(cell.Value, CultureInfo.InvariantCulture)); break;
                                    case 2: result = sqlite3_bind_double(statement, i+1, Double.Parse(cell.Value, CultureInfo.InvariantCulture)); break;
                                    case 3: byte[] text = Encoding.UTF8.GetBytes(cell.Value); result = sqlite3_bind_text(statement, i+1, Utf8(cell.Value), text.Length, Transient); break;
                                    case 4: byte[] blob = Convert.FromBase64String(cell.Value); result = sqlite3_bind_blob(statement, i+1, blob.Length == 0 ? new byte[1] : blob, blob.Length, Transient); break;
                                    case 5: result = sqlite3_bind_null(statement, i+1); break;
                                    default: throw new InvalidOperationException("Unsupported SQLite value.");
                                }
                                if (result != 0) throw new InvalidOperationException("Could not bind cookie value.");
                            }
                            int step = sqlite3_step(statement); if (step != 101) throw new InvalidOperationException("Could not restore authentication cookie (SQLite code " + step + ").");
                        } finally { sqlite3_finalize(statement); }
                    }
                    Execute(db, "COMMIT");
                } catch { try { Execute(db, "ROLLBACK"); } catch {} throw; }
            } finally { sqlite3_close(db); }
        }
        // Used only to build fake databases in the test suite.
        public static void CreateTestDatabase(string path, string[] statements) {
            IntPtr db; int result = sqlite3_open_v2(Utf8(path), out db, 6, IntPtr.Zero);
            if (result != 0) throw new InvalidOperationException("Cannot create test database.");
            try { foreach (string sql in statements) Execute(db, sql); } finally { sqlite3_close(db); }
        }
    }
}
