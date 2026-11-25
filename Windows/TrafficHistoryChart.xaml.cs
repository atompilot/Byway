using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Byway;

public partial class TrafficHistoryChart : System.Windows.Controls.UserControl
{
    private readonly List<Bar> bars = [];
    private readonly List<(TextBlock Text, double Position)> ticks = [];
    private bool updating;
    private long axisMaximum;

    public TrafficHistoryChart() => InitializeComponent();

    internal TrafficHistoryBin? SelectedBin => (Bars.SelectedItem as ListBoxItem)?.Tag as TrafficHistoryBin;
    internal event Action? BinSelected;

    internal void Show(TrafficHistorySnapshot snapshot, TimeZoneInfo zone, bool selectDefault)
    {
        var bins = snapshot.Bins;
        bool changedRanges = bins.Length != bars.Count ||
            !bins.Select(bin => (bin.StartUtc, bin.EndUtc)).SequenceEqual(
                bars.Select(bar => (bar.Bin.StartUtc, bar.Bin.EndUtc)));
        var selectedAt = selectDefault ? null : SelectedBin?.StartUtc;
        var peak = bins.Where(bin => bin.DownloadBytes is not null).MaxBy(Volume);
        long maximum = AxisMaximum(peak is null ? 0 : Volume(peak));

        updating = true;
        try
        {
            if (changedRanges)
            {
                Bars.Items.Clear();
                bars.Clear();
                foreach (var bin in bins)
                {
                    var bar = MakeBar(bin);
                    bars.Add(bar);
                    Bars.Items.Add(bar.Item);
                }
                SetTicks(snapshot, zone);
            }
            if (axisMaximum != maximum)
            {
                axisMaximum = maximum;
                SetScale(axisMaximum);
            }
            for (int i = 0; i < bins.Length; i++)
                UpdateBar(bars[i], bins[i], snapshot, zone, maximum);

            int selected = selectedAt is { } date ? Array.FindIndex(bins, bin => bin.StartUtc == date) : -1;
            Bars.SelectedIndex = selected >= 0 ? selected : peak is not null ? Array.IndexOf(bins, peak) : -1;
        }
        finally { updating = false; }
    }

    internal static string IntervalLabel(TrafficHistoryBin bin, TrafficHistorySnapshot snapshot, TimeZoneInfo zone)
    {
        var start = TimeZoneInfo.ConvertTime(bin.StartUtc, zone);
        var end = TimeZoneInfo.ConvertTime(bin.EndUtc, zone);
        if (snapshot.Granularity == "hour")
        {
            var observedEnd = bin.State != "future" && snapshot.AsOfUtc < bin.EndUtc
                ? TimeZoneInfo.ConvertTime(snapshot.AsOfUtc, zone) : end;
            bool repeatHour = zone.IsAmbiguousTime(start.DateTime) || start.Offset != observedEnd.Offset;
            string from = start.ToString(repeatHour ? "HH:mm zzz" : "HH:mm", CultureInfo.InvariantCulture);
            string until = observedEnd.Date > start.Date && observedEnd.TimeOfDay == TimeSpan.Zero ? "24:00" :
                observedEnd.ToString(repeatHour ? "HH:mm zzz" : "HH:mm", CultureInfo.InvariantCulture);
            return $"{from}–{until}";
        }
        if (snapshot.Granularity == "month")
            return start.ToString("yyyy 年 M 月", CultureInfo.InvariantCulture);
        if (snapshot.Granularity == "year")
            return start.ToString("yyyy 年", CultureInfo.InvariantCulture);
        return start.ToString("M 月 d 日", CultureInfo.InvariantCulture);
    }

    private static long Volume(TrafficHistoryBin bin) => bin.TotalBytes ?? 0;

    private static long AxisMaximum(long peak)
    {
        if (peak <= 3)
            return 3;
        double step = peak / 3.0;
        double precision = Math.Pow(10, Math.Floor(Math.Log10(step)));
        return (long)(3 * Math.Ceiling(step / precision) * precision);
    }

    private Bar MakeBar(TrafficHistoryBin bin)
    {
        var surface = new Border();
        var down = new Border();
        down.SetResourceReference(Border.BackgroundProperty, "AccentButtonBackground");
        var up = new Border { Background = (Brush)FindResource("UploadTraffic"), CornerRadius = new CornerRadius(2, 2, 0, 0) };
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Stretch, MaxWidth = 36, Margin = new Thickness(2, 0, 2, 0) };
        stack.Children.Add(up);
        stack.Children.Add(down);
        var slot = new Grid();
        slot.Children.Add(surface);
        slot.Children.Add(stack);
        return new(new ListBoxItem { Content = slot }, surface, down, up, bin);
    }

    private void UpdateBar(Bar bar, TrafficHistoryBin bin, TrafficHistorySnapshot snapshot, TimeZoneInfo zone, long maximum)
    {
        bar.Bin = bin;
        bar.Item.Tag = bin;
        if (bin.State == "future")
            bar.Surface.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush");
        else
            bar.Surface.Background = bin.State == "missing" ? (Brush)FindResource("MissingTraffic") : null;
        double usableHeight = Plot.ActualHeight > 2 ? Plot.ActualHeight - 2 : 148;
        bar.Down.Height = bin.State == "recorded" && Volume(bin) == 0 ? 2 : usableHeight * (bin.DownloadBytes ?? 0) / maximum;
        bar.Up.Height = usableHeight * (bin.UploadBytes ?? 0) / maximum;
        string label = IntervalLabel(bin, snapshot, zone);
        string value = bin.State switch
        {
            "recorded" => MainWindow.FormatBytes(Volume(bin)),
            "future" => "尚未到达",
            _ => "无记录"
        };
        string tip = $"{label} · {value}";
        if (!Equals(bar.Item.ToolTip, tip))
        {
            bar.Item.ToolTip = tip;
            AutomationProperties.SetName(bar.Item, tip);
        }
    }

    private void SetScale(long maximum)
    {
        Scale.Children.Clear();
        for (int i = 0; i <= 3; i++)
        {
            var label = NewLabel(MainWindow.FormatBytes(maximum / 3 * (3 - i)));
            Canvas.SetTop(label, i * 50 - 7);
            Canvas.SetRight(label, 0);
            Scale.Children.Add(label);
        }
    }

    private void SetTicks(TrafficHistorySnapshot snapshot, TimeZoneInfo zone)
    {
        Ticks.Children.Clear();
        ticks.Clear();
        var bins = snapshot.Bins;
        if (bins.Length == 0)
            return;
        int step = (int)Math.Ceiling(bins.Length / 6.0);
        for (int i = 0; i < bins.Length; i += step)
        {
            var local = TimeZoneInfo.ConvertTime(bins[i].StartUtc, zone);
            string label = local.ToString(snapshot.Granularity switch
            {
                "hour" => "HH:mm", "month" => "M 月", "year" => "yyyy", _ => "M/d"
            }, CultureInfo.InvariantCulture);
            AddTick(label, (i + (snapshot.Granularity == "hour" ? 0 : .5)) / bins.Length);
        }
        if (snapshot.Granularity == "hour")
            AddTick("24:00", 1);
        ArrangeTicks();
    }

    private static TextBlock NewLabel(string text) => new() { Text = text, FontSize = 11, Opacity = .75 };

    private void AddTick(string value, double position)
    {
        var label = NewLabel(value);
        Ticks.Children.Add(label);
        ticks.Add((label, position));
    }

    private void TicksSizeChanged(object sender, SizeChangedEventArgs e) => ArrangeTicks();

    private void ArrangeTicks()
    {
        foreach (var (label, position) in ticks)
        {
            label.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
            double width = label.DesiredSize.Width;
            Canvas.SetTop(label, 6);
            Canvas.SetLeft(label, Math.Clamp(Ticks.ActualWidth * position - width / 2, 0, Math.Max(0, Ticks.ActualWidth - width)));
        }
    }

    private void BarSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!updating)
            BinSelected?.Invoke();
    }

    private void OnBarKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        int index = e.Key switch
        {
            Key.Left => Math.Max(0, Bars.SelectedIndex - 1),
            Key.Right => Math.Min(bars.Count - 1, Bars.SelectedIndex + 1),
            Key.Home => 0,
            Key.End => bars.Count - 1,
            _ => -1
        };
        if (index < 0 || index >= bars.Count)
            return;
        e.Handled = true;
        Bars.SelectedIndex = index;
        bars[index].Item.Focus();
    }

    private sealed record Bar(ListBoxItem Item, Border Surface, Border Down, Border Up, TrafficHistoryBin Initial)
    {
        internal TrafficHistoryBin Bin { get; set; } = Initial;
    }
}
