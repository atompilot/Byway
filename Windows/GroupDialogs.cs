using System.Windows;
using System.Windows.Controls;

namespace Byway;

internal sealed class SubscriptionDialog : Window
{
    internal SubscriptionLink? Link { get; private set; }

    internal SubscriptionDialog(Window owner)
    {
        Owner = owner;
        Title = L10n.Text("添加订阅");
        Width = 544;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        var panel = new StackPanel { Margin = new Thickness(20) };
        Content = panel;
        var text = new TextBox { Margin = new Thickness(0, 6, 0, 12) };
        System.Windows.Automation.AutomationProperties.SetAutomationId(text, "SubscriptionInput");
        panel.Children.Add(new Label { Content = L10n.Text("订阅链接"), Target = text, Padding = new Thickness(0) });
        panel.Children.Add(text);
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        panel.Children.Add(status);
        var buttons = new DockPanel { LastChildFill = false };
        panel.Children.Add(buttons);
        var qr = new Button { Content = L10n.Text("读取二维码图片…") };
        buttons.Children.Add(qr);
        var add = new Button { Content = L10n.Text("添加节点组"), IsDefault = true };
        DockPanel.SetDock(add, Dock.Right);
        buttons.Children.Add(add);
        var cancel = new Button { Content = L10n.Text("取消"), IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(cancel, Dock.Right);
        buttons.Children.Add(cancel);

        void Accept(string input)
        {
            try
            {
                Link = SubscriptionLink.Parse(input);
                DialogResult = true;
            }
            catch (InvalidDataException error) { status.Text = error.Message; }
        }

        add.Click += (_, _) => Accept(text.Text);
        qr.Click += async (_, _) =>
        {
            var picker = new Microsoft.Win32.OpenFileDialog
            {
                Title = L10n.Text("选择订阅二维码"),
                Filter = L10n.Text("图片 (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff")
            };
            if (picker.ShowDialog(this) != true)
                return;

            string path = picker.FileName;
            qr.IsEnabled = add.IsEnabled = false;
            try
            {
                string code = await Task.Run(() => QrImage.Read(path));
                if (IsVisible)
                    Accept(code);
            }
            catch (InvalidDataException error) { status.Text = error.Message; }
            catch (Exception error) when (error is IOException or NotSupportedException or ArgumentException or FormatException)
            {
                status.Text = L10n.Text("无法读取二维码图片。");
            }
            finally { qr.IsEnabled = add.IsEnabled = true; }
        };
        Loaded += (_, _) => text.Focus();
    }
}

internal sealed class GroupDialog : Window
{
    internal NodeGroup? Result { get; private set; }
    internal bool RemoveGroup { get; private set; }

    internal GroupDialog(Window owner, NodeGroup? group, IReadOnlyList<Node> nodes, Func<string, bool> nameExists)
    {
        Owner = owner;
        Title = group is null ? L10n.Text("新建节点组") : L10n.Text("节点组设置");
        Width = 500;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        var panel = new StackPanel { Margin = new Thickness(20) };
        Content = panel;
        var text = new TextBox { Text = group?.Name ?? "", MaxLength = 80, Margin = new Thickness(0, 6, 0, 12) };
        panel.Children.Add(new Label { Content = L10n.Text("组名"), Target = text, Padding = new Thickness(0) });
        panel.Children.Add(text);

        TextBox? address = null;
        if (group?.IsSubscription == true)
        {
            address = new TextBox { Text = group.SubscriptionAddress, Margin = new Thickness(0, 6, 0, 12) };
            System.Windows.Automation.AutomationProperties.SetAutomationId(address, "EditSubscriptionAddress");
            panel.Children.Add(new Label { Content = L10n.Text("订阅地址"), Target = address, Padding = new Thickness(0) });
            panel.Children.Add(address);
        }

        var list = new ListBox
        {
            MaxHeight = 300, ItemsSource = nodes, DisplayMemberPath = nameof(Node.Name),
            SelectionMode = SelectionMode.Multiple, Margin = new Thickness(0, 6, 0, 12)
        };
        if (group?.IsSubscription != true)
        {
            panel.Children.Add(new TextBlock { Text = L10n.Text("组内节点") });
            panel.Children.Add(list);
            foreach (Node node in nodes.Where(node => group?.Members.Contains(node.Id) == true))
                list.SelectedItems.Add(node);
        }

        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        panel.Children.Add(status);
        var buttons = new DockPanel { LastChildFill = false };
        panel.Children.Add(buttons);
        if (group is not null)
        {
            var remove = new Button { Content = group.IsSubscription ? L10n.Text("删除订阅组…") : L10n.Text("删除节点组…") };
            buttons.Children.Add(remove);
            remove.Click += (_, _) =>
            {
                string effect = group.IsSubscription ? L10n.Text("将移除订阅和它导入的节点。") : L10n.Text("组内的节点仍保留在节点列表。");
                if (MessageBox.Show(this, L10n.Format($"删除「{group.Name}」？{effect}"), L10n.Text("删除节点组"),
                        MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes)
                {
                    RemoveGroup = true;
                    DialogResult = true;
                }
            };
        }

        var save = new Button { Content = L10n.Text("保存"), IsDefault = true, MinWidth = 70 };
        DockPanel.SetDock(save, Dock.Right);
        buttons.Children.Add(save);
        var cancel = new Button { Content = L10n.Text("取消"), IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(cancel, Dock.Right);
        buttons.Children.Add(cancel);
        save.Click += (_, _) =>
        {
            string name = Subscription.SafeName(text.Text, "");
            if (name.Length == 0 || nameExists(name))
            {
                status.Text = name.Length == 0 ? L10n.Text("请输入组名。") : L10n.Text("已有同名节点组。");
                return;
            }
            List<Guid> members = group?.IsSubscription == true
                ? group.Members : list.SelectedItems.Cast<Node>().Select(node => node.Id).ToList();
            string? subscription = null;
            try { if (address is not null) subscription = SubscriptionLink.Parse(address.Text ?? "").Address.AbsoluteUri; }
            catch (InvalidDataException error) { status.Text = error.Message; return; }
            if (group?.IsSubscription == true && subscription != group.SubscriptionAddress)
            {
                string message = L10n.Text("新订阅通过校验后，将替换原有组成员。");
                if (group.Overrides is { Count: > 0 })
                    message += L10n.Text(" 旧订阅的本机节点修改也会随之移除。");
                if (MessageBox.Show(this, message, L10n.Text("更换订阅地址"), MessageBoxButton.OKCancel,
                        MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK)
                    return;
            }
            Result = group is null ? new(Guid.NewGuid(), name, null, members)
                : group with { Name = name, Members = members, SubscriptionAddress = subscription };
            DialogResult = true;
        };
        Loaded += (_, _) => text.Focus();
    }
}
