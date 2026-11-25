using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Byway;

internal sealed record DeviceInfo(Guid Id, string DisplayName, string Type,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ModelIdentifier,
    string OsVersion, string AppVersion)
{
    internal string ShortCode => Id.ToString("N")[..8].ToUpperInvariant();
}

internal sealed record DeviceNameInput(string? DisplayName);

internal sealed class DeviceIdentityStore(
    string path, string type, string defaultName, string? modelIdentifier, string appVersion)
{
    private sealed record Settings(Guid Id, string? DisplayName = null);
    private readonly object gate = new();

    internal DeviceInfo Read()
    {
        lock (gate)
            return Describe(ReadOrCreate());
    }

    internal DeviceInfo Rename(string value)
    {
        string name = value.Trim();
        int length = name.EnumerateRunes().Count();
        if (length is < 1 or > 80 || name.EnumerateRunes().Any(rune =>
            Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator))
            throw new ArgumentException("设备名称需要 1 至 80 个字符，且不能包含换行或控制字符。", nameof(value));

        lock (gate)
        {
            var saved = ReadOrCreate();
            if (saved.DisplayName != name)
            {
                saved = saved with { DisplayName = name };
                Write(saved, overwrite: true);
            }
            return Describe(saved);
        }
    }

    private DeviceInfo Describe(Settings saved) => new(saved.Id,
        saved.DisplayName ?? $"{defaultName}-{saved.Id.ToString("N")[..8].ToUpperInvariant()}",
        type, modelIdentifier, Environment.OSVersion.Version.ToString(), appVersion);

    private Settings ReadOrCreate()
    {
        try { return ReadSaved(); }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }

        var created = new Settings(Guid.NewGuid());
        try { Write(created, overwrite: false); }
        catch (IOException) when (File.Exists(path)) { return ReadSaved(); }
        return created;
    }

    private Settings ReadSaved()
    {
        var saved = JsonSerializer.Deserialize<Settings>(File.ReadAllBytes(path));
        return saved is not null && saved.Id != Guid.Empty ? saved :
            throw new InvalidDataException("无法读取已保存的设备身份。");
    }

    private void Write(Settings saved, bool overwrite)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(saved));
            File.Move(temporary, path, overwrite);
        }
        finally
        {
            File.Delete(temporary);
        }
    }
}
