using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using static Byway.AiLogWindow;

namespace Byway;

public partial class MainWindow
{
    private readonly EngineDiagnostics engineLog = new();

    private async Task<EngineConnection[]?> ReadActiveConnectionsAsync()
    {
        var core = active;
        var entry = mixed;
        if (core is null)
            return [];
        var rows = await core.ReadConnectionsAsync();
        if (active != core)
            return null;
        return rows is null || entry is null ? rows :
            rows.Select(row => row with { Source = entry.SourceFor(row.Source) }).ToArray();
    }

    private async Task DisconnectAsync(Guid? id)
    {
        if (active is not { } core)
            throw new ApiError(409, L10n.Text("当前没有运行中的代理。"));
        if (!await core.CloseConnectionsAsync(id))
            throw new ApiError(404, L10n.Text("连接已结束或暂时无法断开。"));
    }

    private void OpenConnectionsClick(object sender, RoutedEventArgs e)
    {
        var panel = new DockPanel { Margin = new Thickness(18) };
        var actions = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(actions, Dock.Top);
        panel.Children.Add(actions);
        var refresh = new Button { Content = L10n.Text("刷新"), Margin = new Thickness(0, 0, 8, 0) };
        var disconnect = new Button { Content = L10n.Text("断开选中"), Margin = new Thickness(0, 0, 8, 0) };
        var disconnectAll = new Button { Content = L10n.Text("断开全部"), Margin = new Thickness(0, 0, 8, 0) };
        var status = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(refresh);
        actions.Children.Add(disconnect);
        actions.Children.Add(disconnectAll);
        actions.Children.Add(status);
        var grid = new DataGrid { IsReadOnly = true, AutoGenerateColumns = false, CanUserAddRows = false,
            SelectionMode = DataGridSelectionMode.Single };
        AutomationProperties.SetAutomationId(grid, "ActiveConnectionList");
        grid.Columns.Add(Column(L10n.Text("目标"), nameof(EngineConnection.Target), new(1, DataGridLengthUnitType.Star)));
        grid.Columns.Add(Column(L10n.Text("来源"), nameof(EngineConnection.Source), 125));
        grid.Columns.Add(Column(L10n.Text("协议"), nameof(EngineConnection.Network), 60));
        grid.Columns.Add(Column(L10n.Text("规则"), nameof(EngineConnection.Rule), 145));
        grid.Columns.Add(Column(L10n.Text("策略链"), nameof(EngineConnection.Chain), 175));
        grid.Columns.Add(Column(L10n.Text("实际出口"), nameof(EngineConnection.Exit), 145));
        grid.Columns.Add(Column(L10n.Text("上传（字节）"), nameof(EngineConnection.Upload), 90));
        grid.Columns.Add(Column(L10n.Text("下载（字节）"), nameof(EngineConnection.Download), 90));
        panel.Children.Add(grid);
        var window = DiagnosticWindow(L10n.Text("连接列表"), panel);
        bool pending = false;
        async Task Read()
        {
            if (pending)
                return;
            pending = true;
            try
            {
                Guid? selectedId = (grid.SelectedItem as EngineConnection)?.Id;
                var rows = await ReadActiveConnectionsAsync();
                if (rows is null)
                {
                    status.Text = L10n.Text("暂时无法读取连接。");
                    return;
                }
                grid.ItemsSource = rows;
                grid.SelectedItem = rows.FirstOrDefault(row => row.Id == selectedId);
                disconnectAll.IsEnabled = rows.Length > 0;
                status.Text = L10n.Format($"当前 {rows.Length} 条连接");
            }
            finally { pending = false; }
        }
        disconnect.IsEnabled = disconnectAll.IsEnabled = false;
        grid.SelectionChanged += (_, _) => disconnect.IsEnabled = grid.SelectedItem is EngineConnection;
        refresh.Click += async (_, _) => await Read();
        disconnect.Click += async (_, _) =>
        {
            if (grid.SelectedItem is EngineConnection row)
                await RunAsync(() => DisconnectAsync(row.Id));
            await Read();
        };
        disconnectAll.Click += async (_, _) =>
        {
            if (MessageBox.Show(window, L10n.Text("断开当前所有代理连接？"), L10n.Text("断开连接"), MessageBoxButton.YesNo) == MessageBoxResult.Yes)
                await RunAsync(() => DisconnectAsync(null));
            await Read();
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += async (_, _) => await Read();
        window.Closed += (_, _) => timer.Stop();
        window.Loaded += async (_, _) => await Read();
        window.Show();
        timer.Start();
    }

    private void OpenEngineLogClick(object sender, RoutedEventArgs e)
    {
        var panel = new DockPanel { Margin = new Thickness(18) };
        var copy = new Button { Content = L10n.Text("复制日志"), HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(copy, Dock.Top);
        panel.Children.Add(copy);
        var view = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetAutomationId(view, "EngineLogText");
        panel.Children.Add(view);
        copy.Click += async (_, _) => await RunAsync(() =>
        {
            if (view.Text.Length > 0)
                System.Windows.Clipboard.SetText(view.Text);
            return Task.CompletedTask;
        });
        var window = DiagnosticWindow(L10n.Text("内核日志"), panel);
        void Read() => view.Text = string.Join(Environment.NewLine,
            engineLog.Snapshot().Select(row => $"{row.Time:HH:mm:ss} {row.Text}"));
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => Read();
        window.Closed += (_, _) => timer.Stop();
        Read();
        window.Show();
        timer.Start();
    }

    private Window DiagnosticWindow(string title, UIElement content) => new()
    {
        Owner = this, Title = title, Width = 1100, Height = 520, MinWidth = 650, MinHeight = 320,
        WindowStartupLocation = WindowStartupLocation.CenterOwner, Content = content
    };
}
