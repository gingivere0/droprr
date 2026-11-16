using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// How a delivery ended: sent directly (with the path it took), or queued for a phone or browser to collect.
public sealed record DeliveryResult(SendOutcome? Outcome, bool Queued)
{
    // "wifi", "tailscale", or "queued", for the local API.
    public string Wire => Queued ? "queued" : Outcome?.Path == SendPath.Lan ? "wifi" : "tailscale";
}

// One send to a peer, from the Send window or the local API. A computer gets the items directly. A phone that
// gave this PC a token and is open on this network takes them directly too; otherwise (or if nothing got through
// before it closed Droprr) they're queued in its outbox. Files go first, then the text.
sealed class Delivery(Peer peer, IReadOnlyList<string> paths, string text)
{
    // The files went through (direct or queued), even if the text after them didn't.
    public bool FilesDone { get; private set; }

    public async Task<DeliveryResult> RunAsync(IProgress<long>? progress = null, CancellationToken cancel = default,
        IProgress<string>? stage = null)
    {
        long moved = 0;
        var counted = new Counted(n =>
        {
            Interlocked.Add(ref moved, n);
            progress?.Report(n);
        });

        var queue = peer.IsPhone && !(peer.Token.Length > 0 && await Sender.IsOnLanAsync(peer, cancel));
        if (!queue)
        {
            try
            {
                SendOutcome? outcome = null;
                if (paths.Count > 0)
                {
                    outcome = await Sender.SendFilesAsync(peer, peer.Token, paths, counted, cancel, stage);
                    FilesDone = true;
                }
                if (text.Length > 0)
                    outcome = await Sender.SendTextAsync(peer, peer.Token, text, cancel, stage);
                if (outcome is not null)
                    RememberPath(peer, outcome.Path);
                return new DeliveryResult(outcome, Queued: false);
            }
            catch (HttpRequestException) when (peer.IsPhone && !cancel.IsCancellationRequested && Interlocked.Read(ref moved) == 0)
            {
            }
        }
        foreach (var path in paths)
            await Outbox.EnqueueFileAsync(peer.Name, path, counted, cancel);
        FilesDone = paths.Count > 0;
        if (text.Length > 0)
            Outbox.EnqueueText(peer.Name, Sender.TextType(text), text);
        return new DeliveryResult(null, Queued: true);
    }

    // Saved per device, so Settings can show which path it last took.
    static void RememberPath(Peer peer, SendPath path)
    {
        if (peer.LastPath == path)
            return;
        peer.LastPath = path;
        SettingsStore.Update(s =>
        {
            if (s.Peers.FindByName(peer.Name) is { } saved)
                saved.LastPath = path;
        });
    }

    // Reports synchronously, unlike Progress<T>, so the byte count is current when a send fails.
    sealed class Counted(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
    }
}
