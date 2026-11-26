using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Windows;
using System.Windows.Controls;

namespace Byway;

public partial class MainWindow
{
    private bool privateRefreshing;
    private bool privateFormLoaded;
    private Guid? privateFormIdentity;
    private string? privateAuthUrl;
    private long privateLastRefresh;
    private string? lastPrivateProbeId;
    private string? lastPrivateProbe;

    private string SelectedRelayMode => PrivateProvider.SelectedIndex == 1 && PrivateRelayMode.SelectedIndex == 0
        ? PrivateNetworkInput.TailscaleDefault : PrivateNetworkInput.Strict;

    private static bool ExternalTailscaleRunning() =>
        NetworkInterface.GetAllNetworkInterfaces().Any(adapter =>
            adapter.OperationalStatus == OperationalStatus.Up &&
            (adapter.Name.Equals("Tailscale", StringComparison.OrdinalIgnoreCase) ||
             adapter.Description.Contains("Tailscale Tunnel", StringComparison.OrdinalIgnoreCase)));

    private async Task<PrivateNetworkStatus> ReadPrivateNetworkAsync(bool includeAuth = false)
    {
        var settings = profile.PrivateNetwork;
        if (settings is null)
            return new(null, false, null, L10n.Text("未配置"));
        if (!settings.Enabled)
            return new(settings.Input, false, null, L10n.Text("已暂停"));
        if (ExternalTailscaleRunning())
            return new(settings.Input, true, null, L10n.Text("Tailscale 客户端正在使用虚拟网卡"));
        if (active is not { Capture: CaptureMode.Tun, Running: true } core)
            return new(settings.Input, true, null, L10n.Text("等待全流量（TUN）"));
        try
        {
            var runtime = await core.PrivateNetworkAsync<PrivateNetworkRuntime>();
            if (!includeAuth)
                runtime = runtime with { AuthURL = null };
            string state = runtime.State switch
            {
                "NeedsLogin" => L10n.Text("等待登录"),
                "NeedsMachineAuth" => L10n.Text("等待管理员授权"),
                "RelayMismatch" => L10n.Text("中继清单不符，请检查协调服务"),
                "Running" when runtime.Relays?.Verified == true => L10n.Text("已连接"),
                "Stopped" => L10n.Text("已断开"),
                _ => L10n.Text("正在连接")
            };
            return new(settings.Input, true, runtime, state);
        }
        catch (Exception error) when (error is InvalidOperationException or System.Net.Http.HttpRequestException or IOException)
        {
            return new(settings.Input, true, null, L10n.Text("等待私网内核"));
        }
    }

    private async Task SavePrivateNetworkAsync(PrivateNetworkSettings? next, bool startIfReady = false)
    {
        var previous = profile.PrivateNetwork;
        if (next is not null && previous is not null && active is { Capture: CaptureMode.Tun, Running: true })
        {
            var status = await ReadPrivateNetworkAsync();
            if (status.Runtime is { } runtime)
            {
                next = next with
                {
                    LastAddresses = [.. (previous.LastAddresses ?? []).Concat(runtime.Peers.SelectMany(peer => peer.Addresses))
                        .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).Take(4096)],
                    LastDnsSuffix = runtime.DnsSuffix ?? previous.LastDnsSuffix
                };
            }
        }

        var proposed = profile with { PrivateNetwork = next };
        if (active is { Capture: CaptureMode.Tun } core)
        {
            if (next is null && selected is null && Options.RouteMode != RoutingMode.Direct)
            {
                await SetProxyEnabledAsync(false, probeConnectivity: false);
                proposed = profile with { PrivateNetwork = null };
                proposed.Save();
                profile = proposed;
            }
            else
            {
                await ActivateAsync(selected, core.Source ?? selected?.Node, proposed, probeConnectivity: false);
            }
        }
        else if (startIfReady && next?.Enabled == true && Options.Capture == CaptureMode.Tun && Program.IsElevated)
        {
            proposed = proposed with { Options = Options with { ProxyWanted = true } };
            await ActivateAsync(selected, selected?.Node, proposed, probeConnectivity: false);
        }
        else
        {
            proposed.Save();
            profile = proposed;
        }
        if (next is null && previous is not null)
        {
            string directory = PrivateNetworkSettings.DirectoryFor(previous.Identity);
            try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        await RefreshPrivatePageAsync();
    }

    private async Task ConfigurePrivateNetworkAsync(PrivateNetworkInput input)
    {
        input = input.Validate(Options.MixedPort);
        var current = profile.PrivateNetwork;
        if (current is not null &&
            (current.Input.Provider != input.Provider || current.Input.ControlURL != input.ControlURL))
            throw new InvalidOperationException(L10n.Text("请先退出当前私网，再更换协调服务器。"));
        if (current is not null && current.Input.Provider == input.Provider && current.Input.ControlURL == input.ControlURL &&
            current.Input.DeviceName == input.DeviceName && current.Input.RelayMode == input.RelayMode &&
            current.Input.RelayHosts.SequenceEqual(input.RelayHosts) &&
            (current.Input.InboundTcpPorts ?? []).SequenceEqual(input.InboundTcpPorts ?? []))
            return;
        await SavePrivateNetworkAsync(current is null ? new(Guid.NewGuid(), input, false) : current with { Input = input });
        privateFormLoaded = false;
    }

    private Task SetPrivateNetworkAsync(bool enabled)
    {
        var current = profile.PrivateNetwork ?? throw new InvalidOperationException(L10n.Text("请先配置私网。"));
        if (enabled && ExternalTailscaleRunning())
            throw new InvalidOperationException(L10n.Text("请先断开系统中的 Tailscale 客户端，再在 Byway 加入私网。"));
        if (current.Enabled == enabled && active is { Capture: CaptureMode.Tun, Running: true })
            return Task.CompletedTask;
        return SavePrivateNetworkAsync(current with { Enabled = enabled }, startIfReady: enabled);
    }

    private async Task RefreshPrivatePageAsync()
    {
        if (privateRefreshing || PrivateNetworkPage is null || PrivateNetworkPage.Visibility != Visibility.Visible)
            return;
        privateRefreshing = true;
        privateLastRefresh = Stopwatch.GetTimestamp();
        try
        {
            var identity = profile.PrivateNetwork?.Identity;
            if (!privateFormLoaded || privateFormIdentity != identity)
            {
                ReadPrivateForm();
                if (privateFormIdentity != identity || identity is null)
                    PrivateSettings.IsExpanded = identity is null;
                privateFormLoaded = true;
                privateFormIdentity = identity;
            }
            var current = await ReadPrivateNetworkAsync(includeAuth: true);
            if (identity != profile.PrivateNetwork?.Identity)
                return;
            var runtime = current.Runtime;
            PrivateStatus.Text = runtime?.Network is { Length: > 0 } name ? $"{current.State} · {name}" : current.State;
            PrivateAddress.Text = runtime?.Addresses is { Length: > 0 } addresses ? string.Join("  ", addresses) : "";
            PrivateToggle.Content = current.Configuration is null ? L10n.Text("加入私网") : current.Enabled ? L10n.Text("暂停私网") : L10n.Text("恢复私网");
            PrivateTun.Visibility = current.Enabled && active?.Capture != CaptureMode.Tun ? Visibility.Visible : Visibility.Collapsed;
            PrivateLeave.Visibility = current.Configuration is null ? Visibility.Collapsed : Visibility.Visible;
            privateAuthUrl = runtime?.AuthURL;
            PrivateAuthorize.Visibility = AuthorizedLogin(privateAuthUrl) is not null ? Visibility.Visible : Visibility.Collapsed;
            PrivateKeyForm.Visibility = runtime?.State == "NeedsLogin" ? Visibility.Visible : Visibility.Collapsed;
            var relay = runtime?.Relays;
            PrivateRelayAudit.Visibility = relay is null ? Visibility.Collapsed : Visibility.Visible;
            if (relay is not null)
            {
                bool mismatch = runtime?.State == "RelayMismatch";
                string title = L10n.Format($"实际下发的中继（{relay.Hosts.Length} 个）");
                if (mismatch)
                    title += L10n.Text(" · 清单不符");
                string hosts = relay.Hosts.Length == 0 ? L10n.Text("无") : string.Join(", ", relay.Hosts);
                if (mismatch && (PrivateRelayAudit.Header as string != title || PrivateActualRelays.Text != hosts))
                    PrivateRelayAudit.IsExpanded = true;
                PrivateRelayAudit.Header = title;
                PrivateActualRelays.Text = hosts;
            }
            var rows = runtime?.Peers ?? [];
            if (PrivatePeers.ItemsSource is not PrivateNetworkPeer[] previous || !SamePeers(previous, rows))
            {
                string? selectedPeer = (PrivatePeers.SelectedItem as PrivateNetworkPeer)?.Id;
                PrivatePeers.ItemsSource = rows;
                PrivatePeers.SelectedItem = rows.FirstOrDefault(row => row.Id == selectedPeer);
            }
        }
        finally { privateRefreshing = false; }

        static bool SamePeers(PrivateNetworkPeer[] previous, PrivateNetworkPeer[] next) =>
            previous.Length == next.Length && previous.Zip(next).All(pair =>
                pair.First.Id == pair.Second.Id && pair.First.Name == pair.Second.Name &&
                pair.First.Online == pair.Second.Online && pair.First.DnsName == pair.Second.DnsName &&
                pair.First.Addresses.SequenceEqual(pair.Second.Addresses));
    }

    private void RefreshPrivatePageOnTimer()
    {
        if (!busy && Stopwatch.GetElapsedTime(privateLastRefresh) >= TimeSpan.FromSeconds(2))
            _ = RefreshPrivatePageAsync();
    }

    private void ReadPrivateForm()
    {
        var settings = profile.PrivateNetwork?.Input;
        PrivateProvider.SelectedIndex = settings?.Provider == "tailscale" ? 1 : 0;
        PrivateProvider.IsEnabled = settings is null;
        PrivateControl.IsReadOnly = settings is not null;
        PrivateControl.Text = settings?.ControlURL ?? "";
        PrivateName.Text = settings?.DeviceName ?? "";
        PrivateRelays.Text = string.Join(", ", settings?.RelayHosts ?? []);
        PrivateInboundPorts.Text = string.Join(", ", settings?.InboundTcpPorts ?? []);
        PrivateRelayMode.SelectedIndex = settings?.Provider == "tailscale" && settings.RelayMode == PrivateNetworkInput.Strict ? 1 : 0;
        UpdatePrivateRelayForm();
    }

    private void PrivateProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PrivateControl is null || PrivateControlLabel is null)
            return;
        PrivateControl.Visibility = PrivateControlLabel.Visibility = PrivateProvider.SelectedIndex == 0
            ? Visibility.Visible : Visibility.Collapsed;
        UpdatePrivateRelayForm();
    }

    private void PrivateRelayModeChanged(object sender, SelectionChangedEventArgs e) => UpdatePrivateRelayForm();

    private void UpdatePrivateRelayForm()
    {
        if (PrivateRelayModeForm is null || PrivateRelayMode is null || PrivateStrictRelays is null || PrivateRelayHelp is null)
            return;
        PrivateRelayModeForm.Visibility = PrivateProvider.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        bool strict = SelectedRelayMode == PrivateNetworkInput.Strict;
        PrivateStrictRelays.Visibility = strict ? Visibility.Visible : Visibility.Collapsed;
        PrivateRelayHelp.Text = strict ? L10n.Text("填写协调服务应下发的中继域名，多个域名用逗号分隔。")
            : L10n.Text("授权后使用 Tailscale 下发的中继。");
    }

    private async void PrivateToggleClick(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        if (profile.PrivateNetwork is null)
        {
            PrivateSettings.IsExpanded = true;
            if (PrivateProvider.SelectedIndex == 0) PrivateControl.Focus();
            else PrivateRelayMode.Focus();
            return;
        }
        await SetPrivateNetworkAsync(!profile.PrivateNetwork.Enabled);
        await RefreshPrivatePageAsync();
    });

    private async void PrivateSaveClick(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        var ports = Split(PrivateInboundPorts.Text).Select(value => int.TryParse(value, out int port)
            ? port : throw new InvalidDataException(L10n.Text("端口请用逗号分隔的数字。"))).ToArray();
        bool initial = profile.PrivateNetwork is null;
        string mode = SelectedRelayMode;
        await ConfigurePrivateNetworkAsync(new(PrivateProvider.SelectedIndex == 1 ? "tailscale" : "headscale",
            PrivateControl.Text, mode == PrivateNetworkInput.Strict ? Split(PrivateRelays.Text) : [], PrivateName.Text, ports, mode));
        if (initial)
            await SetPrivateNetworkAsync(true);
        await RefreshPrivatePageAsync();
    });

    private static string[] Split(string text) =>
        text.Split([',', '，', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private async void PrivateTunClick(object sender, RoutedEventArgs e)
    {
        if (!Program.IsElevated)
        {
            if (System.Windows.MessageBox.Show(this, L10n.Text("以管理员身份重启 Byway 以启用全流量？"), L10n.Text("私网"),
                MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
                ElevateForTunClick(sender, e);
            return;
        }
        await RunAsync(async () =>
        {
            var next = profile with { Options = Options with { Capture = CaptureMode.Tun, ProxyWanted = true } };
            await ActivateAsync(selected, selected?.Node, next, probeConnectivity: false);
            SyncProxyControls();
            await RefreshPrivatePageAsync();
        });
    }

    private static Uri? AuthorizedLogin(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var url) && url.Scheme == "https" && url.UserInfo.Length == 0 ? url : null;

    private void PrivateAuthorizeClick(object sender, RoutedEventArgs e)
    {
        if (AuthorizedLogin(privateAuthUrl) is { } url)
            try { Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
            catch (Exception error) { ShowError(error.Message); }
    }

    private async void PrivateKeyClick(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        string key = PrivateKey.Password.Trim();
        PrivateKey.Clear();
        await ApplyPrivateKeyAsync(key);
        await RefreshPrivatePageAsync();
    });

    private async Task ApplyPrivateKeyAsync(string? key)
    {
        if (string.IsNullOrEmpty(key) || key.Length > 4096)
            throw new InvalidDataException(L10n.Text("请填写有效的入网密钥。"));
        if (active is not { Capture: CaptureMode.Tun } core || profile.PrivateNetwork?.Enabled != true)
            throw new InvalidOperationException(L10n.Text("请先启动私网。"));
        _ = await core.PrivateNetworkAsync<System.Text.Json.JsonElement>("join", key);
    }

    private async void PrivateRefreshClick(object sender, RoutedEventArgs e) => await RefreshPrivatePageAsync();

    private async void PrivateLeaveClick(object sender, RoutedEventArgs e)
    {
        if (System.Windows.MessageBox.Show(this, L10n.Text("这台设备再次加入时需要重新授权。"), L10n.Text("退出私网"),
            MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
            await RunAsync(() => SavePrivateNetworkAsync(null));
    }

    private void PrivatePeerChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PrivatePeerName is null)
            return;
        var peer = PrivatePeers.SelectedItem as PrivateNetworkPeer;
        PrivatePeerName.Text = peer?.Name ?? L10n.Text("选择设备");
        PrivatePeerAddress.Text = peer is null ? "" : string.Join(Environment.NewLine,
            peer.Addresses.Append(peer.DnsName).Where(value => value.Length != 0));
        PrivateProbe.IsEnabled = PrivateCopy.IsEnabled = peer?.Addresses.Length > 0;
        PrivateProbeResult.Text = peer?.Id == lastPrivateProbeId ? lastPrivateProbe ?? "" : "";
    }

    private async Task<PrivateNetworkProbe> ProbePrivateNetworkAsync(string? address)
    {
        if (address is null || address.Length > 64 || !System.Net.IPAddress.TryParse(address, out _))
            throw new InvalidDataException(L10n.Text("请提供有效的私网地址。"));
        if (active is not { Capture: CaptureMode.Tun } core || profile.PrivateNetwork?.Enabled != true)
            throw new InvalidOperationException(L10n.Text("私网未连接。"));
        return await core.PrivateNetworkAsync<PrivateNetworkProbe>("probe", address);
    }

    private async void PrivateProbeClick(object sender, RoutedEventArgs e)
    {
        if (PrivatePeers.SelectedItem is not PrivateNetworkPeer { Addresses.Length: > 0 } peer)
            return;
        await RunAsync(async () =>
        {
            var probe = await ProbePrivateNetworkAsync(peer.Addresses[0]);
            string path = probe.Path switch
            {
                "direct" => L10n.Text("直连"),
                "derp" => string.IsNullOrEmpty(probe.Region) ? L10n.Text("中继") : L10n.Format($"中继 {probe.Region}"),
                "peerRelay" => L10n.Text("设备中继"),
                _ => L10n.Text("路径未知")
            };
            lastPrivateProbeId = peer.Id;
            lastPrivateProbe = $"{path} · {probe.LatencyMs:F0} ms";
            if ((PrivatePeers.SelectedItem as PrivateNetworkPeer)?.Id == peer.Id)
                PrivateProbeResult.Text = lastPrivateProbe;
        });
    }

    private void PrivateCopyClick(object sender, RoutedEventArgs e)
    {
        if (PrivatePeers.SelectedItem is PrivateNetworkPeer { Addresses.Length: > 0 } peer)
            System.Windows.Clipboard.SetText(peer.Addresses[0]);
    }
}
