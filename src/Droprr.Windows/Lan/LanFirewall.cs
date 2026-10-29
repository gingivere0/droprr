using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;

namespace Droprr;

// The Windows Firewall rule the local network needs: inbound TCP on the HTTPS port, Private networks only.
// Reading rules needs no elevation; adding one takes a single UAC prompt, and only when the person asks.
// Droprr doesn't listen on the LAN until the rule exists, so Windows never asks about each new build itself
// (a "Cancel" there would create a block rule for that copy).
static class LanFirewall
{
    public const string RuleName = "Droprr (local network)";

    const int ProfilePrivate = 2, DirectionIn = 1, ActionBlock = 0, ActionAllow = 1;

    public static bool HasRule(int port)
    {
        try
        {
            foreach (dynamic rule in Policy().Rules)
            {
                if ((string)rule.Name == RuleName && (bool)rule.Enabled && (int)rule.Direction == DirectionIn
                    && (int)rule.Action == ActionAllow && ((int)rule.Profiles & ProfilePrivate) != 0
                    && ((string?)rule.LocalPorts ?? "").Split(',').Contains(port.ToString()))
                    return true;
            }
        }
        catch (Exception ex)
        {
            RequestLog.Note($"local network: couldn't read firewall rules: {ex.Message.ReplaceLineEndings(" ")}");
        }
        return false;
    }

    // Inbound block rules for any Droprr.exe, which Windows makes when someone answers "Cancel" to its
    // "allow access?" prompt. They'd override the allow rule for that copy.
    public static IReadOnlyList<(string Name, string Program)> BlockRules()
    {
        var found = new List<(string, string)>();
        try
        {
            foreach (dynamic rule in Policy().Rules)
            {
                var program = (string?)rule.ApplicationName ?? "";
                if ((int)rule.Direction == DirectionIn && (int)rule.Action == ActionBlock
                    && program.EndsWith("\\Droprr.exe", StringComparison.OrdinalIgnoreCase))
                    found.Add(((string)rule.Name, program));
            }
        }
        catch (Exception ex)
        {
            RequestLog.Note($"local network: couldn't read firewall rules: {ex.Message.ReplaceLineEndings(" ")}");
        }
        return found;
    }

    // Adds the rule (replacing an older one with the same name) and removes Droprr block rules, in one elevated
    // netsh run. Returns whether the rule exists afterward; false if the person declined the UAC prompt.
    public static async Task<bool> AllowAsync(int port)
    {
        var commands = new List<string>
        {
            $"netsh advfirewall firewall delete rule name=\"{RuleName}\"",
            $"netsh advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow protocol=TCP localport={port} profile=private",
        };
        commands.AddRange(BlockRules().Select(r => $"netsh advfirewall firewall delete rule name=\"{r.Name}\" program=\"{r.Program}\""));
        var start = new ProcessStartInfo("cmd.exe", "/c " + string.Join(" & ", commands))
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            using var process = Process.Start(start);
            if (process is not null)
                await process.WaitForExitAsync();
        }
        catch (Win32Exception)
        {
            // The UAC prompt was declined.
            return false;
        }
        var ok = HasRule(port);
        RequestLog.Note($"local network: firewall rule for port {port} {(ok ? "added" : "not added")}");
        return ok;
    }

    static dynamic Policy() => Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: true)!)!;
}
