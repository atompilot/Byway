using System.Text;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.RepresentationModel;

namespace Byway;

internal static class ClashYaml
{
    internal const int MaxBytes = 2 * 1024 * 1024;

    internal static YamlMappingNode Read(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > MaxBytes)
            throw new InvalidDataException("请提供不超过 2 MB 的 UTF-8 Clash YAML。");
        try
        {
            using var reader = new StringReader(text.TrimStart('\uFEFF'));
            var stream = new YamlStream();
            stream.Load(new BoundedParser(new Parser(reader)));
            return stream.Documents.Count == 1 ? Mapping(stream.Documents[0].RootNode, "配置") :
                throw new InvalidDataException("Clash YAML 必须包含一份配置。");
        }
        catch (YamlException error)
        {
            throw new InvalidDataException($"无法读取 Clash YAML（第 {error.Start.Line} 行）。");
        }
    }

    internal static YamlNode? Get(this YamlMappingNode map, string key) =>
        map.Children.TryGetValue(new YamlScalarNode(key), out var value) ? value : null;

    internal static YamlMappingNode Mapping(YamlNode? node, string label) =>
        node as YamlMappingNode ?? throw new InvalidDataException($"Clash 配置中的 {label} 必须是映射。");

    internal static string Scalar(YamlNode? node, string label) =>
        node is YamlScalarNode { Value: { } value } && value.Length > 0 ? value :
            throw new InvalidDataException($"Clash 配置中的 {label} 必须是非空文本。");

    internal static string Text(this YamlMappingNode map, string key, string? fallback = null) =>
        map.Get(key) is null && fallback is not null ? fallback : Scalar(map.Get(key), key);

    internal static bool Flag(this YamlMappingNode map, string key, bool fallback = false) =>
        map.Get(key) is null ? fallback : bool.TryParse(map.Text(key), out bool value) ? value :
            throw new InvalidDataException($"Clash 配置中的 {key} 必须是 true 或 false。");

    internal static IEnumerable<YamlNode> Sequence(YamlNode? node, string label) =>
        node is null ? [] : node is YamlSequenceNode sequence ? sequence.Children :
            throw new InvalidDataException($"Clash 配置中的 {label} 必须是列表。");

    internal static string[] Texts(YamlNode? node, string label) =>
        Sequence(node, label).Select(value => Scalar(value, label)).ToArray();

    internal static void CheckFields(this YamlMappingNode map, string label, params string[] supported)
    {
        foreach (var key in map.Children.Keys)
        {
            string field = Scalar(key, label);
            if (!supported.Contains(field, StringComparer.Ordinal))
                throw new InvalidDataException($"Clash 配置中的 {label} 含有暂不支持的字段 {field}。");
        }
    }

    private sealed class BoundedParser(IParser parser) : IParser
    {
        private int events;
        private int depth;
        public ParsingEvent? Current => parser.Current;

        public bool MoveNext()
        {
            if (!parser.MoveNext())
                return false;
            if (Current is MappingStart or SequenceStart)
                depth++;
            else if (Current is MappingEnd or SequenceEnd)
                depth--;
            if (++events > 250_000 || depth > 32)
                throw new InvalidDataException("Clash YAML 结构超出可导入范围。");
            return true;
        }
    }
}
