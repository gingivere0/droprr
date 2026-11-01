using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// Launching Droprr while it's already running (from Search, the Start menu, or Explorer's Send To) hands the
// command line to the running copy over a pipe that only this Windows user can open, then exits quietly.
static class SingleInstance
{
    const int AnyProcess = -1;

    static string PipeName => "Droprr-" + WindowsIdentity.GetCurrent().User!.Value;

    // Returns false if no running copy answered, so the caller can fall back.
    public static bool TryForward(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect(2000);
            // This process was just started by the user, so it may pass its right to take the foreground on.
            AllowSetForegroundWindow(AnyProcess);
            using var writer = new StreamWriter(client);
            writer.Write(JsonSerializer.Serialize(args));
            return true;
        }
        catch (Exception ex) when (ex is TimeoutException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // Calls onArgs, on a background thread, with the command line of each later launch.
    public static void Listen(Action<string[]> onArgs, CancellationToken stop) => Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(stop);
                using var reader = new StreamReader(server);
                if (JsonSerializer.Deserialize<string[]>(await reader.ReadToEndAsync(stop)) is { } args)
                    onArgs(args);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                await Task.Delay(500, CancellationToken.None);
            }
        }
    });

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);
}
