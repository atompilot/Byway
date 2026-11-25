using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;

namespace Byway;

public partial class MainWindow
{
    private readonly DispatcherTimer trafficTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private TrafficSample? trafficBaseline;
    private TrafficSample? previousTraffic;
    private Task? pendingTrafficSample;
    private bool hasSessionTraffic;
    private TrafficStatusSnapshot trafficStats = new(null, null, null, null, null, "unavailable");
    private DesktopOptions Options => profile.Options ?? new();

    private void InitializeWorkspace()
    {
        ApplySidebarWidth();
        BypassInput.Text = Options.Bypass.Replace(";", Environment.NewLine);
        SyncProxyControls();
        CloseToTray.IsChecked = Options.CloseToTray;
        ReadStartupControls();
        VersionLabel.Text = $"版本 {typeof(MainWindow).Assembly.GetName().Version!.ToString(3)}";
        ShowRoutingConfigurations();
        InitializeTrafficHistory();
        trafficTimer.Tick += async (_, _) =>
        {
            await SampleTrafficAsync();
            if (StatsPage.IsVisible)
                RefreshTrafficHistory();
        };
        trafficTimer.Start();
        routingTimer.Tick += async (_, _) => await RefreshDueRoutingAsync();
        routingTimer.Start();
        ShowCurrentPage();
    }

    private double ClampSidebarWidth(double width) => Math.Clamp(width, SidebarColumn.MinWidth, SidebarColumn.MaxWidth);

    private void ApplySidebarWidth() => SidebarColumn.Width = new GridLength(ClampSidebarWidth(Options.SidebarWidth));

    private void SidebarDragCompleted(object sender, DragCompletedEventArgs e)
    {
        if (e.Canceled)
            ApplySidebarWidth();
        else
            SaveSidebarWidth();
    }

    private void SidebarResizeKeyUp(object sender, KeyEventArgs e)
    {
        if (e.Key is Key.Left or Key.Right)
            SaveSidebarWidth();
    }

    private void SaveSidebarWidth()
    {
        if (busy)
        {
            ApplySidebarWidth();
            return;
        }

        double width = SidebarColumn.Width.Value;
        if (width == Options.SidebarWidth)
            return;
        try { SaveOptions(Options with { SidebarWidth = width }); }
        catch (Exception error)
        {
            ApplySidebarWidth();
            ShowError(error.Message);
        }
    }

    private void NavigationChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AiPage is not null)
            ShowCurrentPage();
    }

    private void ShowCurrentPage()
    {
        NodesPage.Visibility = Navigation.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
        ConfigPage.Visibility = Navigation.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        PrivateNetworkPage.Visibility = Navigation.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
        StatsPage.Visibility = Navigation.SelectedIndex == 3 ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = Navigation.SelectedIndex == 4 ? Visibility.Visible : Visibility.Collapsed;
        AiPage.Visibility = Navigation.SelectedIndex == 5 ? Visibility.Visible : Visibility.Collapsed;
        if (Navigation.SelectedIndex == 2)
            _ = RefreshPrivatePageAsync();
        if (Navigation.SelectedIndex == 5)
            RefreshAiPage();
        if (Navigation.SelectedIndex == 3)
            RefreshTrafficHistory(force: true);
    }

    private void RefreshWorkspaceControls()
    {
        ConfigProxyStatus.Text = mixed is null
            ? $"127.0.0.1:{Options.MixedPort} · 代理已停用"
            : $"{CaptureName(active?.Capture ?? Options.Capture)} · {mixed.Endpoint} · " +
                (profile.ActiveRouting?.Name ?? "默认配置");
        SaveConfigButton.IsEnabled = ApplyProxyEndpoint.IsEnabled = !busy && !restorePending;
        RefreshRoutingControls();
        BypassInput.IsEnabled = MixedPortInput.IsEnabled = RoutingModeInput.IsEnabled = !busy;
        CaptureModeInput.IsEnabled = ElevateForTunButton.IsEnabled = !busy && !restorePending;
        CloseToTray.IsEnabled = !busy;
        StartAtLoginInput.IsEnabled = !busy;
        ResumeProxyInput.IsEnabled = !busy && Options.StartAtLogin;
        AiLanToggle.IsEnabled = aiServer?.LocalReady == true && !busy && !startingAi;
        PrivateNetworkPage.IsEnabled = !busy && !restorePending;
    }

    private async void SaveConfigClick(object sender, RoutedEventArgs e)
    {
        await RunAsync(async () =>
        {
            await ApplyProxyOptionsAsync(Options with { Bypass = BypassInput.Text });
            BypassInput.Text = Options.Bypass.Replace(";", Environment.NewLine);
            Status.Text = active?.Capture == CaptureMode.SystemProxy ? "系统代理例外已生效。" : "系统代理例外已保存。";
        });
    }

    private async void ApplyProxyEndpointClick(object sender, RoutedEventArgs e)
    {
        await RunAsync(async () =>
        {
            if (!int.TryParse(MixedPortInput.Text, out int port) || RoutingModeInput.SelectedIndex < 0 || CaptureModeInput.SelectedIndex < 0)
                throw new InvalidDataException("请输入本机混合端口并选择路由模式和接管方式。");
            var capture = (CaptureMode)CaptureModeInput.SelectedIndex;
            if (capture == CaptureMode.Tun && !Program.IsElevated)
                throw new InvalidDataException("请先以管理员身份重启 Byway，再应用全流量模式。");
            await ApplyProxyOptionsAsync(Options with { MixedPort = port, RouteMode = (RoutingMode)RoutingModeInput.SelectedIndex, Capture = capture });
            SyncProxyControls();
            Status.Text = active is null ? $"已保存 · {CaptureName(capture)}" : $"已应用 · {CaptureName(capture)} · {mixed!.Endpoint}";
        });
    }

    private async Task ApplyProxyOptionsAsync(DesktopOptions settings)
    {
        if (restorePending)
            throw new InvalidOperationException("请先恢复 Windows 系统代理。");
        var previous = Options;
        if (settings.MixedPort is < 1 or > 65535 or 8766 or 8767)
            throw new InvalidDataException("混合端口须在 1 至 65535 之间，8766 和 8767 供 Byway AI 使用。");
        settings = settings with { Bypass = NormalizeBypass(settings.Bypass) };
        var next = profile with { Options = settings };
        if (active is { } core && mixed is { } entry)
        {
            if (settings.MixedPort != previous.MixedPort || settings.RouteMode != previous.RouteMode || settings.Capture != previous.Capture)
            {
                await ActivateAsync(selected, core.Source ?? selected?.Node, next);
                return;
            }
            if (settings.Bypass != previous.Bypass && core.Capture == CaptureMode.SystemProxy)
            {
                ProxyLease.UpdateBypass(core, entry.Endpoint, previous.Bypass, settings.Bypass, next.Save);
                profile = next;
                return;
            }
        }
        next.Save();
        profile = next;
    }

    private void SyncProxyControls()
    {
        MixedPortInput.Text = Options.MixedPort.ToString(CultureInfo.InvariantCulture);
        CaptureModeInput.SelectedIndex = (int)Options.Capture;
        RoutingModeInput.SelectedIndex = (int)Options.RouteMode;
    }

    private static string CaptureName(CaptureMode capture) => capture switch
    {
        CaptureMode.Tun => "全流量（TUN）",
        CaptureMode.Manual => "仅监听（手动代理）",
        _ => "系统代理"
    };

    private void CaptureModeDraftChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TunHelp is null || ManualProxyHelp is null || ElevateForTunButton is null)
            return;
        bool tun = CaptureModeInput.SelectedIndex == (int)CaptureMode.Tun;
        TunHelp.Visibility = tun ? Visibility.Visible : Visibility.Collapsed;
        ManualProxyHelp.Visibility = CaptureModeInput.SelectedIndex == (int)CaptureMode.Manual ? Visibility.Visible : Visibility.Collapsed;
        ElevateForTunButton.Visibility = tun && !Program.IsElevated ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void ElevateForTunClick(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        var current = ProcessIdentity.Current();
        var start = new ProcessStartInfo(Environment.ProcessPath!) { Verb = "runas", UseShellExecute = true };
        start.ArgumentList.Add("--restart-elevated");
        start.ArgumentList.Add(current.Pid.ToString(CultureInfo.InvariantCulture));
        start.ArgumentList.Add(current.Started.ToString(CultureInfo.InvariantCulture));
        try
        {
            using var restarted = Process.Start(start) ?? throw new InvalidOperationException("无法以管理员身份启动 Byway。");
        }
        catch (System.ComponentModel.Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            Status.Text = "已取消管理员授权。";
            return;
        }
        await ExitAsync();
    });

    private async void StartupPreferenceChanged(object sender, RoutedEventArgs e)
    {
        await RunAsync(() =>
        {
            bool start = StartAtLoginInput.IsChecked == true;
            ApplyStartupOptions(Options with { StartAtLogin = start, ResumeProxy = start && ResumeProxyInput.IsChecked == true });
            Status.Text = "登录启动设置已保存。";
            return Task.CompletedTask;
        });
        ReadStartupControls();
    }

    private void ApplyStartupOptions(DesktopOptions options)
    {
        if (!options.StartAtLogin && options.ResumeProxy)
            throw new InvalidDataException("请先开启登录启动，再开启代理恢复。");
        if (options.StartAtLogin != Options.StartAtLogin || options.StartAtLogin && !LoginStartup.IsRegistered)
            LoginStartup.Apply(options.StartAtLogin, () => SaveOptions(options));
        else
            SaveOptions(options);
    }

    private void ReadStartupControls()
    {
        StartAtLoginInput.IsChecked = Options.StartAtLogin;
        ResumeProxyInput.IsChecked = Options.ResumeProxy;
        ResumeProxyInput.IsEnabled = Options.StartAtLogin;
        CloseToTray.IsChecked = Options.CloseToTray;
    }

    private static string NormalizeBypass(string value)
    {
        string[] entries = value.Split(['\r', '\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (string entry in entries)
        {
            if (!string.Equals(entry, "<local>", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(entry, "<-loopback>", StringComparison.OrdinalIgnoreCase) &&
                Uri.CheckHostName(entry.Replace('*', 'x')) == UriHostNameType.Unknown)
                throw new InvalidDataException($"无法识别地址「{entry}」。请填写域名、IP 或 Windows 通配符。");
        }
        return string.Join(';', entries.Distinct(StringComparer.OrdinalIgnoreCase));
    }

    private async void ClosePreferenceChanged(object sender, RoutedEventArgs e)
    {
        bool requested = CloseToTray.IsChecked == true;
        if (!IsLoaded || requested == Options.CloseToTray)
            return;
        await RunAsync(() =>
        {
            SaveOptions(Options with { CloseToTray = requested });
            Status.Text = requested ? "关闭窗口时收起到托盘。" : "关闭窗口时退出 Byway。";
            return Task.CompletedTask;
        });
        CloseToTray.IsChecked = Options.CloseToTray;
    }

    private void SaveOptions(DesktopOptions options)
    {
        var next = profile with { Options = options };
        next.Save();
        profile = next;
    }

    private async void OpenDataFolderClick(object sender, RoutedEventArgs e)
    {
        await RunAsync(() =>
        {
            Process.Start(new ProcessStartInfo(Path.GetDirectoryName(Program.StatePath("nodes.dat"))!) { UseShellExecute = true });
            return Task.CompletedTask;
        });
    }

    private void StartTraffic(TrafficSample? baseline)
    {
        trafficHistory.Flush();
        trafficBaseline = previousTraffic = baseline;
        hasSessionTraffic = false;
        trafficStats = new(null, null, null, null, null, "pending");
        TrafficStatus.Text = "正在获取实时数据…";
        DownloadSpeed.Text = UploadSpeed.Text = ConnectionCount.Text = "—";
        UpdateTrafficScope();
    }

    private Task SampleTrafficAsync()
    {
        if (active is not { } core)
            return Task.CompletedTask;
        if (pendingTrafficSample is { IsCompleted: false })
            return pendingTrafficSample;
        pendingTrafficSample = SampleTrafficAsync(core);
        return pendingTrafficSample;
    }

    private async Task SampleTrafficAsync(Core core)
    {
        TrafficSample? sample = await core.ReadTrafficAsync();
        if (active != core)
            return;
        if (sample is null)
        {
            TrafficStatus.Text = "暂时无法读取实时数据";
            DownloadSpeed.Text = UploadSpeed.Text = ConnectionCount.Text = "—";
            trafficStats = trafficStats with { DownloadBytesPerSecond = null, UploadBytesPerSecond = null, ActiveConnections = null, State = "pending" };
            return;
        }

        if (trafficBaseline is null || previousTraffic is { } last &&
            (sample.Download < last.Download || sample.Upload < last.Upload))
            trafficBaseline = previousTraffic = sample;
        var previous = previousTraffic ?? sample;
        var first = trafficBaseline;
        var seconds = Math.Max(0.01, Stopwatch.GetElapsedTime(previous.Timestamp, sample.Timestamp).TotalSeconds);
        long downloaded = sample.Download - previous.Download;
        long uploaded = sample.Upload - previous.Upload;
        double downloadRate = downloaded / seconds;
        double uploadRate = uploaded / seconds;
        trafficStats = new(sample.Download - first.Download, sample.Upload - first.Upload, downloadRate, uploadRate,
            sample.Connections, "live");
        DownloadSpeed.Text = FormatBytes(downloadRate) + "/s";
        UploadSpeed.Text = FormatBytes(uploadRate) + "/s";
        ConnectionCount.Text = sample.Connections.ToString(CultureInfo.CurrentCulture);
        TrafficStatus.Text = "代理已开启";
        trafficHistory.Record(sample.CapturedAtUtc, downloaded, uploaded);
        FlushTrafficHistoryIfDue();
        previousTraffic = sample;
        hasSessionTraffic = true;
    }

    private void StopTraffic()
    {
        trafficBaseline = previousTraffic = null;
        DownloadSpeed.Text = UploadSpeed.Text = ConnectionCount.Text = "—";
        trafficStats = trafficStats with { DownloadBytesPerSecond = null, UploadBytesPerSecond = null, ActiveConnections = null,
            State = hasSessionTraffic ? "previous" : "unavailable" };
        TrafficStatus.Text = "代理已停用";
        trafficHistory.Flush();
        UpdateTrafficScope();
        if (StatsPage.IsVisible)
            RefreshTrafficHistory(force: true);
    }

    internal static string FormatBytes(double bytes, string precision = "0.#")
    {
        string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
        int scale = 0;
        while (bytes >= 1024 && scale < units.Length - 1)
        {
            bytes /= 1024;
            scale++;
        }
        return $"{bytes.ToString(scale == 0 ? "0" : precision, CultureInfo.CurrentCulture)} {units[scale]}";
    }
}

internal sealed record TrafficStatusSnapshot(long? DownloadBytes, long? UploadBytes, double? DownloadBytesPerSecond,
    double? UploadBytesPerSecond, int? ActiveConnections, string State);
