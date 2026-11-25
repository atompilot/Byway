using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace Byway;

internal sealed class RoutingDialog : Window
{
    internal ImportedRouting? Result { get; private set; }

    internal RoutingDialog(Window owner, ImportedRouting? current)
    {
        Owner = owner;
        Title = current is null ? "新建分流配置" : "编辑分流配置";
        Width = 700;
        Height = 660;
        MinWidth = 530;
        MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var sheet = new DockPanel { Margin = new Thickness(20) };
        Content = sheet;

        var help = new TextBlock { Text = "导入 Shadowrocket .conf 文件或粘贴原文。PROXY 使用节点页的当前节点，DIRECT 直连。", TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(help, Dock.Top);
        sheet.Children.Add(help);

        var toolbar = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(toolbar, Dock.Top);
        sheet.Children.Add(toolbar);
        var open = Button("导入文件…", "ReadRoutingFile");
        toolbar.Children.Add(open);
        var load = Button("读取 Clash 订阅…", "LoadRoutingSubscription");
        toolbar.Children.Add(load);
        var nameBox = new TextBox { Text = current?.Name ?? "", MaxLength = 80, Margin = new Thickness(0, 0, 0, 10) };
        AutomationProperties.SetAutomationId(nameBox, "RoutingName");
        var nameLabel = new Label { Content = "配置名称", Target = nameBox, Padding = new Thickness(0, 0, 0, 4) };
        DockPanel.SetDock(nameLabel, Dock.Top);
        sheet.Children.Add(nameLabel);
        DockPanel.SetDock(nameBox, Dock.Top);
        sheet.Children.Add(nameBox);
        var source = new TextBox { Text = current?.SubscriptionUrl ?? "", Margin = new Thickness(0, 0, 0, 8) };
        AutomationProperties.SetAutomationId(source, "RoutingSubscription");
        var sourceLabel = new Label { Content = "Clash 订阅地址（可选）", Target = source, Padding = new Thickness(0, 0, 0, 4) };
        DockPanel.SetDock(sourceLabel, Dock.Top);
        sheet.Children.Add(sourceLabel);
        DockPanel.SetDock(source, Dock.Top);
        sheet.Children.Add(source);
        var interval = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        var intervalLabel = new Label { Content = "刷新间隔（小时，0 表示仅手动）", Padding = new Thickness(0, 2, 8, 0) };
        var hours = new TextBox { Text = (current?.RefreshHours ?? 24).ToString(), Width = 56, MaxLength = 3 };
        AutomationProperties.SetAutomationId(hours, "RoutingRefreshHours");
        intervalLabel.Target = hours;
        interval.Children.Add(intervalLabel);
        interval.Children.Add(hours);
        interval.Visibility = source.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        DockPanel.SetDock(interval, Dock.Top);
        sheet.Children.Add(interval);

        var buttons = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(buttons, Dock.Bottom);
        sheet.Children.Add(buttons);
        var cancel = new Button { Content = "关闭", IsCancel = true };
        DockPanel.SetDock(cancel, Dock.Right);
        buttons.Children.Add(cancel);
        var apply = Button("保存", "ApplyRouting");
        apply.IsEnabled = current is not null;
        DockPanel.SetDock(apply, Dock.Right);
        buttons.Children.Add(apply);
        var preview = Button("预览规则", "PreviewRouting");
        buttons.Children.Add(preview);

        var feedback = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetAutomationId(feedback, "RoutingPreview");
        AutomationProperties.SetLiveSetting(feedback, AutomationLiveSetting.Polite);
        var scroll = new ScrollViewer { Content = feedback, MaxHeight = 150, Margin = new Thickness(0, 8, 0, 0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        DockPanel.SetDock(scroll, Dock.Bottom);
        sheet.Children.Add(scroll);
        var text = new TextBox
        {
            Text = current?.Text ?? "", AcceptsReturn = true, AcceptsTab = true, FontFamily = new FontFamily("Consolas"),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        AutomationProperties.SetName(text, "分流配置原文");
        AutomationProperties.SetAutomationId(text, "RoutingText");
        sheet.Children.Add(text);

        string? loadedSource = current?.SubscriptionUrl;
        DateTimeOffset? loadedAt = current?.RefreshedAt;
        text.IsReadOnly = loadedSource is not null;
        void InvalidatePreview()
        {
            apply.IsEnabled = false;
            feedback.Text = "";
        }
        text.TextChanged += (_, _) => InvalidatePreview();
        source.TextChanged += (_, _) =>
        {
            interval.Visibility = source.Text.Trim().Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            text.IsReadOnly = source.Text.Trim().Length > 0;
            InvalidatePreview();
        };

        ImportedRouting Draft()
        {
            string? subscription = null;
            int every = 24;
            if (!string.IsNullOrWhiteSpace(source.Text))
            {
                subscription = SubscriptionLink.Parse(source.Text).Address.AbsoluteUri;
                if (subscription != loadedSource)
                    throw new InvalidDataException("请先读取这个 Clash 订阅。");
                if (!int.TryParse(hours.Text, out every) || every is < 0 or > 168)
                    throw new InvalidDataException("刷新间隔请填写 0 至 168 小时。");
            }
            return new(current?.Id ?? Guid.NewGuid(), nameBox.Text, text.Text, subscription, every,
                subscription is null ? null : loadedAt, current?.Selections);
        }
        preview.Click += (_, _) =>
        {
            try
            {
                var draft = Draft();
                var report = draft.Parse().Report();
                feedback.Text = (draft.IsClash
                        ? $"Clash 分流 · {report.RuleCount} 条规则 · 默认 {report.Final} · DNS {report.DnsServer}"
                        : $"可用规则 {report.RuleCount} 条 · 直连例外 {report.BypassCount} 条 · 默认 {report.Final}")
                    + (report.Warnings.Length == 0 ? "" : "\n\n" + string.Join("\n", report.Warnings));
                apply.Content = report.Warnings.Length == 0 ? "保存" : "确认提示并保存";
                apply.IsEnabled = true;
            }
            catch (InvalidDataException error) { feedback.Text = error.Message; apply.IsEnabled = false; }
        };
        apply.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(nameBox.Text))
            {
                feedback.Text = "请输入配置名称。";
                return;
            }
            try
            {
                Result = Draft();
                DialogResult = true;
            }
            catch (InvalidDataException error) { feedback.Text = error.Message; }
        };
        load.Click += async (_, _) =>
        {
            load.IsEnabled = open.IsEnabled = preview.IsEnabled = source.IsEnabled = false;
            InvalidatePreview();
            try
            {
                var link = SubscriptionLink.Parse(source.Text);
                feedback.Text = "正在读取 Clash 订阅…";
                string yaml = await Subscription.FetchClashAsync(link.Address);
                ClashConfiguration.Parse(yaml);
                loadedSource = link.Address.AbsoluteUri;
                loadedAt = DateTimeOffset.UtcNow;
                text.Text = yaml;
                if (string.IsNullOrWhiteSpace(nameBox.Text))
                    nameBox.Text = link.Name;
                feedback.Text = "已读取订阅。点击「预览规则」查看兼容提示。";
            }
            catch (InvalidDataException error) { feedback.Text = error.Message; }
            finally { load.IsEnabled = open.IsEnabled = preview.IsEnabled = source.IsEnabled = true; }
        };
        open.Click += (_, _) =>
        {
            var picker = new Microsoft.Win32.OpenFileDialog
            {
                Title = "导入分流配置", Filter = "分流配置 (*.yaml;*.yml;*.conf;*.srconf)|*.yaml;*.yml;*.conf;*.srconf|文本文件 (*.txt)|*.txt|所有文件|*.*"
            };
            if (picker.ShowDialog(this) != true)
                return;
            try
            {
                using var file = File.OpenRead(picker.FileName);
                if (file.Length > ClashYaml.MaxBytes)
                    throw new InvalidDataException("配置文件不能超过 2 MB。");
                byte[] data = new byte[file.Length];
                file.ReadExactly(data);
                string original = new UTF8Encoding(false, true).GetString(data);
                source.Clear();
                loadedSource = null;
                loadedAt = null;
                text.IsReadOnly = false;
                text.Text = original;
                if (string.IsNullOrWhiteSpace(nameBox.Text))
                    nameBox.Text = Path.GetFileNameWithoutExtension(picker.FileName);
                feedback.Text = "已载入文件。点击「预览规则」查看兼容提示。";
            }
            catch (Exception error) when (error is IOException or InvalidDataException or DecoderFallbackException or UnauthorizedAccessException)
            {
                feedback.Text = error is InvalidDataException ? error.Message : "无法读取配置，请选择 UTF-8 文本文件。";
            }
        };
    }

    private static Button Button(string label, string id)
    {
        var button = new Button { Content = label, Margin = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetAutomationId(button, id);
        return button;
    }
}
