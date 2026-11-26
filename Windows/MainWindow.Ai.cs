using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Threading;

namespace Byway;

public partial class MainWindow
{
    private static readonly Lazy<string> AiGuide = new(() => ReadAiResource("Byway.AI-GUIDE.md"));
    private static readonly Lazy<string> AiSkill = new(() => ReadAiResource("Byway.AI-SKILL.md"));

    private static string ReadAiResource(string name)
    {
        using var reader = new StreamReader(typeof(MainWindow).Assembly.GetManifestResourceStream(name)!);
        return reader.ReadToEnd();
    }
    private readonly Lazy<DeviceIdentityStore> deviceIdentity = new(() =>
        new(Program.StatePath("device-identity.json"), "windows", "Windows", WindowsModel(),
            typeof(MainWindow).Assembly.GetName().Version!.ToString(3)));
    private static string? WindowsModel()
    {
        try
        {
            return (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName", null)
                as string)?.Trim();
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            return null;
        }
    }

    private DeviceInfo? TryReadDevice()
    {
        try { return deviceIdentity.Value.Read(); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private DeviceInfo RenameDevice(string name)
    {
        try
        {
            var device = deviceIdentity.Value.Rename(name);
            RefreshDeviceDisplay(device);
            return device;
        }
        catch (ArgumentException error) { throw new ApiError(422, error.Message); }
    }

    private void RefreshDeviceDisplay(DeviceInfo? device)
    {
        AiDeviceName.Text = device?.DisplayName ?? L10n.Text("无法读取设备身份");
        AiDeviceCode.Text = device is null ? "" : L10n.Format($"识别码  {device.ShortCode}");
        AiRenameDevice.IsEnabled = device is not null;
    }

    private void EditDeviceNameClick(object sender, RoutedEventArgs e)
    {
        if (TryReadDevice() is not { } device)
            return;
        AiDeviceNameInput.Text = device.DisplayName;
        AiDeviceNameEditor.Visibility = Visibility.Visible;
        AiRenameDevice.Visibility = Visibility.Collapsed;
        AiDeviceNameInput.Focus();
        AiDeviceNameInput.SelectAll();
    }

    private void CancelDeviceNameClick(object sender, RoutedEventArgs e) => CloseDeviceNameEditor();

    private void SaveDeviceNameClick(object sender, RoutedEventArgs e)
    {
        try
        {
            RenameDevice(AiDeviceNameInput.Text);
            CloseDeviceNameEditor();
            AiDeviceFeedback.Text = L10n.Text("设备名称已保存。");
        }
        catch (Exception error)
        {
            AiDeviceFeedback.Text = error.Message;
        }
    }

    private void CloseDeviceNameEditor()
    {
        AiDeviceNameEditor.Visibility = Visibility.Collapsed;
        AiRenameDevice.Visibility = Visibility.Visible;
        AiDeviceFeedback.Text = "";
        AiRenameDevice.Focus();
    }

    private AiServer? aiServer;
    private readonly AiCallLog aiCalls = new();
    private AiLogWindow? aiLogWindow;
    private bool startingAi;
    private bool LanActive => profile.Ai?.LanEnabled == true && aiServer?.LanReady == true;
    private readonly DispatcherTimer aiAddressTimer = new() { Interval = TimeSpan.FromSeconds(5) };

    private void InitializeAi()
    {
        Loaded += async (_, _) =>
        {
            if (aiServer is null)
                await StartAiAsync();
        };
        aiAddressTimer.Tick += (_, _) =>
        {
            RefreshDiscovery();
            if (AiPage.IsVisible)
                RefreshAiPage();
        };
        aiAddressTimer.Start();
    }

    private async Task StartAiAsync()
    {
        if (startingAi)
            return;

        startingAi = true;
        RefreshAiPage();
        try
        {
            if (profile.Ai is null)
                SaveAiOptions(new(AiOptions.NewToken()));
            aiServer ??= new(DispatchApiAsync, profile.Ai!.Token, aiCalls);
            await aiServer.StartLocalAsync();
            AiFeedback.Text = "";
            if (profile.Ai!.LanEnabled)
            {
                if (LanFirewall.IsAuthorized())
                    await aiServer.SetLanAsync(true);
                else
                    AiFeedback.Text = L10n.Text("当前版本需要 Windows 防火墙授权。打开局域网控制以继续。");
            }
        }
        catch (Exception)
        {
            AiFeedback.Text = aiServer?.LocalReady == true
                ? L10n.Text("局域网 API 启动失败。请检查 Windows 防火墙和端口 8767，再打开局域网控制。")
                : L10n.Text("本机 API 启动失败。请检查端口 8766，再重试。");
        }
        finally
        {
            startingAi = false;
            RefreshAiPage();
        }
    }

    private void SaveAiOptions(AiOptions settings)
    {
        var next = profile with { Ai = settings };
        next.Save();
        profile = next;
    }

    private async Task ChangeLanAsync(bool enabled, bool interactive = false)
    {
        var server = aiServer ?? throw new InvalidOperationException(L10n.Text("API 还未启动。"));
        var settings = profile.Ai!;
        if (enabled)
        {
            await LanFirewall.EnsureAuthorizedAsync(interactive);
            await server.SetLanAsync(true);
            try
            {
                if (!settings.LanEnabled)
                    SaveAiOptions(settings with { LanEnabled = true });
            }
            catch { await server.SetLanAsync(false); throw; }
        }
        else
        {
            if (settings.LanEnabled)
                SaveAiOptions(settings with { LanEnabled = false });
            await server.SetLanAsync(false);
        }
        RefreshAiPage();
    }

    private void RefreshAiPage()
    {
        RefreshDeviceDisplay(TryReadDevice());
        RefreshDiscovery();
        bool localReady = aiServer?.LocalReady == true;
        bool lanEnabled = LanActive;
        var (hostAddress, addresses) = AiLanConnection();
        string[] displayedAddresses = hostAddress is null ? addresses : [$"mDNS   {hostAddress}", .. addresses];
        AiLocalAddress.Text = localReady ? L10n.Format($"本机 API   {AiServer.LocalAddress}") : startingAi ? L10n.Text("正在启动本机 API…") : L10n.Text("本机 API 未启动");
        AiLanToggle.IsChecked = lanEnabled;
        AiLanToggle.IsEnabled = localReady && !busy && !startingAi;
        AiLanAddress.Text = lanEnabled ? displayedAddresses.Length == 0 ? L10n.Text("等待局域网地址。") : string.Join(Environment.NewLine, displayedAddresses)
            : L10n.Text("局域网已关闭。");
        AiCopyConnection.IsEnabled = localReady;
        string? webAddress = ManagementAddress();
        AiWebAddress.Text = webAddress ?? (lanEnabled ? L10n.Text("等待局域网 IP 地址。") : L10n.Text("管理网页未就绪。"));
        AiOpenWeb.IsEnabled = AiCopyWeb.IsEnabled = webAddress is not null;
        var discovery = DiscoveryState();
        AiDiscoveryToggle.IsChecked = discovery.Enabled;
        AiDiscoveryToggle.IsEnabled = lanEnabled && !busy;
        AiDiscoveryStatus.Text = !lanEnabled || !discovery.Enabled ? "" : discovery.Status switch
        {
            "published" => L10n.Text("已发布 mDNS 地址。"),
            "unavailable" => L10n.Text("mDNS 不可用，使用 IP 地址。"),
            _ => L10n.Text("正在发布 mDNS 地址。")
        };
        AiCopyWebIp.Visibility = discovery.MdnsUrl is not null && discovery.IpUrl is not null
            ? Visibility.Visible : Visibility.Collapsed;
        AiRetry.Visibility = !startingAi && !localReady ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshDiscovery()
    {
        bool enabled = profile.Ai?.DiscoveryEnabled ?? true;
        aiServer?.UpdateDiscovery(enabled, enabled && LanActive ? TryReadDevice()?.Id : null);
    }

    private DiscoveryState DiscoveryState() => aiServer?.Discovery ?? new(profile.Ai?.DiscoveryEnabled ?? true, "waiting");

    private DiscoveryState SetDiscoveryEnabled(bool enabled)
    {
        if (profile.Ai is not { } settings)
            throw new ApiError(503, L10n.Text("本机 API 尚未就绪。"));
        if (settings.DiscoveryEnabled != enabled)
            SaveAiOptions(settings with { DiscoveryEnabled = enabled });
        RefreshAiPage();
        return DiscoveryState();
    }

    private void ChangeDiscoveryClick(object sender, RoutedEventArgs e)
    {
        try { SetDiscoveryEnabled(AiDiscoveryToggle.IsChecked == true); }
        catch (Exception error) { AiFeedback.Text = error.Message; RefreshAiPage(); }
    }

    private string? ManagementAddress() => LanActive
        ? DiscoveryState().PreferredUrl ?? AiServer.LanAddresses().FirstOrDefault()
        : aiServer?.LocalReady == true ? AiServer.LocalAddress : null;

    private void OpenManagementClick(object sender, RoutedEventArgs e)
    {
        if (ManagementAddress() is not { } address) return;
        try { Process.Start(new ProcessStartInfo(address.TrimEnd('/') + "/") { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { AiFeedback.Text = L10n.Text("无法打开默认浏览器。"); }
    }

    private void CopyManagementClick(object sender, RoutedEventArgs e)
    {
        if (ManagementAddress() is { } address) CopyManagementAddress(address);
    }

    private void CopyManagementIpClick(object sender, RoutedEventArgs e)
    {
        if (DiscoveryState().IpUrl is { } address) CopyManagementAddress(address);
    }

    private void CopyManagementAddress(string address)
    {
        try { System.Windows.Clipboard.SetText(address.TrimEnd('/') + "/"); AiFeedback.Text = L10n.Text("网页链接已复制。"); }
        catch (ExternalException) { AiFeedback.Text = L10n.Text("无法写入剪贴板，请重试。"); }
    }

    private (string? HostAddress, string[] Addresses) AiLanConnection()
    {
        var addresses = LanActive ? AiServer.LanAddresses() : [];
        return (LanActive ? DiscoveryState().MdnsUrl?.TrimEnd('/') : null, addresses);
    }

    private async void AiLanChanged(object sender, RoutedEventArgs e)
    {
        bool enable = AiLanToggle.IsChecked == true;
        if (!IsLoaded || busy || startingAi || enable == LanActive)
            return;
        try
        {
            AiFeedback.Text = enable ? L10n.Text("正在开启局域网控制…") : L10n.Text("正在关闭局域网控制…");
            await RunExclusiveAsync(async () => { await ChangeLanAsync(enable, interactive: true); return true; });
            AiFeedback.Text = enable ? L10n.Text("局域网控制已开启。") : L10n.Text("局域网控制已关闭。");
        }
        catch (Exception error)
        {
            AiFeedback.Text = error.Message;
        }
        finally { RefreshAiPage(); }
    }

    private async void RetryAiClick(object sender, RoutedEventArgs e) => await StartAiAsync();

    private string ReplaceAiToken()
    {
        string token = AiOptions.NewToken();
        SaveAiOptions(profile.Ai! with { Token = token });
        aiServer!.Token = token;
        return token;
    }

    private async void RotateAiTokenClick(object sender, RoutedEventArgs e)
    {
        if (profile.Ai is null || aiServer is null || busy)
            return;
        if (MessageBox.Show(this, L10n.Text("更换后，已有 AI 连接需要更新令牌。"), L10n.Text("更换访问令牌"),
            MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        await RunAsync(() =>
        {
            ReplaceAiToken();
            AiFeedback.Text = L10n.Text("访问令牌已更换。请重新复制 AI 接入指令。");
            return Task.CompletedTask;
        });
    }

    private void CopyAiConnectionClick(object sender, RoutedEventArgs e)
    {
        if (aiServer is null)
            return;
        var (hostAddress, addresses) = AiLanConnection();
        string address = hostAddress ?? addresses.FirstOrDefault() ?? AiServer.LocalAddress;
        string fallback = hostAddress is null ? "" : L10n.Format($" 若 .local 无法解析，改用 {string.Join(L10n.Text(" 或 "), addresses)}。");
        string text = L10n.Format($"连接 Byway。绕过 HTTP 代理，直接 GET {address}/v1/guide，按指南安装可复用的 skill。{fallback}\nAuthorization: Bearer {aiServer.Token}");
        try { System.Windows.Clipboard.SetText(text); AiFeedback.Text = L10n.Text("已复制 AI 接入指令。"); }
        catch (ExternalException) { AiFeedback.Text = L10n.Text("无法写入剪贴板，请重试。"); }
    }

    private void ShowAiLogClick(object sender, RoutedEventArgs e)
    {
        if (aiLogWindow is { } showing)
        {
            showing.Activate();
            return;
        }
        aiLogWindow = new(this, aiCalls);
        aiLogWindow.Closed += (_, _) => aiLogWindow = null;
        aiLogWindow.Show();
    }
}
