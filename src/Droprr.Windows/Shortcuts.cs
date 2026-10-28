using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Droprr;

// Explorer's Send To entry and the Start menu shortcut (which is what makes Droprr show up in Windows Search).
// Both point at the running exe, so they follow it if it's moved or rebuilt elsewhere.
static class Shortcuts
{
    // Ties the process, its notifications, and the Start menu shortcut together as one app.
    public const string AppUserModelId = "Droprr.Droprr";

    static string SendToPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Droprr.lnk");

    static string StartMenuPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Droprr.lnk");

    public static void SetProcessAppId() => SetCurrentProcessExplicitAppUserModelID(AppUserModelId);

    // Explorer passes the selected files after --send.
    public static void RegisterSendTo()
    {
        if (CurrentExe() is { } exe)
            Write(SendToPath, exe, "--send", "Send to another device with Droprr", appId: null);
    }

    public static void SyncStartMenu(bool enabled)
    {
        if (!enabled)
        {
            File.Delete(StartMenuPath);
            return;
        }
        if (CurrentExe() is { } exe && !PointsAt(StartMenuPath, exe))
            Write(StartMenuPath, exe, "", "Send files, text, and links between your devices", AppUserModelId);
    }

    // Null when running under dotnet.exe (dotnet run), where a shortcut to the host would be wrong.
    static string? CurrentExe()
    {
        var exe = Environment.ProcessPath;
        return exe is null || Path.GetFileName(exe).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase) ? null : exe;
    }

    static bool PointsAt(string linkPath, string exe)
    {
        if (!File.Exists(linkPath))
            return false;
        var link = (IShellLinkW)new CShellLink();
        try
        {
            ((IPersistFile)link).Load(linkPath, 0);
            var target = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
            return string.Equals(target.ToString(), exe, StringComparison.OrdinalIgnoreCase);
        }
        catch (COMException)
        {
            return false;
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    static void Write(string linkPath, string exe, string arguments, string description, string? appId)
    {
        var link = (IShellLinkW)new CShellLink();
        try
        {
            link.SetPath(exe);
            link.SetArguments(arguments);
            link.SetWorkingDirectory(Path.GetDirectoryName(exe)!);
            link.SetDescription(description);
            link.SetIconLocation(exe, 0);
            if (appId is not null)
            {
                var store = (IPropertyStore)link;
                var key = AppUserModelIdKey;
                var value = new PropVariant { Type = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(appId) };
                try
                {
                    store.SetValue(ref key, ref value);
                    store.Commit();
                }
                finally
                {
                    Marshal.FreeCoTaskMem(value.Pointer);
                }
            }
            ((IPersistFile)link).Save(linkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    static readonly PropertyKey AppUserModelIdKey = new() { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SetCurrentProcessExplicitAppUserModelID(string appId);

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int size, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int size);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int size);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int size);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int size, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    // Just enough of PROPVARIANT for a string value.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
    }
}
