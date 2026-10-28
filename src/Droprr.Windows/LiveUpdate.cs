using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace Droprr;

// Deploys without touching the running app. scripts/deploy.ps1 publishes each build into
// deploy\<yyyyMMdd-HHmmss>\ and writes a "ready" marker last. A Droprr running from one of those folders
// watches for a newer one, starts it with --replace <its pid>, and exits. The new copy waits for the old
// one to exit before it binds the port. Droprr run from anywhere else ignores all of this.
static class LiveUpdate
{
    const string ReadyMarker = "ready";

    static string? CurrentVersionFolder => Path.GetDirectoryName(Environment.ProcessPath);

    // The deploy folder, if this exe is running from deploy\<version>\.
    static string? DeployFolder =>
        CurrentVersionFolder is { } current
        && Directory.GetParent(current) is { Name: "deploy" } parent
            ? parent.FullName
            : null;

    static IEnumerable<DirectoryInfo> ReadyVersions(string deploy) =>
        new DirectoryInfo(deploy).EnumerateDirectories()
            .Where(d => File.Exists(Path.Combine(d.FullName, ReadyMarker)) && File.Exists(Path.Combine(d.FullName, "Droprr.exe")))
            .OrderBy(d => d.Name, StringComparer.Ordinal);

    // The exe of a ready version newer than this one, if there is one.
    public static string? NewerVersion()
    {
        if (DeployFolder is not { } deploy || CurrentVersionFolder is not { } current)
            return null;
        var currentName = Path.GetFileName(current);
        var newest = ReadyVersions(deploy).LastOrDefault();
        return newest is not null && string.CompareOrdinal(newest.Name, currentName) > 0
            ? Path.Combine(newest.FullName, "Droprr.exe")
            : null;
    }

    // Started by Seth's own running copy, so the new one runs with the same rights and outside any sandbox.
    public static void StartReplacement(string exe, IEnumerable<string> reopen)
    {
        var arguments = $"--replace {Environment.ProcessId}" + string.Concat(reopen.Select(w => $" --reopen {w}"));
        Process.Start(new ProcessStartInfo(exe, arguments)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(exe),
        });
    }

    // Called by the new copy before it takes the single-instance lock and the port.
    public static void WaitForReplaced(string[] args)
    {
        var index = Array.IndexOf(args, "--replace");
        if (index < 0 || index + 1 >= args.Length || !int.TryParse(args[index + 1], out var pid))
            return;
        try
        {
            using var old = Process.GetProcessById(pid);
            old.WaitForExit(30_000);
        }
        catch (ArgumentException)
        {
            // Already gone.
        }
    }

    // Windows that were open in the copy this one replaced.
    public static IEnumerable<string> WindowsToReopen(string[] args) =>
        args.Select((arg, i) => (arg, i))
            .Where(p => p.arg == "--reopen" && p.i + 1 < args.Length)
            .Select(p => args[p.i + 1]);

    // Keeps the two newest versions (one of which is this one) and removes the rest.
    public static void RemoveOldVersions()
    {
        if (DeployFolder is not { } deploy || CurrentVersionFolder is not { } current)
            return;
        var keep = ReadyVersions(deploy).Select(d => d.FullName).TakeLast(2).Append(current).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in new DirectoryInfo(deploy).EnumerateDirectories())
        {
            if (keep.Contains(folder.FullName) || string.CompareOrdinal(folder.Name, Path.GetFileName(current)) > 0)
                continue;
            try { folder.Delete(recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
