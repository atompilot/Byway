namespace Byway;

internal sealed record NodeGroup(Guid Id, string Name, string? SubscriptionAddress, List<Guid> Members,
    SubscriptionInfo? Info = null, List<SubscriptionNodeOverride>? Overrides = null)
{
    internal bool IsSubscription => SubscriptionAddress is not null;
}

internal sealed record SubscriptionNodeOverride(Node Source, string? Name = null, Node? Connection = null, bool Hidden = false)
{
    internal Node Apply(Node providerNode)
    {
        Node node = Connection ?? providerNode;
        string name = Name ?? providerNode.Name;
        return node.Name == name ? node : node with { Name = name };
    }
}

internal static class NodeGroups
{
    internal static ILookup<Guid, NodeGroup> ByMember(IEnumerable<NodeGroup> groups) =>
        groups.SelectMany(group => group.Members.Distinct().Select(id => (Id: id, Group: group)))
            .ToLookup(membership => membership.Id, membership => membership.Group);

    internal static NodeGroup SetNodeOverride(NodeGroup group, Node current, Node? edited)
    {
        var changes = group.Overrides ?? [];
        Node source = changes.Find(change => change.Source.Id == current.Id)?.Source ?? current;
        var next = changes.Where(change => change.Source.Id != current.Id).ToList();
        if (edited is null)
            next.Add(new(source, Hidden: true));
        else
        {
            string? name = edited.Name == source.Name ? null : edited.Name;
            Node? connection = NodeImport.SameEndpoint(source, edited) ? null : edited;
            if (name is not null || connection is not null)
                next.Add(new(source, name, connection));
        }
        return group with { Overrides = next.Count == 0 ? null : next };
    }

    internal static (List<Node> Nodes, List<SubscriptionNodeOverride>? Overrides) ApplySubscription(
        NodeGroup group, List<Node> previous, List<Node> fresh)
    {
        var changes = (group.Overrides ?? []).ToDictionary(change => change.Source.Id);
        var sources = previous.Where(node => !changes.ContainsKey(node.Id))
            .Concat(changes.Values.Select(change => change.Source)).ToList();
        var matched = Match(sources, fresh);
        var providerIds = matched.Select(node => node.Id).ToHashSet();
        List<Node> result = [];
        foreach (Node providerNode in matched)
        {
            if (changes.TryGetValue(providerNode.Id, out var change))
            {
                changes[providerNode.Id] = change with { Source = providerNode };
                if (!change.Hidden)
                    result.Add(change.Apply(providerNode));
            }
            else
                result.Add(providerNode);
        }
        // A locally configured connection remains available if the provider removes its original entry.
        result.AddRange(changes.Values.Where(change => change.Connection is not null && !providerIds.Contains(change.Source.Id))
            .Select(change => change.Apply(change.Source)));
        return (result, changes.Count == 0 ? null : changes.Values.ToList());
    }

    internal static List<Node> Match(List<Node> previous, List<Node> fresh)
    {
        var remaining = previous.ToList();
        var result = new Node?[fresh.Count];
        MatchBy(NodeImport.SameNode);
        MatchBy(NodeImport.SameEndpoint);

        // Some providers rotate server addresses while keeping logical node names stable.
        var uniqueNames = UniqueNames(previous).Intersect(UniqueNames(fresh)).ToHashSet();
        MatchBy((old, node) => old.Name == node.Name && uniqueNames.Contains(node.Name) &&
            old.Outbound.GetProperty("type").GetString() == node.Outbound.GetProperty("type").GetString());

        return fresh.Select((node, index) => result[index] ?? node).ToList();

        void MatchBy(Func<Node, Node, bool> predicate)
        {
            for (int index = 0; index < fresh.Count; index++)
            {
                if (result[index] is not null)
                    continue;
                var node = fresh[index];
                var match = remaining.Find(old => predicate(old, node));
                if (match is null)
                    continue;
                remaining.Remove(match);
                result[index] = NodeImport.SameNode(match, node) ? match : node.WithId(match.Id);
            }
        }
    }

    private static IEnumerable<string> UniqueNames(IEnumerable<Node> nodes) =>
        nodes.GroupBy(node => node.Name).Where(group => group.Count() == 1).Select(group => group.Key);
}
