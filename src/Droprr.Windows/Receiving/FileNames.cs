using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace Droprr;

static class FileNames
{
    const int MaxLength = 150;

    static readonly HashSet<string> ReservedNames = new(
        new[] { "CON", "PRN", "AUX", "NUL" }
            .Concat(Enumerable.Range(1, 9).SelectMany(i => new[] { $"COM{i}", $"LPT{i}" })),
        StringComparer.OrdinalIgnoreCase);

    // Turns a name chosen by the sender into a safe file name inside the save folder (no paths, no device names).
    public static string Sanitize(string? name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var builder = new StringBuilder();
        foreach (var c in Path.GetFileName(name ?? ""))
        {
            // Bidirectional overrides would let "gpj.exe" display as "exe.jpg"; drop them.
            if (IsHidden(c))
                continue;
            builder.Append(invalid.Contains(c) ? '_' : c);
        }

        var clean = builder.ToString().Trim().TrimEnd('.', ' ');
        if (clean.Trim('.').Length == 0)
            clean = $"File {DateTime.Now:yyyy-MM-dd HHmmss}";
        if (ReservedNames.Contains(Path.GetFileNameWithoutExtension(clean)))
            clean = "_" + clean;
        if (clean.Length > MaxLength)
        {
            var extension = Path.GetExtension(clean);
            if (extension.Length > 20)
                extension = "";
            clean = clean[..(MaxLength - extension.Length)] + extension;
        }
        return clean;
    }

    // Control characters and the invisible formatting characters that change how text is displayed (bidirectional
    // overrides and isolates, zero-width characters).
    static bool IsHidden(char c) =>
        char.IsControl(c) || c is >= '​' and <= '‏' or >= '‪' and <= '‮' or >= '⁦' and <= '⁩' or '﻿';

    // Text from another device (such as its name), made safe to show and log: one line, without hidden
    // characters, at most `max` characters.
    public static string Printable(string text, int max)
    {
        var clean = new string(text.Where(c => !IsHidden(c)).ToArray()).Trim();
        return clean.Length > max ? clean[..max].TrimEnd() : clean;
    }

    // A device name from the network, made safe to show and log: Printable, at most 64 characters.
    public static string DeviceName(string? name) => Printable(name ?? "", 64);

    // Opens a new file, adding " (1)", " (2)", and so on instead of overwriting an existing one.
    public static (FileStream Stream, string Path) CreateUnique(string folder, string? name)
    {
        var clean = Sanitize(name);
        var stem = Path.GetFileNameWithoutExtension(clean);
        var extension = Path.GetExtension(clean);
        for (var i = 0; ; i++)
        {
            var path = Path.Combine(folder, i == 0 ? clean : $"{stem} ({i}){extension}");
            try
            {
                return (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true), path);
            }
            catch (IOException) when (File.Exists(path) && i < 10_000)
            {
            }
        }
    }
}
