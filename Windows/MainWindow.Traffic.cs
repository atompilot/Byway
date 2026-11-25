using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace Byway;

public partial class MainWindow
{
    private readonly TrafficHistory trafficHistory = new(Program.StatePath("traffic"), Program.WriteAtomic);
    private TrafficPeriod historyPeriod;
    private TrafficHistorySnapshot? shownHistory;
    private long historyRefreshTime;
    private long historyFlushTime = Stopwatch.GetTimestamp();
    private TimeZoneInfo historyZone = TimeZoneInfo.Local;

    private void InitializeTrafficHistory() => HistoryChart.BinSelected += RefreshTrafficBin;

    private void FlushTrafficHistoryIfDue()
    {
        if (Stopwatch.GetElapsedTime(historyFlushTime) < TimeSpan.FromSeconds(10))
            return;
        trafficHistory.Flush();
        historyFlushTime = Stopwatch.GetTimestamp();
    }

    private void UpdateTrafficScope()
    {
        if (active is not { } core)
        {
            TrafficScope.Text = "此设备 · Byway 接管的流量";
            return;
        }
        string mode = $"此设备 · {CaptureName(core.Capture)}";
        TrafficScope.Text = core.Source is { } source ? $"{mode} · {source.Name}" : mode;
    }

    private void TrafficPeriodChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.RadioButton { Tag: string tag } ||
            !Enum.TryParse<TrafficPeriod>(tag, out var period) || period == historyPeriod)
            return;
        historyPeriod = period;
        RefreshTrafficHistory(force: true, selectDefault: true);
    }

    private void RefreshTrafficHistory(bool force = false, bool selectDefault = false)
    {
        if (HistoryChart is null || !force && Stopwatch.GetElapsedTime(historyRefreshTime) < TimeSpan.FromSeconds(3))
            return;
        historyRefreshTime = Stopwatch.GetTimestamp();
        UpdateTrafficScope();
        historyZone = TimeZoneInfo.Local;
        var snapshot = trafficHistory.Read(historyPeriod, DateTimeOffset.UtcNow, historyZone);
        shownHistory = snapshot;
        HistoryRange.Text = DescribeTrafficRange(snapshot, historyZone) + " · 按电脑本地时间";
        HistoryTotal.Text = HistoryVolume(snapshot.TotalBytes);
        HistoryDownload.Text = HistoryVolume(snapshot.DownloadBytes);
        HistoryUpload.Text = HistoryVolume(snapshot.UploadBytes);
        HistoryGranularity.Text = snapshot.Granularity switch
        {
            "hour" => "按小时", "month" => "按月", "year" => "按年", _ => "按天"
        };
        HistoryLegend.Text = historyPeriod == TrafficPeriod.Today ? "斜线 无记录  ·  灰色 尚未到达" : "斜线 无记录";
        HistoryNotice.Text = snapshot.StorageIssue ? "部分流量历史暂时无法读写。" :
            snapshot.RecordedSinceUtc is null ? "开启代理后开始记录流量。" :
            snapshot.DownloadBytes is null ? "所选范围暂无采样记录。" : "";
        HistoryNotice.Visibility = HistoryNotice.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        HistoryChart.Show(snapshot, historyZone, selectDefault);
        RefreshTrafficBin();
    }

    private static string DescribeTrafficRange(TrafficHistorySnapshot snapshot, TimeZoneInfo zone)
    {
        var start = TimeZoneInfo.ConvertTime(snapshot.StartUtc, zone);
        var end = TimeZoneInfo.ConvertTime(snapshot.AsOfUtc < snapshot.EndUtc ? snapshot.AsOfUtc : snapshot.EndUtc, zone);
        if (snapshot.Period == TrafficHistory.PeriodCode(TrafficPeriod.Today))
            return $"{start:M 月 d 日 HH:mm}–{end:HH:mm}";
        if (snapshot.Period == TrafficHistory.PeriodCode(TrafficPeriod.Yesterday))
            return $"{start:M 月 d 日}";
        if (snapshot.Period == TrafficHistory.PeriodCode(TrafficPeriod.All))
        {
            if (snapshot.RecordedSinceUtc is not { } first)
                return "尚无历史";
            start = TimeZoneInfo.ConvertTime(first, zone);
            return $"{start:yyyy 年 M 月 d 日}–{end:yyyy 年 M 月 d 日}";
        }
        return $"{start:M 月 d 日}–{end:M 月 d 日}";
    }

    private void RefreshTrafficBin()
    {
        if (shownHistory is not { } snapshot)
            return;
        var bin = HistoryChart.SelectedBin;
        HistoryBinLabel.Text = bin is not null ? TrafficHistoryChart.IntervalLabel(bin, snapshot, historyZone) : "选择时段";
        HistoryBinTotal.Text = HistoryVolume(bin?.TotalBytes);
        HistoryBinDownload.Text = HistoryVolume(bin?.DownloadBytes);
        HistoryBinUpload.Text = HistoryVolume(bin?.UploadBytes);
        HistoryBinNote.Text = bin?.State switch
        {
            "future" => "尚未到达这个时段。",
            "missing" => "这个时段没有采样记录。",
            _ => ""
        };
        HistoryBinNote.Visibility = HistoryBinNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string HistoryVolume(long? value) => value is long bytes ? FormatBytes(bytes) : "—";
}
