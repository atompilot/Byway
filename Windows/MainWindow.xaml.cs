using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Byway;

public partial class MainWindow : Window, IDisposable
{
    private readonly EventWaitHandle show;
    private SavedProfile profile;
    private List<NodeRow> nodes = [];
    private List<NodeRow> visibleNodes = [];
    private static readonly GroupChoice AllNodes = new(L10n.Text("全部节点"), null);
    private static readonly GroupChoice LocalNodes = new(L10n.Text("本地节点"), Guid.Empty);
    private readonly Forms.NotifyIcon tray;
    private readonly Forms.ContextMenuStrip trayMenu = new();
    private readonly Forms.ToolStripMenuItem trayToggle = new();
    private readonly Forms.ToolStripMenuItem trayNodes = new(L10n.Text("切换节点"));
    private readonly Forms.ToolStripMenuItem trayExit = new(L10n.Text("退出 Byway"));
    private readonly DispatcherTimer heartbeat;
    private Process? guard;
    private Core? active;
    private MixedListener? mixed;
    private NodeRow? selected;
    private long lastNodeTestAgeRefresh;
    private bool busy;
    private bool exiting;
    private bool restorePending;
    private bool updatingGroups;

    private List<NodeGroup> Groups => profile.Groups ?? [];
    private GroupChoice Scope => GroupBox.SelectedItem as GroupChoice ?? AllNodes;
    private NodeGroup? CurrentGroup => Groups.Find(group => group.Id == Scope.Id);

    internal MainWindow(EventWaitHandle show, SavedProfile saved, bool atLogin = false, bool restarted = false,
        bool resumeAfterUpgrade = false)
    {
        this.show = show;
        profile = saved;
        InitializeComponent();
        Language = System.Windows.Markup.XmlLanguage.GetLanguage(L10n.Language);

        var trayOpen = new Forms.ToolStripMenuItem(L10n.Text("打开 Byway"));
        trayOpen.Click += (_, _) => ShowWindow();
        trayToggle.Click += async (_, _) => await RunAsync(ToggleProxyAsync);
        trayExit.Click += async (_, _) => await RunAsync(ExitAsync);
        trayNodes.DropDownOpening += (_, _) => PopulateTrayNodes();
        trayMenu.Items.AddRange(new Forms.ToolStripItem[] { trayOpen, trayToggle, trayNodes, new Forms.ToolStripSeparator(), trayExit });
        tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!),
            Text = "Byway", ContextMenuStrip = trayMenu, Visible = true
        };
        tray.DoubleClick += (_, _) => ShowWindow();
        trayMenu.Opening += (_, _) => Refresh();
        heartbeat = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(500)
        };
        heartbeat.Tick += WatchLifecycle;
        heartbeat.Start();
        InitializeWorkspace();
        InitializeAi();
        ShowProfile(saved, null);
        Status.Text = nodes.Count == 0 ? L10n.Text("添加订阅，或导入 Shadowrocket 导出的节点 JSON。") : L10n.Format($"{nodes.Count} 个节点已导入。");
        if (atLogin)
        {
            ShowActivated = false;
            Loaded += StartFromLoginAsync;
        }
        else if ((restarted || resumeAfterUpgrade) && Options.ProxyWanted)
            Loaded += async (_, _) => await RunAsync(() => SetProxyEnabledAsync(true, probeConnectivity: !resumeAfterUpgrade));
        Refresh();
    }

    private async void StartFromLoginAsync(object sender, RoutedEventArgs e)
    {
        Loaded -= StartFromLoginAsync;
        Hide();
        if (Options is { StartAtLogin: true, ResumeProxy: true, ProxyWanted: true })
            await RunAsync(() => SetProxyEnabledAsync(true));
    }

    private void Refresh()
    {
        ProxyState.Text = restorePending ? L10n.Text("正在恢复系统代理") : active is null ? L10n.Text("代理已停用") : L10n.Text("代理已开启");
        string? nodeName = (active?.Source ?? selected?.Node)?.Name;
        CurrentNode.Text = Options.RouteMode == RoutingMode.Direct ? L10n.Text("路由模式 · 直连") :
            nodeName is null ? L10n.Text("尚未选择节点") : L10n.Format($"当前节点 · {nodeName}");
        Guid? activeNodeId = restorePending ? null : active?.Source?.Id;
        foreach (var row in visibleNodes)
            row.UpdateUseStatus(row.Node.Id == activeNodeId, row == selected);
        CurrentRouting.Text = Options.RouteMode == RoutingMode.Rule ? L10n.Format($"分流 · {profile.ActiveRouting?.Name ?? DefaultRoutingName}") :
            Options.RouteMode == RoutingMode.Global ? L10n.Text("路由模式 · 全局") : "";
        CurrentRouting.Visibility = CurrentRouting.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        string toggle = active is null && !restorePending ? L10n.Text("开启代理") : L10n.Text("停用代理");
        ToggleButton.Content = toggle;
        ToggleButton.IsEnabled = !busy && (active is not null || selected is not null ||
            Options.RouteMode == RoutingMode.Direct || restorePending);
        AddNodeButton.IsEnabled = !busy;
        ScanButton.IsEnabled = !busy;
        SubscriptionButton.IsEnabled = !busy;
        ImportButton.IsEnabled = !busy;
        GroupBox.IsEnabled = !busy;
        RefreshGroupButton.IsEnabled = !busy && CurrentGroup?.IsSubscription == true;
        GroupSettingsButton.IsEnabled = !busy && CurrentGroup is not null;
        ShareGroupButton.IsEnabled = !busy && CurrentGroup is { Members.Count: > 0 };
        NewGroupButton.IsEnabled = !busy;
        ProbeButton.IsEnabled = !busy && visibleNodes.Count > 0;
        SidebarSplitter.IsEnabled = !busy;
        ProbeButton.Content = Scope.Id is null ? L10n.Text("测试全部") : L10n.Text("测试本组");
        trayToggle.Text = toggle;
        trayToggle.Enabled = ToggleButton.IsEnabled;
        trayNodes.Enabled = !busy && nodes.Count > 1;
        trayExit.Enabled = !busy;
        tray.Text = "Byway · " + ProxyState.Text;
        RefreshWorkspaceControls();
    }

    private void PopulateTrayNodes()
    {
        while (trayNodes.DropDownItems.Count > 0)
        {
            var old = trayNodes.DropDownItems[0];
            trayNodes.DropDownItems.RemoveAt(0);
            old.Dispose();
        }
        if (Groups.Count == 0)
        {
            AddTrayRows(trayNodes, nodes);
            return;
        }
        AddTrayGroup(LocalNodes.Label, RowsInScope(LocalNodes));
        foreach (NodeGroup group in Groups)
            AddTrayGroup(group.Name, RowsInScope(new(group.Name, group.Id)));
    }

    private void AddTrayGroup(string name, List<NodeRow> rows)
    {
        if (rows.Count == 0)
            return;
        var menu = new Forms.ToolStripMenuItem { Text = name.Replace("&", "&&") };
        AddTrayRows(menu, rows);
        trayNodes.DropDownItems.Add(menu);
    }

    private void AddTrayRows(Forms.ToolStripMenuItem parent, IEnumerable<NodeRow> rows)
    {
        foreach (NodeRow row in rows)
        {
            var item = new Forms.ToolStripMenuItem { Text = row.Node.Name.Replace("&", "&&"), Checked = row == selected };
            item.Click += async (_, _) => await RunAsync(() => ChooseAsync(row));
            parent.DropDownItems.Add(item);
        }
    }

    private void ScopeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (tray is not null && !updatingGroups)
            ShowScope();
    }

    private void ShowScope()
    {
        var group = CurrentGroup;
        visibleNodes = RowsInScope(Scope);
        NodeList.Tag = group is null;
        NodeList.ItemsSource = visibleNodes;
        NodeList.SelectedItem = selected is not null && visibleNodes.Contains(selected) ? selected : null;
        ShowSubscriptionInfo(group);
        Refresh();
    }

    private void ShowSubscriptionInfo(NodeGroup? group)
    {
        SubscriptionInfoBar.Visibility = group?.IsSubscription == true ? Visibility.Visible : Visibility.Collapsed;
        var info = group?.Info;
        List<string> summary = [];
        List<string> usage = [];
        if (info?.TotalBytes is > 0)
        {
            string total = FormatBytes(info.TotalBytes.Value, "0.##");
            summary.Add(info.RemainingBytes is long remaining ? L10n.Format($"剩余 {FormatBytes(remaining, "0.##")} / {total}") : L10n.Format($"总流量 {total}"));
        }
        if (info?.ExpiresAt is { } expires)
        {
            string label = expires <= DateTimeOffset.UtcNow ? L10n.Text("已到期") : L10n.Text("到期");
            summary.Add($"{label} {expires.ToLocalTime():yyyy-MM-dd HH:mm}");
        }
        if (info?.UploadBytes is long upload)
            usage.Add(L10n.Format($"已上传 {FormatBytes(upload, "0.##")}"));
        if (info?.DownloadBytes is long download)
            usage.Add(L10n.Format($"已下载 {FormatBytes(download, "0.##")}"));
        if (summary.Count == 0)
        {
            summary.AddRange(usage);
            usage.Clear();
        }
        SubscriptionSummary.Text = summary.Count > 0 ? string.Join("  ·  ", summary) : L10n.Text("暂无订阅信息。刷新订阅后重新获取。");
        SubscriptionUsage.Text = string.Join("  ·  ", usage);
        SubscriptionUsage.Visibility = usage.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private List<NodeRow> RowsInScope(GroupChoice scope)
    {
        if (scope.Id is null)
            return nodes;
        if (scope.Id == Guid.Empty)
        {
            var managed = Groups.Where(group => group.IsSubscription).SelectMany(group => group.Members).ToHashSet();
            return nodes.Where(row => !managed.Contains(row.Node.Id)).ToList();
        }
        var group = Groups.Find(item => item.Id == scope.Id);
        var byId = nodes.ToDictionary(row => row.Node.Id);
        return group?.Members.Where(byId.ContainsKey).Select(id => byId[id]).ToList() ?? [];
    }

    private void CommitProfile(SavedProfile next, Guid? scope)
    {
        next.Save();
        ShowProfile(next, scope);
    }

    private void ShowProfile(SavedProfile next, Guid? scope)
    {
        var previous = nodes.ToDictionary(row => row.Node.Id);
        profile = next;
        nodes = next.Nodes.Select(node => previous.TryGetValue(node.Id, out var row) && row.Node == node ? row : new NodeRow(node)).ToList();
        var groupsByMember = NodeGroups.ByMember(Groups);
        foreach (var row in nodes)
            row.UpdateGroups(groupsByMember[row.Node.Id]);
        selected = nodes.Find(row => row.Node.Id == next.Selected) ?? nodes.FirstOrDefault();
        var choices = new List<GroupChoice> { AllNodes, LocalNodes };
        choices.AddRange(Groups.Select(group => new GroupChoice($"{group.Name}  ·  {group.Members.Count}", group.Id)));
        updatingGroups = true;
        try
        {
            GroupBox.ItemsSource = choices;
            GroupBox.SelectedItem = choices.Find(choice => choice.Id == scope) ?? AllNodes;
        }
        finally { updatingGroups = false; }
        ShowScope();
    }

    private async void SubscriptionClick(object sender, RoutedEventArgs e)
    {
        var dialog = new SubscriptionDialog(this);
        if (dialog.ShowDialog() == true && dialog.Link is { } link)
            await RunAsync(() => AddSubscriptionAsync(link));
    }

    private async Task<Guid> AddSubscriptionAsync(SubscriptionLink link)
    {
        var existing = Groups.Find(group => group.SubscriptionAddress == link.Address.AbsoluteUri);
        if (existing is not null)
        {
            GroupBox.SelectedItem = ((IEnumerable<GroupChoice>)GroupBox.ItemsSource).First(choice => choice.Id == existing.Id);
            Status.Text = L10n.Text("该订阅已添加。可以刷新这个节点组。");
            return existing.Id;
        }

        string name = UniqueGroupName(link.Name);
        var group = new NodeGroup(Guid.NewGuid(), name, link.Address.AbsoluteUri, []);
        await LoadSubscriptionAsync(group, isNew: true);
        return group.Id;
    }

    private async void RefreshGroupClick(object sender, RoutedEventArgs e)
    {
        if (CurrentGroup is { IsSubscription: true } group)
            await RunAsync(() => LoadSubscriptionAsync(group, isNew: false));
    }

    private async Task LoadSubscriptionAsync(NodeGroup group, bool isNew, bool replaceSource = false)
    {
        Status.Text = L10n.Format($"正在下载「{group.Name}」…");
        var download = await Subscription.FetchAsync(new Uri(group.SubscriptionAddress!));
        List<Node> checkedNodes = [];
        int skipped = download.Skipped;
        for (int index = 0; index < download.Nodes.Count; index++)
        {
            Node node = download.Nodes[index];
            Status.Text = L10n.Format($"正在校验「{group.Name}」的节点 {index + 1} / {download.Nodes.Count}…");
            if (await Core.CheckAsync(node))
                checkedNodes.Add(node);
            else
                skipped++;
        }
        if (checkedNodes.Count == 0)
            throw new InvalidDataException(L10n.Text("订阅中的节点均未通过配置校验，无法应用。"));

        var owned = group.Members.ToHashSet();
        var existing = profile.Nodes.Where(node => owned.Contains(node.Id)).ToList();
        var (replacement, overrides) = replaceSource ? (checkedNodes, null) : NodeGroups.ApplySubscription(group, existing, checkedNodes);
        var members = replacement.Select(node => node.Id).ToList();
        var removed = owned.Except(members).ToHashSet();
        EnsureActiveNodeSurvives(removed);
        bool willUseUpdatedConnection = active is not null && selected is { } current &&
            replacement.Any(node => node.Id == current.Node.Id && !NodeImport.SameEndpoint(current.Node, node));
        var nextNodes = profile.Nodes.Where(node => !owned.Contains(node.Id)).Concat(replacement).ToList();
        var nextGroup = group with { Members = members, Info = download.Info, Overrides = overrides };
        var nextGroups = Groups.Select(item => item.Id == group.Id ? nextGroup : WithoutMembers(item, removed)).ToList();
        if (isNew)
            nextGroups.Add(nextGroup);
        Guid? nextSelected = selected is { } row && !removed.Contains(row.Node.Id) ? row.Node.Id
            : replacement.FirstOrDefault()?.Id ?? nextNodes.FirstOrDefault()?.Id;
        CommitProfile(profile with { Nodes = nextNodes, Selected = nextSelected, Groups = nextGroups }, group.Id);
        string update = isNew
            ? L10n.Format($"已添加「{group.Name}」 · {members.Count} 个节点。")
            : L10n.Format($"已刷新「{group.Name}」 · {members.Count} 个节点。");
        Status.Text = update +
            (skipped > 0 ? L10n.Format($" 跳过 {skipped} 个不支持或无效的节点。") : "") +
            (willUseUpdatedConnection ? L10n.Text(" 当前节点将在下次连接时使用新配置。") : "");
    }

    private void NewGroupClick(object sender, RoutedEventArgs e) => EditGroup(null);
    private void GroupSettingsClick(object sender, RoutedEventArgs e) => EditGroup(CurrentGroup);

    private async void EditGroup(NodeGroup? group)
    {
        var dialog = new GroupDialog(this, group, profile.Nodes, name => GroupNameExists(name, group?.Id));
        if (dialog.ShowDialog() != true)
            return;
        await RunAsync(async () =>
        {
            if (dialog.RemoveGroup && group is not null)
                RemoveGroup(group);
            else if (dialog.Result is { } updated)
                await SaveGroupAsync(group, updated);
        });
    }

    private async Task SaveGroupAsync(NodeGroup? group, NodeGroup updated)
    {
        if (GroupNameExists(updated.Name, group?.Id))
            throw new InvalidDataException(L10n.Text("已有同名节点组。"));
        if (group?.IsSubscription == true && group.SubscriptionAddress != updated.SubscriptionAddress)
        {
            if (Groups.Any(item => item.Id != group.Id && item.SubscriptionAddress == updated.SubscriptionAddress))
                throw new InvalidDataException(L10n.Text("此订阅地址已被另一个节点组使用。"));
            await LoadSubscriptionAsync(updated, isNew: false, replaceSource: true);
            return;
        }
        var next = Groups.Select(item => item.Id == updated.Id ? updated : item).ToList();
        if (group is null)
            next.Add(updated);
        CommitProfile(profile with { Groups = next }, updated.Id);
        Status.Text = L10n.Format($"已保存「{updated.Name}」。");
    }

    private bool GroupNameExists(string name, Guid? except) =>
        name == AllNodes.Label || name == LocalNodes.Label ||
        Groups.Any(group => group.Id != except && string.Equals(group.Name, name, StringComparison.OrdinalIgnoreCase));

    private void RemoveGroup(NodeGroup group)
    {
        var removed = group.IsSubscription ? group.Members.ToHashSet() : [];
        EnsureActiveNodeSurvives(removed);
        var nextNodes = profile.Nodes.Where(node => !removed.Contains(node.Id)).ToList();
        var nextGroups = Groups.Where(item => item.Id != group.Id).Select(item => WithoutMembers(item, removed)).ToList();
        Guid? nextSelected = selected is { } row && !removed.Contains(row.Node.Id) ? row.Node.Id : nextNodes.FirstOrDefault()?.Id;
        CommitProfile(profile with { Nodes = nextNodes, Selected = nextSelected, Groups = nextGroups }, null);
        Status.Text = L10n.Format($"已删除「{group.Name}」。");
    }

    private void EnsureActiveNodeSurvives(HashSet<Guid> removed)
    {
        if (active?.Source is { } source && removed.Contains(source.Id))
            throw new InvalidOperationException(L10n.Text("该操作会移除当前出口。请先切换节点或停用代理。"));
    }

    private static NodeGroup WithoutMembers(NodeGroup group, HashSet<Guid> removed) =>
        group.IsSubscription || removed.Count == 0 ? group : group with { Members = group.Members.Where(id => !removed.Contains(id)).ToList() };

    private async void ImportClick(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = L10n.Text("导入 Shadowrocket 节点"), Filter = "JSON (*.json)|*.json" };
        if (dialog.ShowDialog(this) == true)
            await RunAsync(() => ImportAsync(NodeImport.Read(dialog.FileName), showDetails: true));
    }

    private async Task<object> ImportAsync(ImportBatch batch, bool showDetails = false)
    {
        var knownLocal = RowsInScope(LocalNodes).Select(row => row.Node).ToList();
        List<Node> added = [];
        List<string> failures = [];
        int imported = 0;
        int existing = 0;
        for (int index = 0; index < batch.Entries.Count; index++)
        {
            ImportEntry entry = batch.Entries[index];
            Status.Text = L10n.Format($"正在校验节点 {index + 1} / {batch.Entries.Count}…");
            if (entry.Node is not { } node)
                failures.Add($"{entry.Name} · {entry.Error}");
            else if (knownLocal.Any(other => NodeImport.SameNode(other, node)) || added.Any(other => NodeImport.SameNode(other, node)))
                existing++;
            else if (await Core.CheckAsync(node))
            {
                added.Add(node);
                imported++;
            }
            else
                failures.Add(L10n.Format($"{entry.Name} · sing-box 未通过配置校验"));
        }

        if (imported > 0)
            CommitProfile(profile with { Nodes = profile.Nodes.Concat(added).ToList(), Selected = selected?.Node.Id ?? added[0].Id }, Guid.Empty);
        Status.Text = L10n.Format($"导入 {imported} 个节点，已存在 {existing} 个，失败 {failures.Count} 个。") +
            (batch.Subscriptions > 0 ? L10n.Format($" 跳过 {batch.Subscriptions} 条订阅记录。") : "");
        if (showDetails && failures.Count > 0)
        {
            // Keep failure details visible in a scrollable dialog without exposing connection secrets.
            var details = new Window
            {
                Owner = this, Title = L10n.Text("导入详情"), Width = 500, Height = 270,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Content = new TextBox
                {
                    Text = string.Join(Environment.NewLine, failures), IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(16)
                }
            };
            details.ShowDialog();
        }
        return new { imported, existing, failures, skippedSubscriptions = batch.Subscriptions, nodeIds = added.Select(node => node.Id).ToArray() };
    }

    private async void ProbeClick(object sender, RoutedEventArgs e) => await RunAsync(() => ProbeAsync(visibleNodes.ToArray()));
    private async void ToggleClick(object sender, RoutedEventArgs e) => await RunAsync(ToggleProxyAsync);

    private async void NodeLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject origin &&
            ItemsControl.ContainerFromElement(NodeList, origin) is ListViewItem { DataContext: NodeRow row } &&
            NodeList.SelectedItem == row)
            await ChooseFromListAsync(row);
    }

    private async void NodeKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || NodeList.SelectedItem is not NodeRow row)
            return;
        e.Handled = true;
        if (!e.IsRepeat)
            await ChooseFromListAsync(row);
    }

    private async void SelectClick(object sender, RoutedEventArgs e)
    {
        if (NodeList.SelectedItem is NodeRow row)
            await ChooseFromListAsync(row);
    }

    private async Task ChooseFromListAsync(NodeRow row)
    {
        await RunAsync(() => ChooseAsync(row, probeConnectivity: false));
        NodeList.SelectedItem = selected is not null && visibleNodes.Contains(selected) ? selected : null;
    }

    private async Task ProbeAsync(IReadOnlyList<NodeRow> requested)
    {
        const int maxConcurrentProbes = 8;
        using var launch = new SemaphoreSlim(1);
        foreach (var row in requested)
            row.Update(L10n.Text("等待测试"));
        await ProbeBatchAsync(requested, maxConcurrentProbes, L10n.Text("测试"), CancellationToken.None);

        var retry = requested.Where(row => row.Probe is { Succeeded: false }).ToArray();
        if (requested.Count > 1 && retry.Length > 0 && requested.Any(row => row.Probe?.Succeeded == true))
        {
            using var retryBudget = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            await ProbeBatchAsync(retry, 2, L10n.Text("复测"), retryBudget.Token);
        }

        int success = requested.Count(row => row.Probe?.Succeeded == true);
        Status.Text = requested.Count == 1 ? L10n.Format($"测试完成 · {requested[0].Node.Name} · {requested[0].Test}")
            : L10n.Format($"测试完成 · {success} 个可用，{requested.Count - success} 个失败。");

        async Task ProbeBatchAsync(IReadOnlyList<NodeRow> rows, int concurrency, string action, CancellationToken cancellation)
        {
            int next = 0;
            int completed = 0;
            Status.Text = L10n.Format($"正在{action} · 已完成 0 / {rows.Count}");
            await Task.WhenAll(Enumerable.Range(0, Math.Min(rows.Count, concurrency)).Select(_ => ProbeNextAsync()));

            async Task ProbeNextAsync()
            {
                while (!cancellation.IsCancellationRequested && next < rows.Count)
                {
                    var row = rows[next++];
                    var previous = row.Probe;
                    row.Update(L10n.Format($"{action}中…"));
                    try
                    {
                        using var candidate = await StartProbeCoreAsync(row.Node, cancellation);
                        var result = await candidate.ProbeAsync(cancellationToken: cancellation);
                        row.Update(result.Succeeded ? result : previous ?? result);
                    }
                    catch (Exception error)
                    {
                        if (previous is not null)
                            row.Update(previous);
                        else
                            row.Update(error is TimeoutException or OperationCanceledException ? L10n.Text("内核启动超时") : L10n.Text("内核启动失败"),
                                DateTimeOffset.UtcNow);
                    }
                    Status.Text = L10n.Format($"正在{action} · 已完成 {++completed} / {rows.Count}");
                }
            }
        }

        async Task<Core> StartProbeCoreAsync(Node node, CancellationToken cancellation)
        {
            // Let each core bind its temporary port before the next core chooses a port.
            await launch.WaitAsync(cancellation);
            try { return await Core.StartAsync(node); }
            finally { launch.Release(); }
        }
    }

    private async Task ChooseAsync(NodeRow row, bool probeConnectivity = true)
    {
        if (row == selected)
            return;
        if (restorePending)
            throw new InvalidOperationException(L10n.Text("请先恢复 Windows 系统代理。"));
        if (active is not null && Options.RouteMode != RoutingMode.Direct)
            await ActivateAsync(row, row.Node, profile with { Selected = row.Node.Id }, probeConnectivity);
        else
        {
            SaveSelection(row);
            selected = row;
            NodeList.SelectedItem = row;
            Status.Text = Options.RouteMode == RoutingMode.Direct ? L10n.Format($"已选择 {row.Node.Name} · 当前为直连模式") :
                L10n.Format($"已选择 {row.Node.Name}，开启代理后生效。");
        }
    }

    private Task ToggleProxyAsync() => SetProxyEnabledAsync(active is null && !restorePending);

    private async Task SetProxyEnabledAsync(bool enabled, bool probeConnectivity = true)
    {
        if (!enabled)
        {
            bool manual = active?.Capture == CaptureMode.Manual;
            if (Options.ProxyWanted)
                SaveOptions(Options with { ProxyWanted = false });
            await SampleTrafficAsync();
            StopProxy();
            Status.Text = manual ? L10n.Text("本机代理监听已关闭。") : L10n.Text("已交还 Windows 系统代理。");
        }
        else
        {
            if (restorePending)
                throw new InvalidOperationException(L10n.Text("请先恢复 Windows 系统代理。"));
            if (active is null)
            {
                var next = profile with { Options = Options with { ProxyWanted = true } };
                await ActivateAsync(selected, selected?.Node, next, probeConnectivity);
            }
        }
    }

    private async Task ActivateAsync(NodeRow? row, Node? source, SavedProfile next, bool probeConnectivity = true)
    {
        if (active?.Capture != CaptureMode.Tun)
        {
            await StartProxyAsync(row, source, next, probeConnectivity);
            return;
        }

        var previous = profile;
        var previousRow = selected;
        var previousSource = active.Source ?? previousRow?.Node;
        await SampleTrafficAsync();
        StopProxy();
        try { await StartProxyAsync(row, source, next, probeConnectivity); }
        catch (Exception switchError)
        {
            try { await StartProxyAsync(previousRow, previousSource, previous, probeConnectivity); }
            catch (Exception recoveryError)
            {
                throw new InvalidOperationException(L10n.Format($"切换失败，未能恢复原代理。{recoveryError.Message}"), switchError);
            }
            throw;
        }
    }

    private async Task StartProxyAsync(NodeRow? row, Node? source, SavedProfile next, bool probeConnectivity)
    {
        var routing = next.ActiveRouting?.Parse();
        var settings = next.Options ?? new DesktopOptions();
        var capture = settings.Capture == CaptureMode.Tun && !Program.IsElevated ? CaptureMode.SystemProxy : settings.Capture;
        var privateNetwork = capture == CaptureMode.Tun && !ExternalTailscaleRunning() ? next.PrivateNetwork : null;
        _ = privateNetwork?.Input.Validate(settings.MixedPort);
        var mode = source is null && privateNetwork is not null ? RoutingMode.Direct : settings.RouteMode;
        var label = mode == RoutingMode.Direct ? L10n.Text("直连") :
            source?.Name ?? throw new InvalidOperationException(L10n.Text("请先选择代理节点。"));
        var previousListener = mixed;
        var entry = previousListener?.Port == settings.MixedPort ? previousListener : new MixedListener(settings.MixedPort);
        int previousTarget = entry.TargetPort;
        Status.Text = probeConnectivity ? L10n.Format($"正在验证 {label}…") : L10n.Format($"正在切换到 {label}…");
        Core? candidate = null;
        bool adopted = false;
        try
        {
            candidate = await Core.StartAsync(source, collectTraffic: true, routing, mode, engineLog, capture, privateNetwork);
            string? exitIp = null;
            if (probeConnectivity)
            {
                var result = await candidate.ProbeAsync(fallback: true);
                if (candidate.Source is not null)
                    row?.Update(result);
                if (!result.Succeeded)
                    throw new InvalidOperationException(L10n.Format($"{label} · {result.Error}，未应用新的代理配置。"));
                if (capture == CaptureMode.Tun && !(await candidate.ProbeAsync(fallback: true, throughCapture: true)).Succeeded)
                    throw new InvalidOperationException(L10n.Text("全流量网卡已启动，但未通过系统 DNS 和 HTTPS 检查，未应用新的代理配置。"));
                exitIp = result.ExitIp;
            }

            await SampleTrafficAsync();
            var initialTraffic = await candidate.ReadTrafficAsync();

            entry.TargetPort = candidate.Port;
            if (capture == CaptureMode.Manual)
            {
                ProxyLease.ReleaseForManual(entry.Endpoint, next.Save);
            }
            else
            {
                if (guard is null || guard.HasExited)
                {
                    guard?.Dispose();
                    guard = Program.StartGuard();
                }
                ProxyLease.Activate(candidate, new(guard.Id, guard.StartTime.ToFileTimeUtc()), entry.Endpoint, settings.Bypass, next.Save);
            }
            Core? previous = active;
            active = candidate;
            mixed = entry;
            profile = next;
            adopted = true;
            StartTraffic(initialTraffic);
            selected = row;
            previous?.Dispose();
            if (previousListener != entry)
                previousListener?.Dispose();
            NodeList.SelectedItem = row;
            Status.Text = capture != settings.Capture
                ? L10n.Text("已恢复系统代理。以管理员身份重启 Byway 后可使用全流量模式。")
                : exitIp is null ? L10n.Format($"已使用 {label}") : L10n.Format($"已使用 {label} · 出口 {exitIp}");
        }
        finally
        {
            if (!adopted)
            {
                entry.TargetPort = previousTarget;
                if (previousListener != entry)
                    entry.Dispose();
                candidate?.Dispose();
            }
        }
    }

    private void SaveSelection(NodeRow row)
    {
        var next = profile with { Selected = row.Node.Id };
        next.Save();
        profile = next;
    }

    private void StopProxy()
    {
        restorePending = true;
        ProxyLease.Release();
        mixed?.Dispose();
        mixed = null;
        active?.Dispose();
        active = null;
        StopTraffic();
        restorePending = false;
    }

    private void WatchLifecycle(object? sender, EventArgs args)
    {
        RefreshPrivatePageOnTimer();
        if (show.WaitOne(0))
            ShowWindow();
        if (NodesPage.IsVisible && Stopwatch.GetElapsedTime(lastNodeTestAgeRefresh) >= TimeSpan.FromSeconds(10))
        {
            lastNodeTestAgeRefresh = Stopwatch.GetTimestamp();
            var now = DateTimeOffset.UtcNow;
            foreach (var row in visibleNodes)
                row.RefreshTestAge(now);
        }
        if (active is null && !restorePending)
            return;
        try
        {
            if (!restorePending && active is { Running: true } && mixed is not null &&
                (active.Capture == CaptureMode.Manual || guard is { HasExited: false } &&
                 ProxyLease.IsActive(active, mixed.Endpoint, Options.Bypass)))
                return;
            bool manual = active?.Capture == CaptureMode.Manual;
            StopProxy();
            string message = manual ? L10n.Text("代理内核已停止，本机代理监听已关闭。") : L10n.Text("代理已停止，Windows 已恢复原代理或由其他应用接管。");
            engineLog.Read(message, []);
            Status.Text = message;
        }
        catch (Exception)
        {
            restorePending = true;
            Status.Text = L10n.Text("无法恢复 Windows 系统代理，正在重试。");
        }
        Refresh();
    }

    private async Task ExitAsync()
    {
        await SampleTrafficAsync();
        StopProxy();
        exiting = true;
        System.Windows.Application.Current.Shutdown();
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (busy)
            return;
        try { await RunExclusiveAsync(async () => { await action(); return true; }); }
        catch (System.Text.Json.JsonException) { ShowError(L10n.Text("无法读取 JSON。请选择 Shadowrocket 节点导出文件。")); }
        catch (Exception error) { ShowError(error.Message); }
    }

    private async Task<T> RunExclusiveAsync<T>(Func<Task<T>> action)
    {
        busy = true;
        Refresh();
        try { return await action(); }
        finally
        {
            busy = false;
            if (!exiting)
                Refresh();
        }
    }

    private void ShowError(string message)
    {
        Status.Text = message;
        if (!IsVisible)
            tray.ShowBalloonTip(4000, "Byway", message, Forms.ToolTipIcon.Warning);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (exiting)
            return;
        e.Cancel = true;
        if (Options.CloseToTray)
            Hide();
        else if (!busy)
            Dispatcher.InvokeAsync(() => RunAsync(ExitAsync));
    }

    private void ShowWindow()
    {
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
    }

    public void Dispose()
    {
        heartbeat.Stop();
        trafficTimer.Stop();
        trafficHistory.Flush();
        aiAddressTimer.Stop();
        aiServer?.Dispose();
        tray.Visible = false;
        tray.Icon?.Dispose();
        tray.Dispose();
        trayMenu.Dispose();
        mixed?.Dispose();
        active?.Dispose();
        guard?.Dispose();
    }
}

internal sealed record GroupChoice(string Label, Guid? Id);
