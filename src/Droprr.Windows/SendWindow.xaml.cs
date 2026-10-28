using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows;
using Microsoft.Win32;

namespace Droprr;

public sealed record FileEntry(string FullPath)
{
    public string Name => Path.GetFileName(FullPath);
}

public partial class SendWindow : Window
{
    readonly AppSettings _settings;
    readonly ObservableCollection<FileEntry> _files = new();

    public SendWindow(AppSettings settings, IEnumerable<string> files)
    {
        InitializeComponent();
        Icon = AppIcon.CreateImageSource();
        _settings = settings;

        FileList.ItemsSource = _files;
        _files.CollectionChanged += (_, _) => DropHint.Visibility = _files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        AddPaths(files);

        PeerBox.ItemsSource = settings.Peers;
        if (settings.Peers.Count > 0)
            PeerBox.SelectedIndex = 0;
        else
            Status.Text = "No devices yet. Add peers to settings.json (tray menu > Edit settings).";
    }

    void AddPaths(IEnumerable<string> paths)
    {
        var skippedFolders = false;
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
                skippedFolders = true;
            else if (File.Exists(path) && _files.All(f => f.FullPath != path))
                _files.Add(new FileEntry(path));
        }
        if (skippedFolders)
            Status.Text = "Folders aren't supported yet, so they were skipped.";
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths)
            AddPaths(paths);
        else if (e.Data.GetData(DataFormats.UnicodeText) is string text)
            MessageText.Text = text;
        e.Handled = true;
    }

    void OnAddFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Multiselect = true, Title = "Choose files to send" };
        if (dialog.ShowDialog(this) == true)
            AddPaths(dialog.FileNames);
    }

    void OnClearFiles(object sender, RoutedEventArgs e) => _files.Clear();

    void OnPaste(object sender, RoutedEventArgs e)
    {
        if (Clipboard.ContainsFileDropList())
            AddPaths(Clipboard.GetFileDropList().Cast<string>());
        else if (Clipboard.ContainsText())
            MessageText.Text = Clipboard.GetText();
    }

    async void OnSend(object sender, RoutedEventArgs e)
    {
        if (PeerBox.SelectedItem is not Peer peer)
        {
            Status.Text = "Pick a device first.";
            return;
        }
        var text = MessageText.Text.Trim();
        if (_files.Count == 0 && text.Length == 0)
        {
            Status.Text = "Add files or type some text first.";
            return;
        }

        var token = string.IsNullOrEmpty(peer.Token) ? _settings.Token : peer.Token;
        SendButton.IsEnabled = false;
        Status.Text = $"Sending to {peer.Name}…";
        try
        {
            if (_files.Count > 0)
                await Sender.SendFilesAsync(peer, token, _files.Select(f => f.FullPath).ToList());
            if (text.Length > 0)
                await Sender.SendTextAsync(peer, token, text);
            Status.Text = $"Sent to {peer.Name}.";
            _files.Clear();
            MessageText.Clear();
        }
        catch (Exception ex)
        {
            Status.Text = $"Couldn't send to {peer.Name}: {ex.Message}";
        }
        finally
        {
            SendButton.IsEnabled = true;
        }
    }
}
