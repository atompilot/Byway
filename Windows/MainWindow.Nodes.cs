using System.Windows;

namespace Byway;

public partial class MainWindow
{
    private async void AddNodeClick(object sender, RoutedEventArgs e)
    {
        NodeGroup? destination = CurrentGroup is { IsSubscription: false } group ? group : null;
        var dialog = new NodeDialog(this, null);
        if (dialog.ShowDialog() == true && dialog.Result is { } node)
            await RunAsync(() => AddNodeAsync(node, destination));
    }

    private async Task<Node> AddNodeAsync(Node node, NodeGroup? destination)
    {
        var known = RowsInScope(LocalNodes).Find(row => NodeImport.SameNode(row.Node, node));
        if (known is null && !await Core.CheckAsync(node))
            throw new InvalidDataException($"「{node.Name}」未通过代理内核校验。");

        Node saved = known?.Node ?? node;
        var next = profile with
        {
            Nodes = known is null ? [..profile.Nodes, saved] : profile.Nodes,
            Selected = selected?.Node.Id ?? saved.Id
        };
        bool addedToGroup = destination is not null && !destination.Members.Contains(saved.Id);
        if (addedToGroup)
        {
            var nextGroup = destination! with { Members = [..destination!.Members, saved.Id] };
            next = next with { Groups = Groups.Select(group => group.Id == nextGroup.Id ? nextGroup : group).ToList() };
        }
        CommitProfile(next, destination?.Id ?? Guid.Empty);
        RevealNode(saved.Id);
        Status.Text = addedToGroup ? $"已将「{saved.Name}」添加到「{destination!.Name}」。"
            : known is null ? $"已添加「{saved.Name}」。" : $"「{saved.Name}」已在节点列表中。";
        return saved;
    }

    private async void EditNodeClick(object sender, RoutedEventArgs e)
    {
        if (NodeList.SelectedItem is not NodeRow row)
            return;

        var dialog = new NodeDialog(this, row.Node);
        if (dialog.ShowDialog() == true && dialog.Result is { } edited)
            await RunAsync(() => EditNodeAsync(row.Node, edited));
    }

    private async Task EditNodeAsync(Node current, Node edited)
    {
        bool endpointChanged = !NodeImport.SameEndpoint(current, edited);
        if (endpointChanged && !await Core.CheckAsync(edited))
            throw new InvalidDataException("新连接配置未通过代理内核校验，已保留原节点。");

        bool currentConnection = endpointChanged && active?.Source?.Id == current.Id;
        var groups = Groups.Select(group => group.IsSubscription && group.Members.Contains(current.Id)
            ? NodeGroups.SetNodeOverride(group, current, edited) : group).ToList();
        var next = profile with
        {
            Nodes = profile.Nodes.Select(node => node.Id == current.Id ? edited : node).ToList(),
            Groups = groups
        };
        CommitProfile(next, Scope.Id);
        RevealNode(edited.Id);
        Status.Text = $"已保存「{edited.Name}」。" + (currentConnection ? " 下次连接使用新配置。" : "");
    }

    private async void DeleteNodeClick(object sender, RoutedEventArgs e)
    {
        if (NodeList.SelectedItem is not NodeRow row)
            return;

        Node node = row.Node;
        if (active?.Source?.Id == node.Id)
        {
            ShowError("该节点正在使用。请先切换节点或停用代理。");
            return;
        }
        string detail = Groups.Any(group => group.IsSubscription && group.Members.Contains(node.Id))
            ? "从本机删除，刷新订阅时也会保留这项改动。" : "也会从包含它的节点组中移除。";
        if (MessageBox.Show(this, $"删除「{node.Name}」？{detail}", "删除节点",
                MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes)
            return;
        await RunAsync(() =>
        {
            DeleteNode(node);
            return Task.CompletedTask;
        });
    }

    private void DeleteNode(Node node)
    {
        EnsureActiveNodeSurvives([node.Id]);
        var remaining = profile.Nodes.Where(item => item.Id != node.Id).ToList();
        var groups = Groups.Select(group =>
        {
            if (!group.Members.Contains(node.Id))
                return group;
            if (group.IsSubscription)
                group = NodeGroups.SetNodeOverride(group, node, null);
            return group with { Members = group.Members.Where(id => id != node.Id).ToList() };
        }).ToList();
        Guid? selection = selected?.Node.Id == node.Id ? remaining.FirstOrDefault()?.Id : selected?.Node.Id;
        CommitProfile(profile with { Nodes = remaining, Groups = groups, Selected = selection }, Scope.Id);
        Status.Text = $"已删除「{node.Name}」。";
    }

    private void RevealNode(Guid id)
    {
        if (visibleNodes.Find(row => row.Node.Id == id) is { } row)
        {
            NodeList.SelectedItem = row;
            NodeList.ScrollIntoView(row);
        }
    }
}
