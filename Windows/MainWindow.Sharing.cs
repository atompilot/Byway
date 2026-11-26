using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Byway;

public partial class MainWindow
{
    private async void ScanClick(object sender, RoutedEventArgs e)
    {
        var dialog = new ScanDialog(this);
        if (dialog.ShowDialog() != true || dialog.Result is not { } input)
            return;
        await RunAsync(() => ImportCodeAsync(input));
    }

    private Task<Guid> ImportCodeAsync(ImportCode input) => input switch
        {
            ImportCode.SubscriptionCode subscription => AddSubscriptionAsync(subscription.Link),
            ImportCode.NodeCode single => ImportSharedNodesAsync([single.Node]),
            ImportCode.GroupCode group => ImportSharedNodesAsync(group.Nodes, group.Name),
            _ => throw new InvalidDataException(L10n.Text("无法导入这个二维码。"))
        };

    private async Task<Guid> ImportSharedNodesAsync(IReadOnlyList<Node> incoming, string? groupName = null)
    {
        var existingLocal = RowsInScope(LocalNodes).Select(row => row.Node).ToList();
        List<Node> added = [];
        List<Guid> members = [];
        for (int index = 0; index < incoming.Count; index++)
        {
            Node node = incoming[index];
            Status.Text = L10n.Format($"正在校验节点 {index + 1} / {incoming.Count}…");
            var existing = existingLocal.Find(item => NodeImport.SameNode(item, node));
            if (existing is not null)
            {
                members.Add(existing.Id);
                continue;
            }
            if (!await Core.CheckAsync(node))
                throw new InvalidDataException(L10n.Format($"「{node.Name}」未通过代理内核校验。"));
            added.Add(node);
            members.Add(node.Id);
        }
        var next = profile with
        {
            Nodes = profile.Nodes.Concat(added).ToList(),
            Selected = selected?.Node.Id ?? members[0]
        };
        if (groupName is null)
        {
            if (added.Count > 0)
                CommitProfile(next, Guid.Empty);
            else
                GroupBox.SelectedItem = LocalNodes;

            NodeList.SelectedItem = visibleNodes.Find(row => row.Node.Id == members[0]);
            NodeList.ScrollIntoView(NodeList.SelectedItem);
            Status.Text = added.Count > 0 ? L10n.Format($"已导入「{incoming[0].Name}」。") : L10n.Format($"「{incoming[0].Name}」已在本地节点中。");
            return members[0];
        }

        var sameGroup = Groups.Find(group => !group.IsSubscription && group.Name == groupName &&
            group.Members.ToHashSet().SetEquals(members));
        if (sameGroup is not null)
        {
            GroupBox.SelectedItem = ((IEnumerable<GroupChoice>)GroupBox.ItemsSource).First(choice => choice.Id == sameGroup.Id);
            Status.Text = L10n.Text("该分享组已添加。");
            return sameGroup.Id;
        }
        var newGroup = new NodeGroup(Guid.NewGuid(), UniqueGroupName(groupName), null, members);
        CommitProfile(next with { Groups = [..Groups, newGroup] }, newGroup.Id);
        Status.Text = L10n.Format($"已添加「{newGroup.Name}」 · {newGroup.Members.Count} 个节点。");
        return newGroup.Id;
    }

    private string UniqueGroupName(string candidate)
    {
        string name = candidate;
        for (int number = 2; GroupNameExists(name, null); number++)
            name = $"{candidate} ({number})";
        return name;
    }

    private void NodeRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var clicked = e.OriginalSource as DependencyObject;
        var container = ItemsControl.ContainerFromElement(NodeList, clicked) as ListViewItem;
        NodeList.SelectedItem = container?.DataContext as NodeRow;
    }

    private void NodeMenuOpening(object sender, ContextMenuEventArgs e)
    {
        e.Handled = busy || NodeList.SelectedItem is not NodeRow;
    }

    private async void ProbeNodeClick(object sender, RoutedEventArgs e)
    {
        if (NodeList.SelectedItem is NodeRow row)
            await RunAsync(() => ProbeAsync([row]));
    }

    private void ShareNodeClick(object sender, RoutedEventArgs e)
    {
        if (NodeList.SelectedItem is NodeRow row)
            ShowShare(row.Node.Name, () => ShareCodes.ForNode(row.Node), false);
    }

    private void ShareGroupClick(object sender, RoutedEventArgs e)
    {
        if (CurrentGroup is not { } group)
            return;

        ShowShare(group.Name, () => GroupShareCode(group), !group.IsSubscription);
    }

    private string GroupShareCode(NodeGroup group) => group.IsSubscription ? ShareCodes.ForSubscription(group)
        : ShareCodes.ForGroup(group.Name, RowsInScope(new(group.Name, group.Id)).Select(row => row.Node).ToList());

    private void ShowShare(string name, Func<string> encode, bool bywayOnly)
    {
        try { new ShareDialog(this, name, encode(), bywayOnly).ShowDialog(); }
        catch (Exception error) when (error is InvalidDataException or ArgumentException)
        {
            ShowError(L10n.Text("无法生成分享二维码。") + (error is InvalidDataException ? error.Message : ""));
        }
    }
}
