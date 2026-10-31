using System;
using System.Threading.Tasks;
using System.Windows;
using Wpf.Ui.Controls;

namespace Droprr;

// The installer's one window (see Installer): what will happen, two choices, and Install.
public partial class SetupWindow : FluentWindow
{
    public SetupWindow()
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        Logo.Source = AppIcon.ImageSource;
        Version.Text = $"Version {Installer.Version}";
        var upgrading = Installer.FindRunning().Count > 0 || Installer.IsInstalled;
        Heading.Text = upgrading ? "Update Droprr" : "Install Droprr";
        InstallButton.Content = upgrading ? "Update" : "Install";
        Summary.Text = @"Droprr is installed just for you, in AppData\Local\Programs\Droprr, without administrator rights."
            + (upgrading ? " This replaces the Droprr you have now. Your devices, settings, and received files are kept." : "");
        SignInBox.IsChecked = !Installer.IsInstalled || StartWithWindows.IsEnabled;
        var rulesNeeded = !Installer.FirewallReady();
        FirewallBox.IsChecked = rulesNeeded;
        FirewallBox.Visibility = FirewallHint.Visibility = rulesNeeded ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnCancel(object sender, RoutedEventArgs e) => Close();

    async void OnInstall(object sender, RoutedEventArgs e)
    {
        InstallButton.IsEnabled = CancelButton.IsEnabled = SignInBox.IsEnabled = FirewallBox.IsEnabled = false;
        Busy.Visibility = Visibility.Visible;
        Status.IsOpen = false;
        try
        {
            var firewallOk = await Installer.InstallAsync(SignInBox.IsChecked == true, FirewallBox.IsChecked == true && FirewallBox.IsVisible);
            Installer.LaunchInstalled();
            if (!firewallOk)
            {
                Busy.Visibility = Visibility.Collapsed;
                Status.Severity = InfoBarSeverity.Warning;
                Status.Title = "Droprr is installed";
                Status.Message = "Windows Firewall wasn't changed. You can allow Droprr later in its Settings.";
                Status.IsOpen = true;
                CancelButton.Content = "Close";
                CancelButton.IsEnabled = true;
                return;
            }
            Close();
        }
        catch (Exception ex)
        {
            Busy.Visibility = Visibility.Collapsed;
            Status.Severity = InfoBarSeverity.Error;
            Status.Title = "Couldn't install Droprr";
            Status.Message = ex.Message;
            Status.IsOpen = true;
            InstallButton.IsEnabled = CancelButton.IsEnabled = SignInBox.IsEnabled = FirewallBox.IsEnabled = true;
        }
    }
}
