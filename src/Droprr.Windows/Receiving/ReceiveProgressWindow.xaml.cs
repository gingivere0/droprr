using System.Windows;

namespace Droprr;

// Small corner window shown while a large item arrives.
public partial class ReceiveProgressWindow : Wpf.Ui.Controls.FluentWindow
{
    public ReceiveProgressWindow()
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        Loaded += (_, _) =>
        {
            var area = SystemParameters.WorkArea;
            Left = area.Right - ActualWidth - 16;
            Top = area.Bottom - ActualHeight - 16;
        };
    }

    public void Update(TransferProgress progress)
    {
        Bar.IsIndeterminate = progress.Total is null;
        if (progress.Total is { } total && total > 0)
        {
            Bar.Value = 100.0 * progress.Received / total;
            Detail.Text = $"{FormatSize(progress.Received)} of {FormatSize(total)}";
        }
        else
        {
            Detail.Text = FormatSize(progress.Received);
        }
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.0} GB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.0} MB",
        >= 1L << 10 => $"{bytes / 1024.0:0} KB",
        _ => $"{bytes} bytes",
    };
}
