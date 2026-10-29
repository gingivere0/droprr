using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Droprr;

// Droprr is its own installer. The release build is one self-contained exe (scripts\build-installer.ps1). Named
// DroprrSetup*.exe, or started with --install, it shows SetupWindow and copies itself to
// %LOCALAPPDATA%\Programs\Droprr\Droprr.exe: a per-user install with no administrator rights. It stops a running
// Droprr first (an older install or a deploy\ build), keeps settings, devices, and received files, adds the Start
// menu and Send To shortcuts and an Apps entry, and can turn on run-at-sign-in and the firewall rules (one UAC
// prompt). The installed copy's --uninstall undoes all of it.
static class Installer
{
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Droprr";

    public static string Version { get; } =
        typeof(Installer).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public static string InstallFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Droprr");

    public static string InstalledExe => Path.Combine(InstallFolder, "Droprr.exe");

    public static bool IsInstalled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(UninstallKey);
            return key is not null && File.Exists(InstalledExe);
        }
    }

    // This process is the installed copy.
    public static bool IsInstalledCopy =>
        string.Equals(Environment.ProcessPath, InstalledExe, StringComparison.OrdinalIgnoreCase);

    public static bool IsSetupLaunch(string[] args) =>
        args.Contains("--install")
        || Path.GetFileName(Environment.ProcessPath ?? "").StartsWith("DroprrSetup", StringComparison.OrdinalIgnoreCase);

    public static bool IsUninstallLaunch(string[] args) => args.Contains("--uninstall");

    // Droprr processes of this user other than this one.
    public static IReadOnlyList<Process> FindRunning()
    {
        var me = Environment.ProcessId;
        var session = Process.GetCurrentProcess().SessionId;
        return Process.GetProcessesByName("Droprr").Where(p => p.Id != me && p.SessionId == session).ToList();
    }

    // Asks the running Droprr to exit (it finishes what it's receiving first), then ends it if it hasn't after a while.
    static async Task StopRunningAsync()
    {
        var running = FindRunning();
        if (running.Count == 0)
            return;
        SingleInstance.TryForward(["--quit"]);
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && running.Any(p => !p.HasExited))
            await Task.Delay(250);
        foreach (var process in running.Where(p => !p.HasExited))
        {
            try
            {
                process.Kill();
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or TimeoutException)
            {
            }
        }
    }

    // Returns false if the firewall rules were wanted but Windows didn't allow them.
    public static async Task<bool> InstallAsync(bool startAtSignIn, bool firewall)
    {
        var source = Environment.ProcessPath ?? throw new InvalidOperationException("Can't find this installer's own file.");
        await StopRunningAsync();
        await InstallFilesAsync(source, startAtSignIn);
        return !firewall || await LanFirewall.SetRulesAsync(Port(), allow: true);
    }

    // The install itself, once nothing is running: the exe, the Apps entry, shortcuts, and the sign-in entry.
    internal static async Task InstallFilesAsync(string source, bool startAtSignIn)
    {
        Directory.CreateDirectory(InstallFolder);
        if (!string.Equals(Path.GetFullPath(source), InstalledExe, StringComparison.OrdinalIgnoreCase))
            await RetryAsync(() => File.Copy(source, InstalledExe, overwrite: true));

        using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", "Droprr");
            key.SetValue("DisplayVersion", Version);
            key.SetValue("Publisher", "Droprr");
            key.SetValue("DisplayIcon", $"\"{InstalledExe}\",0");
            key.SetValue("InstallLocation", InstallFolder);
            key.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
            key.SetValue("QuietUninstallString", $"\"{InstalledExe}\" --uninstall --quiet");
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            key.SetValue("EstimatedSize", (int)(new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        Shortcuts.Install(InstalledExe);
        StartWithWindows.Set(startAtSignIn, InstalledExe);
        RequestLog.Note($"installed version {Version}");
    }

    public static void LaunchInstalled() =>
        Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = false, WorkingDirectory = InstallFolder });

    // Both firewall rules (Tailscale, and the local network if it's on) are there.
    public static bool FirewallReady()
    {
        var port = Port();
        return LanFirewall.HasTailscaleRule(port) && LanFirewall.HasRule(LanNetwork.TlsPort(port));
    }

    static int Port()
    {
        try
        {
            return SettingsStore.Load().Port;
        }
        catch (Exception)
        {
            return AppSettings.DefaultPort;
        }
    }

    // Removes everything the installer and the app added, except received files and (unless `removeSettings`) the
    // settings with their paired devices. The install folder is deleted a few seconds after this process exits.
    public static async Task UninstallAsync(bool removeSettings)
    {
        await StopRunningAsync();
        var port = Port();
        if (LanFirewall.HasTailscaleRule(port) || LanFirewall.HasRule(LanNetwork.TlsPort(port)))
            await LanFirewall.SetRulesAsync(port, allow: false);
        RemoveFiles(removeSettings);

        // This exe can't delete itself while running: a hidden cmd waits a moment, then removes the folder.
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping -n 4 127.0.0.1 >nul & rmdir /s /q \"{InstallFolder}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetTempPath(),
        });
    }

    // Everything but the firewall rules and the install folder itself.
    internal static void RemoveFiles(bool removeSettings)
    {
        try { StartWithWindows.Set(false); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        Shortcuts.Uninstall(InstallFolder);
        TryDeleteFolder(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Droprr"));
        if (removeSettings)
            TryDeleteFolder(SettingsStore.Folder);
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false);
    }

    static void TryDeleteFolder(string folder)
    {
        try
        {
            if (Directory.Exists(folder))
                Directory.Delete(folder, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    static async Task RetryAsync(Action action)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException && attempt < 20)
            {
                await Task.Delay(500);
            }
        }
    }

    // The installer or uninstaller, run instead of the app. Returns the process exit code.
    public static async Task<int> RunAsync(string[] args)
    {
        if (!IsUninstallLaunch(args))
        {
            var window = new SetupWindow();
            var closed = new TaskCompletionSource();
            window.Closed += (_, _) => closed.TrySetResult();
            window.Show();
            await closed.Task;
            return 0;
        }

        if (!args.Contains("--quiet"))
        {
            var confirm = new Wpf.Ui.Controls.MessageBox
            {
                Title = "Uninstall Droprr?",
                Content = "Droprr will be removed from this PC, with its shortcuts and firewall rules. Files you received stay in your Downloads folder.",
                PrimaryButtonText = "Uninstall",
                CloseButtonText = "Cancel",
            };
            if (await confirm.ShowDialogAsync() != Wpf.Ui.Controls.MessageBoxResult.Primary)
                return 1;
        }
        var removeSettings = false;
        if (!args.Contains("--quiet"))
        {
            var keep = new Wpf.Ui.Controls.MessageBox
            {
                Title = "Keep your devices?",
                Content = "Keep Droprr's settings and paired devices, in case you install it again? Removing them means pairing every device again.",
                PrimaryButtonText = "Keep",
                SecondaryButtonText = "Remove",
                CloseButtonText = "Cancel",
            };
            var answer = await keep.ShowDialogAsync();
            if (answer == Wpf.Ui.Controls.MessageBoxResult.None)
                return 1;
            removeSettings = answer == Wpf.Ui.Controls.MessageBoxResult.Secondary;
        }
        await UninstallAsync(removeSettings);
        return 0;
    }
}
