using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Byway;

internal sealed record ProxySettings(uint Flags, string Server, string Bypass, string PacUrl)
{
    private const uint ProxyEnabled = 2;
    private const uint PacEnabled = 4;

    internal static ProxySettings ForByway(string endpoint, string bypass, CaptureMode capture = CaptureMode.SystemProxy) =>
        capture == CaptureMode.Tun ? new(1, "", "", "") : new(3, endpoint, bypass, "");

    internal bool MatchesActiveSettings(ProxySettings other) =>
        Flags == other.Flags &&
        ((Flags & ProxyEnabled) == 0 || Server == other.Server && Bypass == other.Bypass) &&
        ((Flags & PacEnabled) == 0 || PacUrl == other.PacUrl);
}

internal static partial class WinProxy
{
    private const uint PerConnection = 75;
    private const uint Flags = 1;
    private const uint FlagsUi = 10;
    private const uint Server = 2;
    private const uint Bypass = 3;
    private const uint PacUrl = 4;

    internal static unsafe ProxySettings Read()
    {
        Option* options = stackalloc Option[4] { new(FlagsUi), new(Server), new(Bypass), new(PacUrl) };
        var list = new OptionList(options);
        uint size = list.Size;
        try
        {
            if (InternetQueryOption(0, PerConnection, &list, &size))
                return new((uint)options[0].Value, ReadString(options[1]), ReadString(options[2]), ReadString(options[3]));
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法读取 Windows 系统代理。");
        }
        finally
        {
            for (int index = 1; index < 4; index++)
                if (options[index].Value != 0)
                    GlobalFree(options[index].Value);
        }
    }

    internal static unsafe void Write(ProxySettings settings)
    {
        using var policy = Registry.LocalMachine.OpenSubKey(@"Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings");
        if (policy?.GetValue("ProxySettingsPerUser") is 0)
            throw new InvalidOperationException("此 PC 使用统一的设备代理策略，Byway 需要当前用户的代理设置。");

        fixed (char* server = settings.Server, bypass = settings.Bypass, pac = settings.PacUrl)
        {
            Option* options = stackalloc Option[4]
            {
                new(Flags, (nint)settings.Flags), new(Server, (nint)server),
                new(Bypass, (nint)bypass), new(PacUrl, (nint)pac)
            };
            var list = new OptionList(options);
            if (!InternetSetOption(0, PerConnection, &list, list.Size))
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "无法设置 Windows 系统代理。");
        }
        InternetSetOption(0, 95, null, 0); // INTERNET_OPTION_PROXY_SETTINGS_CHANGED
        InternetSetOption(0, 39, null, 0); // INTERNET_OPTION_SETTINGS_CHANGED
        InternetSetOption(0, 37, null, 0); // INTERNET_OPTION_REFRESH
        if (Read() != settings)
            throw new InvalidOperationException("Windows 系统代理的回读结果与预期不同。");
    }

    private static string ReadString(Option option) => Marshal.PtrToStringUni(option.Value) ?? "";

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Option(uint id, nint value = 0)
    {
        internal readonly uint Id = id;
        internal readonly nint Value = value;
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct OptionList(Option* options)
    {
        internal uint Size = (uint)sizeof(OptionList);
        internal nint Connection;
        internal uint Count = 4;
        internal uint ErrorIndex;
        internal Option* Options = options;
    }

    [LibraryImport("wininet.dll", EntryPoint = "InternetQueryOptionW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool InternetQueryOption(nint handle, uint option, void* buffer, uint* size);

    [LibraryImport("wininet.dll", EntryPoint = "InternetSetOptionW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool InternetSetOption(nint handle, uint option, void* buffer, uint size);

    [LibraryImport("kernel32.dll")]
    private static partial nint GlobalFree(nint pointer);
}
