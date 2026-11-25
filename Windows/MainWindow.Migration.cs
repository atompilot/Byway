using System.Windows;

namespace Byway;

public partial class MainWindow
{
    private async void MigrateClashClick(object sender, RoutedEventArgs e) => await RunAsync(async () =>
    {
        Status.Text = "正在读取 Clash for Windows 的在用配置…";
        var draft = await PreviewClashMigrationAsync();
        var report = draft.Configuration.Report();
        string subscription = draft.Entry.SubscriptionUrl is null ? "本地配置" : "已保留订阅来源，可继续刷新";
        string warnings = report.Warnings.Length == 0 ? "" : "\n\n" + string.Join("\n", report.Warnings);
        string action = draft.UpdatesExisting ? "更新现有配置" : "保存为新配置";
        string mode = draft.Settings.RouteMode switch { RoutingMode.Direct => "直连", RoutingMode.Global => "全局", _ => "规则" };
        string summary = $"{action}「{draft.Entry.Name}」\n" +
            $"{report.NodeCount} 个节点、{report.GroupCount} 个策略组、{report.RuleCount} 条规则\n" +
            $"{subscription} · {draft.BypassCount} 条代理例外 · {mode}模式 · 端口 {draft.Settings.MixedPort}\n\n" +
            "保存后，先退出 Clash，再开启 Byway 代理。" + warnings;
        if (MessageBox.Show(this, summary, "从 Clash 迁移", MessageBoxButton.OKCancel,
            MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK)
            await SaveClashMigrationAsync(draft);
        else
            Status.Text = "已取消 Clash 迁移。";
    });

    private async Task<ClashMigrationDraft> PreviewClashMigrationAsync()
    {
        if (active is not null || restorePending)
            throw new ApiError(409, "请先停用 Byway 代理，再从 Clash 迁移。");
        var proxy = WinProxy.Read();
        var source = await Task.Run(() => ClashWindowsMigration.ReadAsync(proxy));
        var existing = RoutingConfigurations.Find(item => item.IsClash && source.SubscriptionUrl is not null &&
            item.SubscriptionUrl == source.SubscriptionUrl) ??
            RoutingConfigurations.Find(item => item.IsClash && item.Text.TrimStart('\uFEFF') == source.Text);
        string name = existing?.Name ?? Subscription.SafeName($"Clash · {source.Name}", "Clash 配置");
        string baseName = name;
        for (int suffix = 2; existing is null && RoutingConfigurations.Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)); suffix++)
            name = $"{baseName} ({suffix})";
        var entry = new ImportedRouting(existing?.Id ?? Guid.NewGuid(), name, source.Text,
            source.SubscriptionUrl ?? existing?.SubscriptionUrl,
            existing?.SubscriptionUrl is not null ? existing.RefreshHours : 24,
            DateTimeOffset.UtcNow, source.Selections, source.GlobalTarget);
        var settings = Options with
        {
            Bypass = NormalizeBypass(string.Join(';', source.Bypass, Options.Bypass)),
            MixedPort = source.Port,
            RouteMode = source.Mode
        };
        return new(source.Revision(), entry, (ClashConfiguration)entry.Parse(), settings, existing is not null);
    }

    private async Task SaveClashMigrationAsync(ClashMigrationDraft draft)
    {
        if (!await Core.CheckRoutingAsync(draft.Configuration))
            throw new InvalidDataException("Clash 配置未通过内核校验，已保留原配置。");
        var entries = RoutingConfigurations.ToList();
        int index = entries.FindIndex(item => item.Id == draft.Entry.Id);
        if (index < 0)
            entries.Add(draft.Entry);
        else
            entries[index] = draft.Entry;
        var next = profile with { RoutingConfigurations = entries, SelectedRouting = draft.Entry.Id, Options = draft.Settings };
        SavedProfile.BackupBeforeClashMigration();
        next.Save();
        profile = next;
        ShowRoutingConfigurations();
        SyncProxyControls();
        BypassInput.Text = Options.Bypass.Replace(";", Environment.NewLine);
        Status.Text = $"已导入「{draft.Entry.Name}」的分流规则。退出 Clash 后，选择节点并开启 Byway 代理。";
    }

    private sealed record ClashMigrationDraft(string Revision, ImportedRouting Entry, ClashConfiguration Configuration,
        DesktopOptions Settings, bool UpdatesExisting)
    {
        internal int BypassCount => Settings.Bypass.Split(';', StringSplitOptions.RemoveEmptyEntries).Length;
    }
}
