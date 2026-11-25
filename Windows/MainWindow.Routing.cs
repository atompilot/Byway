using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Byway;

public partial class MainWindow
{
    private const string DefaultRoutingName = "默认配置";
    private readonly DispatcherTimer routingTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly Dictionary<Guid, DateTimeOffset> routingAttempts = [];
    private List<ImportedRouting> RoutingConfigurations => profile.RoutingConfigurations ?? [];
    private Guid? ChosenRouting => (RoutingSelection.SelectedItem as RoutingChoice)?.Id;

    private void ShowRoutingConfigurations() => ShowRoutingConfigurations(profile.SelectedRouting);

    private void ShowRoutingConfigurations(Guid? choice)
    {
        var current = profile.ActiveRouting;
        var report = current?.Parse().Report();
        RoutingSummary.Text = current is null ? "当前使用默认配置"
            : $"当前使用「{current.Name}」 · {report!.RuleCount} 条规则";
        List<RoutingChoice> entries = [new(null, DefaultRoutingName), ..RoutingConfigurations.Select(item => new RoutingChoice(item.Id, item.Name))];
        RoutingSelection.ItemsSource = entries;
        RoutingSelection.SelectedItem = entries.Find(item => item.Id == choice) ?? entries[0];
        RefreshRoutingControls();
    }

    private void RoutingChoiceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DeleteRoutingButton is not null)
        {
            ClearRuleTestResult();
            if (RuleDraft is not null)
                RuleDraft.Visibility = Visibility.Collapsed;
            RefreshRoutingControls();
        }
    }

    private void RefreshRoutingControls()
    {
        bool ready = !busy && !restorePending;
        RoutingSelection.IsEnabled = ready;
        NewRoutingButton.IsEnabled = ready;
        MigrateClashButton.IsEnabled = ready && active is null;
        ApplyRoutingChoice.IsEnabled = ready && ChosenRouting != profile.SelectedRouting;
        EditRoutingButton.IsEnabled = DeleteRoutingButton.IsEnabled = ready && ChosenRouting.HasValue;
        var entry = RoutingConfigurations.Find(item => item.Id == ChosenRouting);
        RefreshRoutingButton.IsEnabled = ready && entry?.SubscriptionUrl is not null;
        RefreshRuleTestControls(entry, ready);
    }

    private async void NewRoutingClick(object sender, RoutedEventArgs e) => await EditRoutingAsync(null);

    private async void EditRoutingClick(object sender, RoutedEventArgs e)
    {
        if (ChosenRouting is Guid id)
            await EditRoutingAsync(FindRouting(id));
    }

    private async Task EditRoutingAsync(ImportedRouting? current)
    {
        var dialog = new RoutingDialog(this, current);
        if (dialog.ShowDialog() == true && dialog.Result is { } edited)
            await RunAsync(() => SaveRoutingEntryAsync(edited, activate: false));
    }

    private async void ApplyRoutingChoiceClick(object sender, RoutedEventArgs e) =>
        await RunAsync(() => SelectRoutingAsync(ChosenRouting));

    private async void RefreshRoutingClick(object sender, RoutedEventArgs e)
    {
        if (ChosenRouting is Guid id)
            await RunAsync(() => RefreshRoutingEntryAsync(id));
    }

    private async void DeleteRoutingClick(object sender, RoutedEventArgs e)
    {
        if (ChosenRouting is not Guid id)
            return;
        var entry = FindRouting(id);
        string details = profile.SelectedRouting == id ? "\n当前将切回默认配置。" : "";
        if (MessageBox.Show(this, $"删除「{entry.Name}」？{details}", "删除分流配置",
            MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes)
            await RunAsync(() => DeleteRoutingAsync(id));
    }

    private ImportedRouting FindRouting(Guid id, bool shadowrocketOnly = false) =>
        RoutingConfigurations.Find(item => item.Id == id && (!shadowrocketOnly || !item.IsClash))
        ?? throw new ApiError(404, "分流配置不存在。");

    private async Task SaveRoutingEntryAsync(ImportedRouting entry, bool activate)
    {
        var name = Subscription.SafeName(entry.Name, "");
        if (name.Length == 0 || name == DefaultRoutingName)
            throw new InvalidDataException("请为配置填写有效名称。");
        if (RoutingConfigurations.Any(item => item.Id != entry.Id && item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("已有同名分流配置。");
        entry = entry with { Name = name };
        if (entry.SubscriptionUrl is not null && entry.RefreshHours is < 0 or > 168)
            throw new InvalidDataException("刷新间隔请填写 0 至 168 小时。0 表示仅手动刷新。");

        var configured = RoutingConfigurations.ToList();
        int index = configured.FindIndex(item => item.Id == entry.Id);
        if (index < 0 || configured[index].Text != entry.Text || configured[index].IsClash != entry.IsClash ||
            configured[index].Selections != entry.Selections)
        {
            var parsed = entry.Parse();
            if (!await Core.CheckRoutingAsync(parsed))
                throw new InvalidDataException("分流配置未通过内核校验，已保留原配置。");
        }
        if (index < 0)
            configured.Add(entry);
        else
            configured[index] = entry;
        await WriteRoutingAsync(profile with { RoutingConfigurations = configured,
            SelectedRouting = activate ? entry.Id : profile.SelectedRouting }, entry.Id);
        Status.Text = $"已保存「{entry.Name}」。";
    }

    private async Task RefreshRoutingEntryAsync(Guid id)
    {
        var entry = FindRouting(id);
        if (entry.SubscriptionUrl is not { } url)
            throw new InvalidDataException("这份配置没有 Clash 订阅地址。");
        routingAttempts[id] = DateTimeOffset.UtcNow;
        string text = await Subscription.FetchClashAsync(SubscriptionLink.Parse(url).Address);
        if (text == entry.Text)
        {
            await SaveRoutingEntryAsync(entry with { RefreshedAt = DateTimeOffset.UtcNow }, activate: false);
        }
        else
        {
            var current = (ClashConfiguration)entry.Parse();
            var selections = current.Groups.ToDictionary(group => group.Name, group => group.Selected);
            var updated = ClashConfiguration.Parse(text, selections);
            if (updated.Groups.Any(group => selections.TryGetValue(group.Name, out var previous) && previous != group.Selected))
                throw new InvalidDataException("订阅移除了已有策略组正在使用的成员，已保留原配置。请先核对订阅中的策略组。");
            await SaveRoutingEntryAsync(entry with { Text = text, RefreshedAt = DateTimeOffset.UtcNow,
                Selections = updated.Groups.ToDictionary(group => group.Name, group => group.Selected) }, activate: false);
        }
        Status.Text = $"已刷新「{entry.Name}」。";
    }

    private async Task RefreshDueRoutingAsync()
    {
        if (busy || exiting || restorePending || System.Windows.Interop.ComponentDispatcher.IsThreadModal)
            return;
        var now = DateTimeOffset.UtcNow;
        var due = RoutingConfigurations.Find(item => item.SubscriptionUrl is not null && item.RefreshHours > 0 &&
            now - (routingAttempts.GetValueOrDefault(item.Id, item.RefreshedAt ?? DateTimeOffset.MinValue)) >=
                TimeSpan.FromHours(item.RefreshHours));
        if (due is null)
            return;
        try { await RunExclusiveAsync(async () => { await RefreshRoutingEntryAsync(due.Id); return true; }); }
        catch (Exception) { Status.Text = $"「{due.Name}」自动刷新失败，已保留当前配置。"; }
    }

    private async Task SelectRoutingAsync(Guid? id)
    {
        if (id is Guid target)
            FindRouting(target);
        await WriteRoutingAsync(profile with { SelectedRouting = id }, id);
        Status.Text = $"已切换到「{profile.ActiveRouting?.Name ?? DefaultRoutingName}」。";
    }

    private async Task DeleteRoutingAsync(Guid id)
    {
        var entry = FindRouting(id);
        Guid? selectedId = profile.SelectedRouting == id ? null : profile.SelectedRouting;
        await WriteRoutingAsync(profile with
        {
            RoutingConfigurations = RoutingConfigurations.Where(item => item.Id != id).ToList(),
            SelectedRouting = selectedId
        }, selectedId);
        routingAttempts.Remove(id);
        Status.Text = $"已删除「{entry.Name}」。";
    }

    private async Task WriteRoutingAsync(SavedProfile next, Guid? choice)
    {
        if (restorePending)
            throw new InvalidOperationException("请先恢复 Windows 系统代理。");

        var before = profile.ActiveRouting;
        var after = next.ActiveRouting;
        bool changed = before?.Text != after?.Text || before?.Selections != after?.Selections || before?.IsClash != after?.IsClash;
        if (changed && active is { } core)
            await ActivateAsync(selected, core.Source ?? selected?.Node, next);
        else
        {
            next.Save();
            profile = next;
        }
        ShowRoutingConfigurations(choice);
    }

    private object RoutingSnapshot(bool shadowrocketOnly = false) => new
    {
        activeId = shadowrocketOnly && profile.ActiveRouting?.IsClash == true ? null : profile.SelectedRouting,
        configurations = RoutingConfigurations.Where(item => !shadowrocketOnly || !item.IsClash).Select(item => new
        {
            item.Id, item.Name, format = item.IsClash ? "clash" : "shadowrocket", active = item.Id == profile.SelectedRouting
        }).ToArray()
    };

    private object RoutingDetails(ImportedRouting item, bool includeText = false)
    {
        var parsed = item.Parse();
        return new
        {
            item.Id, item.Name, text = includeText || !item.IsClash ? item.Text : null, format = item.IsClash ? "clash" : "shadowrocket",
            active = item.Id == profile.SelectedRouting, report = parsed.Report(),
            groups = (parsed as ClashConfiguration)?.Groups,
            subscription = item.SubscriptionUrl is not null,
            refreshHours = item.SubscriptionUrl is not null ? item.RefreshHours : (int?)null, item.RefreshedAt
        };
    }

    private sealed record RoutingChoice(Guid? Id, string Name);
}
