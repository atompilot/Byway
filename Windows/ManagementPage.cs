using Microsoft.AspNetCore.Http;

namespace Byway;

internal static class ManagementPage
{
    private const string Policy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'";
    private static readonly IReadOnlyDictionary<string, (byte[] Body, string ContentType)> Assets =
        new Dictionary<string, (byte[], string)>
        {
            ["/"] = (Read("management.html"), "text/html; charset=utf-8"),
            ["/management.css"] = (Read("management.css"), "text/css; charset=utf-8"),
            ["/management.js"] = (Read("management.js"), "text/javascript; charset=utf-8")
        };

    private static byte[] Read(string name)
    {
        using var resource = typeof(ManagementPage).Assembly.GetManifestResourceStream("Byway.Web." + name)!;
        using var buffer = new MemoryStream();
        resource.CopyTo(buffer);
        return buffer.ToArray();
    }

    internal static bool IsAsset(HttpRequest request) =>
        HttpMethods.IsGet(request.Method) && Assets.ContainsKey(request.Path.Value ?? "");

    internal static bool AllowsRequest(HttpRequest request, bool asset)
    {
        string origin = request.Headers.Origin.ToString();
        string site = request.Headers["Sec-Fetch-Site"].ToString();
        if (origin.Length == 0 && site.Length == 0)
            return true;
        if (origin.Length > 0 && !origin.Equals($"{request.Scheme}://{request.Host}", StringComparison.Ordinal))
            return false;
        if (site.Length > 0 && site != "same-origin" && !(asset && site == "none"))
            return false;
        return asset || request.Method switch
        {
            "GET" => request.Path.Value is "/v1/device" or "/v1/status" or "/v1/nodes" or "/v1/config/routing" or "/v1/discovery",
            "PATCH" => request.Path.Value is "/v1/device" or "/v1/discovery",
            _ => false
        };
    }

    internal static IResult Asset(HttpContext context)
    {
        context.Response.Headers.ContentSecurityPolicy = Policy;
        context.Response.Headers.XContentTypeOptions = "nosniff";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";
        context.Response.Headers["X-Frame-Options"] = "DENY";
        var asset = Assets[context.Request.Path.Value!];
        return Results.Bytes(asset.Body, asset.ContentType);
    }
}
