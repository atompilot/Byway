using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;

namespace Byway;

internal sealed class AiLogWindow : Window
{
    internal AiLogWindow(Window owner, AiCallLog calls)
    {
        Owner = owner;
        Title = L10n.Text("AI 调用日志");
        Width = 990;
        Height = 490;
        MinWidth = 670;
        MinHeight = 340;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var panel = new DockPanel { Margin = new Thickness(18) };
        Content = panel;
        var summary = new TextBlock { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(summary, Dock.Top);
        panel.Children.Add(summary);

        var grid = new DataGrid
        {
            AutoGenerateColumns = false, IsReadOnly = true, CanUserAddRows = false, CanUserDeleteRows = false,
            HeadersVisibility = DataGridHeadersVisibility.Column
        };
        AutomationProperties.SetAutomationId(grid, "AiCalls");
        grid.Columns.Add(Column(L10n.Text("时间"), nameof(AiCall.Time), 84, "{0:HH:mm:ss}"));
        grid.Columns.Add(Column(L10n.Text("来源"), nameof(AiCall.Source), 172));
        grid.Columns.Add(Column(L10n.Text("方法"), nameof(AiCall.Method), 66));
        grid.Columns.Add(Column(L10n.Text("接口"), nameof(AiCall.Path), new DataGridLength(1, DataGridLengthUnitType.Star)));
        grid.Columns.Add(Column(L10n.Text("状态"), nameof(AiCall.Status), 58));
        grid.Columns.Add(Column(L10n.Text("耗时"), nameof(AiCall.Milliseconds), 78, "{0} ms"));
        panel.Children.Add(grid);

        AiCall? latest = null;
        void Populate()
        {
            AiCall[] rows = calls.Snapshot();
            summary.Text = rows.Length == 0 ? L10n.Text("本次运行还没有 API 调用。") : L10n.Format($"本次运行 · 最近 {rows.Length} 条");
            var first = rows.FirstOrDefault();
            if (first == latest)
                return;
            latest = first;
            grid.ItemsSource = rows;
        }

        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => Populate();
        Closed += (_, _) => timer.Stop();
        Populate();
        timer.Start();
    }

    internal static DataGridTextColumn Column(string header, string property, DataGridLength width, string? format = null)
    {
        var style = new Style(typeof(TextBlock));
        style.Setters.Add(new Setter(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis));
        style.Setters.Add(new Setter(FrameworkElement.ToolTipProperty, new Binding(property) { StringFormat = format }));
        return new()
        {
            Header = header, Binding = new Binding(property) { StringFormat = format },
            Width = width, ElementStyle = style
        };
    }
}
