using System.Globalization;
using System.IO;
using System.Text.Json;

namespace Byway;

internal static class L10n
{
    internal static string Language { get; } = SelectLanguage();
    private static readonly Dictionary<string, string> translations = Load(Language);
    private static readonly Dictionary<string, string> english = Language is "en" or "zh-Hans" ? translations : Load("en");

    internal static string Text(string source) =>
        translations.GetValueOrDefault(source) ?? english.GetValueOrDefault(source) ?? source;

    internal static string Format(FormattableString source) =>
        string.Format(CultureInfo.CurrentCulture, Text(source.Format), source.GetArguments());

    private static string SelectLanguage()
    {
        // A self-contained Linux build can run with invariant .NET globalization.
        string locale = OperatingSystem.IsLinux()
            ? new[] { "LC_ALL", "LC_MESSAGES", "LANG" }
                .Select(Environment.GetEnvironmentVariable)
                .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? CultureInfo.CurrentUICulture.Name
            : CultureInfo.CurrentUICulture.Name;
        string tag = locale.Split('-', '_', '.', '@')[0].ToLowerInvariant();
        return tag switch { "zh" => "zh-Hans", "es" => "es", _ => "en" };
    }

    private static Dictionary<string, string> Load(string language)
    {
        using Stream? stream = typeof(L10n).Assembly.GetManifestResourceStream($"Byway.Localization.byway-{language}.json");
        return stream is null ? [] : JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? [];
    }
}
