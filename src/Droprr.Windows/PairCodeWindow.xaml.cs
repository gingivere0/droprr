using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace Droprr;

// LAN pairing's code screen. Asking: a nearby device wants to pair; the person checks that both screens show the
// same code and accepts or declines. Waiting: this PC asked; it shows the code while the person there confirms.
public partial class PairCodeWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly TaskCompletionSource<bool> _answer = new();
    Action? _onCancel;

    PairCodeWindow(string code)
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        CodeText.Text = $"{code[..3]} {code[3..]}";
        Closed += (_, _) =>
        {
            _answer.TrySetResult(false);
            _onCancel?.Invoke();
        };
    }

    // Returns whether the person accepted; false if they declined or closed the window. Canceled (an
    // OperationCanceledException) if `cancel` fired first: the request timed out or the device gave up.
    // It appears on top without taking the keyboard, and has no default button, so typing elsewhere can't accept a
    // request nobody expected.
    public static Task<bool> AskAsync(string name, string code, CancellationToken cancel)
    {
        name = FileNames.Printable(name, 64);
        var window = new PairCodeWindow(code);
        window.Heading.Text = $"Pair with {name}?";
        window.Hint.Text = $"Only if you started pairing on {name} and it shows this code. Pairing lets it send to this PC, and this PC send to it.";
        var registration = cancel.Register(() => window.Dispatcher.BeginInvoke(() =>
        {
            window._answer.TrySetCanceled(cancel);
            window.Close();
        }));
        window._answer.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        window.Show();
        return window._answer.Task;
    }

    // Shown while this PC waits for the other device; closing it (or Cancel) calls `onCancel`.
    public static PairCodeWindow ShowWaiting(string name, string code, Action onCancel)
    {
        var window = new PairCodeWindow(code) { _onCancel = onCancel };
        window.Heading.Text = $"Confirm on {name}";
        window.Hint.Text = $"{name} should show the same code. Accept there to pair.";
        window.AcceptButton.Visibility = Visibility.Collapsed;
        window.DeclineButton.Content = "Cancel";
        window.Show();
        return window;
    }

    // Closing after a result shouldn't count as cancelling.
    public new void Close()
    {
        _onCancel = null;
        base.Close();
    }

    void OnAccept(object sender, RoutedEventArgs e)
    {
        _answer.TrySetResult(true);
        Close();
    }

    // Decline, or Cancel while waiting: closing answers false and calls onCancel.
    void OnDecline(object sender, RoutedEventArgs e) => base.Close();
}
