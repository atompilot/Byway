using System.Net;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Byway;

public partial class MainWindow
{
    private RoutingRuleMatch? lastRuleMatch;

    private void RefreshRuleTestControls(ImportedRouting? entry, bool ready)
    {
        if (RuleTestHost is null || OpenRuleDraft is null || SaveRuleDraft is null)
            return;

        bool supported = entry?.IsClash != true;
        bool hasHost = !string.IsNullOrWhiteSpace(RuleTestHost.Text);
        string name = entry?.Name ?? DefaultRoutingName;
        string usage = entry?.Id == profile.SelectedRouting ? L10n.Text("当前配置") : L10n.Text("未启用");
        string mode = Options.RouteMode == RoutingMode.Rule ? "" : L10n.Text(" · 按规则模式测试");
        RuleTestTarget.Text = supported ? $"{usage} · {name}{mode}" : L10n.Format($"{name} · 请选择 Shadowrocket 分流配置进行测试");
        RuleTestHost.IsEnabled = ready && supported;
        RuleTestButton.IsEnabled = ready && supported && hasHost;
        RuleDraft.IsEnabled = ready;
        OpenRuleDraft.Visibility = supported && entry is not null && hasHost && RuleDraft.Visibility != Visibility.Visible
            ? Visibility.Visible : Visibility.Collapsed;
        OpenRuleDraft.IsEnabled = SaveRuleDraft.IsEnabled = ready;
        if (lastRuleMatch is { } match)
            RuleResultPolicy.Text = FormatRulePolicy(match.Policy);
    }

    private string FormatRulePolicy(string policy) => policy switch
    {
        "PROXY" => $"PROXY · {(active?.Source ?? selected?.Node)?.Name ?? L10n.Text("尚未选择节点")}",
        "DIRECT" => L10n.Text("DIRECT · 直连"),
        _ => L10n.Text("REJECT · 拒绝")
    };

    private void ClearRuleTestResult()
    {
        lastRuleMatch = null;
        if (RuleTestResult is not null)
            RuleTestResult.Visibility = Visibility.Collapsed;
        if (RuleTestFeedback is not null)
            RuleTestFeedback.Text = "";
    }

    private void ShowRuleTestResult(RoutingRuleMatch result)
    {
        lastRuleMatch = result;
        RuleResultPolicy.Text = FormatRulePolicy(result.Policy);
        RuleResultLocation.Text = result.LineNumber is int line ? L10n.Format($"第 {line} 行 · {result.Type}") : L10n.Text("默认兜底 · FINAL");
        RuleResultText.Text = result.Rule;
        RuleTestResult.Visibility = Visibility.Visible;
        RuleTestResult.BringIntoView();
    }

    private void RuleTestOpened(object sender, RoutedEventArgs e)
    {
        if (RuleTestHost?.IsEnabled == true)
            RuleTestHost.Focus();
    }

    private void RuleTestHostChanged(object sender, TextChangedEventArgs e)
    {
        ClearRuleTestResult();
        if (RuleDraft is not null)
            RuleDraft.Visibility = Visibility.Collapsed;
        if (RuleTestButton is not null && SaveRuleDraft is not null && RoutingSelection is not null)
            RefreshRoutingControls();
    }

    private async void RuleTestHostKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter && RuleTestButton.IsEnabled)
        {
            e.Handled = true;
            await TestSelectedRuleAsync();
        }
    }

    private async void RuleTestClick(object sender, RoutedEventArgs e) => await TestSelectedRuleAsync();

    private async Task TestSelectedRuleAsync()
    {
        ClearRuleTestResult();
        RuleTestFeedback.Text = L10n.Text("正在测试规则…");
        await RunAsync(async () =>
        {
            var entry = ChosenRouting is Guid id ? FindRouting(id) : null;
            try
            {
                var result = await TestRoutingRuleAsync(entry, RuleTestHost.Text);
                ShowRuleTestResult(result.Match);
                RuleTestFeedback.Text = "";
            }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException)
            {
                RuleTestFeedback.Text = error.Message;
            }
        });
    }

    private void OpenRuleDraftClick(object sender, RoutedEventArgs e)
    {
        try
        {
            string host = ShadowrocketConfiguration.TestHost(RuleTestHost.Text);
            RuleDraftType.SelectedIndex = IPAddress.TryParse(host, out _) ? 3 : 0;
            RuleDraftValue.Text = host;
            RuleDraftNoResolve.IsChecked = false;
            RuleDraftFeedback.Text = "";
            RuleDraftPolicy.SelectedIndex = lastRuleMatch?.Policy switch { "DIRECT" => 1, "REJECT" => 2, _ => 0 };
            RuleDraft.Visibility = Visibility.Visible;
            RuleTestFeedback.Text = "";
            RefreshRoutingControls();
            RuleDraftPolicy.Focus();
            RuleDraft.BringIntoView();
        }
        catch (InvalidDataException error) { RuleTestFeedback.Text = error.Message; }
    }

    private void RuleDraftTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (RuleDraftValueLabel is null || RuleDraftNoResolve is null)
            return;
        string? type = (RuleDraftType.SelectedItem as ComboBoxItem)?.Content as string;
        RuleDraftValueLabel.Content = type switch
        {
            "DOMAIN-KEYWORD" => L10n.Text("域名关键词"),
            "IP-CIDR" => L10n.Text("IP 或 CIDR"),
            "GEOIP" => L10n.Text("国家代码（CN）"),
            _ => L10n.Text("域名")
        };
        RuleDraftNoResolve.Visibility = type is "IP-CIDR" or "GEOIP" ? Visibility.Visible : Visibility.Collapsed;
        if (type == "GEOIP")
            RuleDraftValue.Text = "CN";
        else if (e.RemovedItems.OfType<ComboBoxItem>().Any(item => Equals(item.Content, "GEOIP")))
            RuleDraftValue.Text = RuleTestHost.Text;
    }

    private void CancelRuleDraftClick(object sender, RoutedEventArgs e)
    {
        RuleDraft.Visibility = Visibility.Collapsed;
        RuleTestFeedback.Text = "";
        RefreshRoutingControls();
        OpenRuleDraft.Focus();
    }

    private async void SaveRuleDraftClick(object sender, RoutedEventArgs e)
    {
        if (ChosenRouting is not Guid id)
            return;
        var entry = FindRouting(id);
        var type = (RuleDraftType.SelectedItem as ComboBoxItem)?.Content as string;
        var policy = (RuleDraftPolicy.SelectedItem as ComboBoxItem)?.Content as string;
        bool noResolve = RuleDraftNoResolve.IsVisible && RuleDraftNoResolve.IsChecked == true;
        RuleDraftFeedback.Text = L10n.Text("正在校验并保存…");
        await RunAsync(async () =>
        {
            bool changed;
            try { changed = await AddRoutingRuleAsync(entry, type, RuleDraftValue.Text, policy, noResolve); }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException)
            {
                RuleDraftFeedback.Text = error.Message;
                return;
            }
            RuleDraft.Visibility = Visibility.Collapsed;
            string saved = changed ? L10n.Format($"已保存到「{entry.Name}」。") : L10n.Text("同一条规则已位于段首。");
            RuleTestFeedback.Text = L10n.Format($"{saved} 正在复测…");
            try
            {
                var result = await TestRoutingRuleAsync(FindRouting(id), RuleTestHost.Text);
                ShowRuleTestResult(result.Match);
                RuleTestFeedback.Text = saved;
            }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException)
            {
                RuleTestFeedback.Text = $"{saved} {error.Message}";
            }
        });
    }

    private async Task<RoutingRuleTestResult> TestRoutingRuleAsync(ImportedRouting? entry, string? input)
    {
        if (entry?.IsClash == true)
            throw new InvalidDataException(L10n.Text("请选择 Shadowrocket 分流配置进行测试。"));
        string host = ShadowrocketConfiguration.TestHost(input);
        var match = await Core.TestRuleAsync((ShadowrocketConfiguration?)entry?.Parse(), host);
        return new(entry?.Id, entry?.Name ?? DefaultRoutingName, host, entry?.Id == profile.SelectedRouting,
            match.Policy == "PROXY" ? (active?.Source ?? selected?.Node)?.Name : null, match);
    }

    private async Task<bool> AddRoutingRuleAsync(ImportedRouting entry, string? type, string? value, string? policy, bool noResolve)
    {
        if (entry.IsClash)
            throw new InvalidDataException(L10n.Text("请选择 Shadowrocket 分流配置添加规则。"));
        string updated = ShadowrocketConfiguration.InsertRule(entry.Text, type, value, policy, noResolve);
        if (updated == entry.Text)
            return false;
        SavedProfile.BackupBeforeRuleAddition();
        await SaveRoutingEntryAsync(entry with { Text = updated }, activate: false);
        return true;
    }

    private sealed record RoutingRuleTestResult(Guid? ConfigurationId, string ConfigurationName, string Host, bool Active,
        string? NodeName, RoutingRuleMatch Match);
}
