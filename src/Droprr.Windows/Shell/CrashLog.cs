using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Droprr;

// %APPDATA%\Droprr\crash.log: unhandled exceptions with their stack, never tokens or file contents. An exception
// on the UI thread or in a forgotten task is logged and survived; one anywhere else ends the app, but is logged
// first. (A crash inside native code, such as an access violation, can't be caught here; Windows' Event Viewer
// still records those.)
static class CrashLog
{
    const long MaxBytes = 512 * 1024;
    static readonly object Gate = new();

    static string FilePath => Path.Combine(SettingsStore.Folder, "crash.log");

    public static void Install(Application app)
    {
        app.DispatcherUnhandledException += (_, e) =>
        {
            Write("UI thread (survived)", e.Exception);
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Write(e.IsTerminating ? "background thread (app closed)" : "background thread", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Write("background task (survived)", e.Exception);
            e.SetObserved();
        };
    }

    public static void Write(string where, Exception? error)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(SettingsStore.Folder);
                var file = new FileInfo(FilePath);
                if (file.Exists && file.Length > MaxBytes)
                    file.Delete();
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {where}: {error}{Environment.NewLine}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
            // Logging is best effort.
        }
    }
}
