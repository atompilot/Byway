using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace Byway;

internal sealed class NodeDialog : Window
{
    internal Node? Result { get; private set; }

    internal NodeDialog(Window owner, Node? original)
    {
        Owner = owner;
        Title = original is null ? "添加节点" : "查看与编辑节点";
        Width = 550;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;

        var panel = new StackPanel { Margin = new Thickness(20) };
        Content = panel;
        string originalLink = original is null ? "" : ShareCodes.ForNode(original);
        if (original is not null)
        {
            string host = original.Host.Contains(':') ? $"[{original.Host}]" : original.Host;
            var endpoint = new TextBlock
            {
                Text = $"{original.ProtocolLabel}  ·  {host}:{original.Port}", Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap
            };
            AutomationProperties.SetAutomationId(endpoint, "NodeDetails");
            panel.Children.Add(endpoint);
        }

        var name = new TextBox { Text = original?.Name ?? "", MaxLength = 80, Margin = new Thickness(0, 6, 0, 12) };
        AutomationProperties.SetAutomationId(name, "NodeNameInput");
        panel.Children.Add(new Label { Content = "节点名称", Target = name, Padding = new Thickness(0) });
        panel.Children.Add(name);
        var link = new TextBox { Text = originalLink, TextWrapping = TextWrapping.Wrap, MinHeight = 70, MaxHeight = 150,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 12) };
        AutomationProperties.SetAutomationId(link, "NodeLinkInput");
        panel.Children.Add(new Label { Content = "连接链接（VLESS、VMess 或 Shadowsocks）", Target = link, Padding = new Thickness(0) });
        panel.Children.Add(link);

        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) };
        AutomationProperties.SetAutomationId(status, "NodeEditorStatus");
        panel.Children.Add(status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        panel.Children.Add(buttons);
        buttons.Children.Add(new Button { Content = "取消", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) });
        var save = new Button { Content = original is null ? "添加" : "保存", IsDefault = true, MinWidth = 70 };
        buttons.Children.Add(save);
        save.Click += (_, _) =>
        {
            try
            {
                Node node;
                string input = link.Text.Trim();
                if (original is not null && input == originalLink)
                    node = original;
                else if (ImportCode.Parse(input) is ImportCode.NodeCode single)
                    node = original is null ? single.Node : single.Node.WithId(original.Id);
                else
                    throw new InvalidDataException("请填写单个节点的连接链接。");

                string displayName = Subscription.SafeName(name.Text, node.Name);
                Result = node.Name == displayName ? node : node with { Name = displayName };
                DialogResult = true;
            }
            catch (InvalidDataException error) { status.Text = error.Message; }
        };
        Loaded += (_, _) => { if (original is null) link.Focus(); else name.Focus(); };
    }
}
