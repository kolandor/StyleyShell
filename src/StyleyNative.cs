// Native helpers for styley: live console palette, VT mode and .lnk console properties.
// Compiled once by styley.ps1 (Add-Type) and cached as a DLL under %LOCALAPPDATA%\styley\cache.
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace Styley
{
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO_EX
    {
        public uint cbSize;
        public COORD dwSize;
        public COORD dwCursorPosition;
        public ushort wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
        public ushort wPopupAttributes;
        [MarshalAs(UnmanagedType.Bool)] public bool bFullscreenSupported;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public uint[] ColorTable;
    }

    public static class Console
    {
        const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
        const uint ENABLE_PROCESSED_OUTPUT = 0x1, ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfoEx(IntPtr h, ref CONSOLE_SCREEN_BUFFER_INFO_EX info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleScreenBufferInfoEx(IntPtr h, ref CONSOLE_SCREEN_BUFFER_INFO_EX info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadConsoleOutputAttribute(IntPtr h, [Out] ushort[] attrs, uint len, COORD at, out uint read);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteConsoleOutputAttribute(IntPtr h, ushort[] attrs, uint len, COORD at, out uint written);

        // CONOUT$ is the console of this process even when stdout is redirected (e.g. `styley list | more`).
        static IntPtr Open()
        {
            IntPtr h = CreateFileW("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == IntPtr.Zero || h == new IntPtr(-1)) throw new InvalidOperationException("No console attached (CONOUT$ unavailable).");
            return h;
        }

        static CONSOLE_SCREEN_BUFFER_INFO_EX Read(IntPtr h)
        {
            var info = new CONSOLE_SCREEN_BUFFER_INFO_EX();
            info.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_SCREEN_BUFFER_INFO_EX));
            if (!GetConsoleScreenBufferInfoEx(h, ref info))
                throw new InvalidOperationException("GetConsoleScreenBufferInfoEx failed: " + Marshal.GetLastWin32Error());
            return info;
        }

        public static bool IsAvailable()
        {
            try { IntPtr h = Open(); try { Read(h); return true; } finally { CloseHandle(h); } }
            catch { return false; }
        }

        /// <summary>Returns 18 values: ColorTable[0..15], wAttributes, wPopupAttributes.</summary>
        public static uint[] GetPalette()
        {
            IntPtr h = Open();
            try
            {
                var info = Read(h);
                var r = new uint[18];
                Array.Copy(info.ColorTable, r, 16);
                r[16] = info.wAttributes;
                r[17] = info.wPopupAttributes;
                return r;
            }
            finally { CloseHandle(h); }
        }

        /// <summary>
        /// Applies a palette to the current console window immediately.
        /// Cells that still carry the old default attribute are switched to the new one,
        /// so the existing screen follows the new background instead of keeping stripes.
        /// </summary>
        public static void SetPalette(uint[] table, ushort attr, ushort popup, bool remapCells)
        {
            if (table == null || table.Length != 16) throw new ArgumentException("table must have 16 entries");
            IntPtr h = Open();
            try
            {
                var info = Read(h);
                ushort oldAttr = info.wAttributes;
                short lastRow = Math.Max(info.dwCursorPosition.Y, info.srWindow.Bottom);
                short width = info.dwSize.X;

                info.ColorTable = (uint[])table.Clone();
                info.wAttributes = attr;
                info.wPopupAttributes = popup;
                // Known quirk: Set* treats srWindow as exclusive, Get* returns it inclusive.
                // Without this the window shrinks by one row and column on every call.
                info.srWindow.Right++;
                info.srWindow.Bottom++;
                if (!SetConsoleScreenBufferInfoEx(h, ref info))
                    throw new InvalidOperationException("SetConsoleScreenBufferInfoEx failed: " + Marshal.GetLastWin32Error());

                if (remapCells && (oldAttr & 0xFF) != (attr & 0xFF) && width > 0)
                    RemapAttributes(h, (ushort)(oldAttr & 0xFF), (ushort)(attr & 0xFF), width, lastRow);
            }
            finally { CloseHandle(h); }
        }

        static void RemapAttributes(IntPtr h, ushort from, ushort to, short width, short lastRow)
        {
            const int rowsPerChunk = 200;
            for (int top = 0; top <= lastRow; top += rowsPerChunk)
            {
                int rows = Math.Min(rowsPerChunk, lastRow - top + 1);
                uint len = (uint)(rows * width), n;
                var buf = new ushort[len];
                var at = new COORD { X = 0, Y = (short)top };
                if (!ReadConsoleOutputAttribute(h, buf, len, at, out n)) return;
                bool changed = false;
                for (int i = 0; i < n; i++)
                {
                    if ((buf[i] & 0xFF) == from) { buf[i] = (ushort)((buf[i] & 0xFF00) | to); changed = true; }
                }
                if (changed) WriteConsoleOutputAttribute(h, buf, n, at, out n);
            }
        }

        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder name, int max);

        /// <summary>
        /// True when this console is a pseudoconsole (ConPTY): Windows Terminal, VS Code and others.
        /// Such hosts ignore the console palette API. Unlike WT_SESSION this also covers windows that
        /// conhost handed over to Windows Terminal (default terminal), e.g. started from a .lnk shortcut.
        /// </summary>
        public static bool IsPseudoConsole()
        {
            IntPtr w = GetConsoleWindow();
            if (w == IntPtr.Zero) return false;
            var sb = new System.Text.StringBuilder(64);
            return GetClassNameW(w, sb, sb.Capacity) > 0 && sb.ToString() == "PseudoConsoleWindow";
        }

        [DllImport("kernel32.dll", SetLastError = true)] static extern uint GetConsoleProcessList([Out] uint[] list, uint count);

        /// <summary>Process ids attached to this console window (empty when unknown).</summary>
        public static uint[] GetProcesses()
        {
            var buf = new uint[64];
            uint n = GetConsoleProcessList(buf, (uint)buf.Length);
            if (n == 0) return new uint[0];
            if (n > buf.Length) { buf = new uint[n]; n = GetConsoleProcessList(buf, n); }
            var r = new uint[Math.Min(n, (uint)buf.Length)];
            Array.Copy(buf, r, r.Length);
            return r;
        }

        /// <summary>Enables VT escape processing on the console output. Returns the previous mode, or -1.</summary>
        public static long EnableVirtualTerminal()
        {
            try
            {
                IntPtr h = Open();
                try
                {
                    uint mode;
                    if (!GetConsoleMode(h, out mode)) return -1;
                    SetConsoleMode(h, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
                    return mode;
                }
                finally { CloseHandle(h); }
            }
            catch { return -1; }
        }

        public static void RestoreMode(long mode)
        {
            if (mode < 0) return;
            try { IntPtr h = Open(); try { SetConsoleMode(h, (uint)mode); } finally { CloseHandle(h); } }
            catch { }
        }
    }

    [ComImport, Guid("45e2b4ae-b1c3-11d0-b92f-00a0c90312e1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkDataList
    {
        void AddDataBlock(IntPtr pDataBlock);
        void CopyDataBlock(uint dwSig, out IntPtr ppDataBlock);
        void RemoveDataBlock(uint dwSig);
        void GetFlags(out uint pdwFlags);
        void SetFlags(uint dwFlags);
    }

    public static class Shortcut
    {
        const uint NT_CONSOLE_PROPS_SIG = 0xA0000002;
        const int NT_CONSOLE_PROPS_SIZE = 204;
        const int OFF_FILL = 8, OFF_POPUP = 10, OFF_COLORS = 140;
        static readonly Guid CLSID_ShellLink = new Guid("00021401-0000-0000-C000-000000000046");
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);

        /// <summary>
        /// Writes the palette into the console block (NT_CONSOLE_PROPS) of a .lnk file.
        /// Returns "updated", "no-console-block" (the shortcut uses the registry) or an error text.
        /// </summary>
        public static string SetPalette(string path, uint[] table, ushort fill, ushort popup)
        {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
            try
            {
                ((IPersistFile)link).Load(path, 2 /* STGM_READWRITE */);
                var dl = (IShellLinkDataList)link;
                IntPtr p;
                try { dl.CopyDataBlock(NT_CONSOLE_PROPS_SIG, out p); }
                catch (COMException) { return "no-console-block"; }
                if (p == IntPtr.Zero) return "no-console-block";
                try
                {
                    int size = Marshal.ReadInt32(p, 0);
                    if (size < NT_CONSOLE_PROPS_SIZE) return "unexpected-block-size-" + size;
                    Marshal.WriteInt16(p, OFF_FILL, (short)fill);
                    Marshal.WriteInt16(p, OFF_POPUP, (short)popup);
                    for (int i = 0; i < 16; i++) Marshal.WriteInt32(p, OFF_COLORS + i * 4, (int)table[i]);
                    dl.RemoveDataBlock(NT_CONSOLE_PROPS_SIG);
                    dl.AddDataBlock(p);
                }
                finally { LocalFree(p); }
                ((IPersistFile)link).Save(null, true);
                return "updated";
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        /// <summary>
        /// Adds (or replaces) the whole console block of a .lnk. Used for shortcuts that have no block:
        /// such shortcuts take colours from HKCU\Console, not from the per-program key, so a theme for one
        /// shell only would not reach them otherwise.
        /// </summary>
        public static string SetConsoleBlock(string path, byte[] block)
        {
            if (block == null || block.Length != NT_CONSOLE_PROPS_SIZE) throw new ArgumentException("block must be 204 bytes");
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
            try
            {
                ((IPersistFile)link).Load(path, 2 /* STGM_READWRITE */);
                var dl = (IShellLinkDataList)link;
                try { dl.RemoveDataBlock(NT_CONSOLE_PROPS_SIG); } catch (COMException) { }
                IntPtr p = Marshal.AllocHGlobal(block.Length);
                try
                {
                    Marshal.Copy(block, 0, p, block.Length);
                    dl.AddDataBlock(p);
                }
                finally { Marshal.FreeHGlobal(p); }
                ((IPersistFile)link).Save(null, true);
                return "created";
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        /// <summary>Reads 18 values (16 colours, fill, popup) from the console block, or null.</summary>
        public static uint[] GetPalette(string path)
        {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_ShellLink));
            try
            {
                ((IPersistFile)link).Load(path, 0 /* STGM_READ */);
                IntPtr p;
                try { ((IShellLinkDataList)link).CopyDataBlock(NT_CONSOLE_PROPS_SIG, out p); }
                catch (COMException) { return null; }
                if (p == IntPtr.Zero) return null;
                try
                {
                    var r = new uint[18];
                    for (int i = 0; i < 16; i++) r[i] = (uint)Marshal.ReadInt32(p, OFF_COLORS + i * 4);
                    r[16] = (ushort)Marshal.ReadInt16(p, OFF_FILL);
                    r[17] = (ushort)Marshal.ReadInt16(p, OFF_POPUP);
                    return r;
                }
                finally { LocalFree(p); }
            }
            finally { Marshal.ReleaseComObject(link); }
        }
    }
}
