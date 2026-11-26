using System.Windows.Markup;

namespace Byway;

[MarkupExtensionReturnType(typeof(string))]
public sealed class LocExtension(string source) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => L10n.Text(source);
}
