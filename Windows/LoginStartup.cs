using Microsoft.Win32;

namespace Byway;

internal static class LoginStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Byway";
    private static string Command => $"\"{Environment.ProcessPath}\" --login";

    internal static bool IsRegistered
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return string.Equals(key?.GetValue(ValueName) as string, Command, StringComparison.OrdinalIgnoreCase);
        }
    }

    internal static void Apply(bool enabled, Action commit)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        string? previous = key.GetValue(ValueName) as string;
        if (previous is not null && !previous.EndsWith("\\Byway.exe\" --login", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(L10n.Text("Windows 中的 Byway 登录启动项由其他程序设置。"));
        try
        {
            Write(key, enabled ? Command : null);
            commit();
        }
        catch
        {
            Write(key, previous);
            throw;
        }
    }

    private static void Write(RegistryKey key, string? command)
    {
        if (command is null)
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        else
            key.SetValue(ValueName, command, RegistryValueKind.String);
    }
}
