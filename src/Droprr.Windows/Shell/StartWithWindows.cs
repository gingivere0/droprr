using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Droprr;

static class StartWithWindows
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Droprr";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    // Points the sign-in entry at `exe` (this one by default).
    public static void Set(bool enabled, string? exe = null)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && (exe ?? Environment.ProcessPath) is { } path)
            key.SetValue(ValueName, $"\"{path}\" --background");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
