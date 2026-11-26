using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Interop;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;

namespace Byway;

public partial class MainWindow
{
    private static readonly JsonSerializerOptions ApiJson = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 32
    };

    private async Task<IResult> DispatchApiAsync(HttpContext context, bool fromLan)
    {
        HttpRequest request = context.Request;
        string path = request.Path.Value ?? "";
        bool hasBody = context.Features.Get<IHttpRequestBodyDetectionFeature>()?.CanHaveBody == true;
        JsonElement body = default;
        string? scanned = null;
        if (request.Method == "POST" && path == "/v1/qr/decode")
        {
            if (!hasBody)
                throw new ApiError(400, L10n.Text("请上传二维码图片。"));
            using var stream = new MemoryStream();
            await request.Body.CopyToAsync(stream, context.RequestAborted);
            stream.Position = 0;
            try { scanned = QrImage.Read(stream); }
            catch (Exception error) when (error is NotSupportedException or FormatException or ArgumentException)
            {
                throw new ApiError(422, L10n.Text("无法读取这张二维码图片。"));
            }
        }
        else if (hasBody)
        {
            var limit = context.Features.Get<IHttpMaxRequestBodySizeFeature>();
            if (limit?.IsReadOnly == false)
                limit.MaxRequestBodySize = path.StartsWith("/v1/config/routing", StringComparison.Ordinal)
                    ? 16 * 1024 * 1024 : 4 * 1024 * 1024;
            if (!request.HasJsonContentType())
                throw new ApiError(415, L10n.Text("请求正文需要 application/json。"));
            using var parsed = await JsonDocument.ParseAsync(request.Body, new JsonDocumentOptions { MaxDepth = 32 }, context.RequestAborted);
            body = parsed.RootElement.Clone();
        }

        string[] segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return await Dispatcher.InvokeAsync(() =>
        {
            context.RequestAborted.ThrowIfCancellationRequested();
            if (exiting || aiServer is null || fromLan && profile.Ai?.LanEnabled != true)
                throw new ApiError(503, L10n.Text("Byway API 已暂停。"));
            if (!aiServer.MatchesToken(request))
                throw new ApiError(401, L10n.Text("访问令牌已失效。"));
            if (request.Method == "GET" || scanned is not null)
                return ReadApiAsync(path, segments, request, scanned);

            if (busy || startingAi || ComponentDispatcher.IsThreadModal)
                throw new ApiError(409, L10n.Text("Byway 正在处理操作，请稍后重试。"));
            return RunExclusiveAsync(() => ChangeApiAsync(path, segments, request.Method, body, fromLan));
        }).Task.Unwrap();
    }

    private async Task<IResult> ReadApiAsync(string path, string[] segments, HttpRequest request, string? scanned)
    {
        if (scanned is not null)
            return Results.Json(new { code = scanned });

        switch (path)
        {
            case "/v1/guide":
                return Results.Text(L10n.Format($"设备 {TryReadDevice()?.DisplayName ?? "Windows"}\nAPI 地址 {request.Scheme}://{request.Host}\n\n{AiGuide.Value}"),
                    "text/plain; charset=utf-8");
            case "/v1/skill": return Results.Text(AiSkill.Value, "text/markdown; charset=utf-8");
            case "/v1/device": return Results.Json(TryReadDevice() ?? throw new ApiError(503, L10n.Text("无法读取设备身份。")));
            case "/v1/status": return Results.Json(ApiStatus());
            case "/v1/private-network":
            case "/v1/private-network/config":
            case "/v1/private-network/relays": return Results.Json(await ReadPrivateNetworkAsync());
            case "/v1/private-network/peers":
                return Results.Json((await ReadPrivateNetworkAsync()).Runtime?.Peers ?? []);
            case "/v1/nodes": return Results.Json(nodes.Select(ApiNode).ToArray());
            case "/v1/groups": return Results.Json(Groups.Select(ApiGroup).ToArray());
            case "/v1/config": return Results.Json(ProxyConfiguration());
            case "/v1/config/shadowrocket": return Results.Json(RoutingSnapshot(shadowrocketOnly: true));
            case "/v1/config/routing": return Results.Json(RoutingSnapshot());
            case "/v1/settings": return Results.Json(DesktopSettings());
            case "/v1/statistics": return Results.Json(trafficStats);
            case "/v1/statistics/history":
            {
                var period = request.Query["range"].ToString() switch
                {
                    "" or "today" => TrafficPeriod.Today,
                    "yesterday" => TrafficPeriod.Yesterday,
                    "last7days" => TrafficPeriod.Last7Days,
                    "last30days" => TrafficPeriod.Last30Days,
                    "all" => TrafficPeriod.All,
                    _ => throw new ApiError(422, L10n.Text("range 须为 today、yesterday、last7days、last30days 或 all。"))
                };
                return Results.Json(trafficHistory.Read(period, DateTimeOffset.UtcNow, TimeZoneInfo.Local));
            }
            case "/v1/connections":
                return await ReadActiveConnectionsAsync() is { } rows ? Results.Json(rows) :
                    throw new ApiError(503, L10n.Text("暂时无法读取连接。"));
            case "/v1/diagnostics/engine": return Results.Json(engineLog.Snapshot());
            case "/v1/ai": return Results.Json(ApiConnection());
            case "/v1/discovery": return Results.Json(DiscoveryState());
        }

        if (segments is ["v1", "nodes", var nodeId])
            return Results.Json(ApiNode(FindNode(nodeId)));
        if (segments is ["v1", "groups", var groupId])
            return Results.Json(ApiGroup(FindGroup(groupId)));
        if (segments is ["v1", "config", "shadowrocket", var configurationId])
            return Results.Json(RoutingDetails(FindRouting(RoutingId(configurationId), shadowrocketOnly: true)));
        if (segments is ["v1", "config", "routing", var routingId])
            return Results.Json(RoutingDetails(FindRouting(RoutingId(routingId)), request.Query["includeText"] == "1"));
        if (segments is ["v1", "nodes", var sharedNode, "share"])
            return await ApiShareAsync(ShareCodes.ForNode(FindNode(sharedNode).Node), request.Query["qr"]);
        if (segments is ["v1", "groups", var sharedGroup, "share"])
            return await ApiShareAsync(GroupShareCode(FindGroup(sharedGroup)), request.Query["qr"]);

        throw new ApiError(404, L10n.Text("API 路径不存在。"));
    }

    private async Task<IResult> ChangeApiAsync(string path, string[] segments, string method, JsonElement body, bool fromLan)
    {
        switch (method, path)
        {
            case ("PUT", "/v1/private-network/config"):
                await ConfigurePrivateNetworkAsync(Input<PrivateNetworkInput>(body));
                return Results.Json(await ReadPrivateNetworkAsync());
            case ("POST", "/v1/private-network/join"):
                if (body.ValueKind != JsonValueKind.Undefined)
                    throw new ApiError(400, L10n.Text("入网密钥只能在本机提交。"));
                await SetPrivateNetworkAsync(true);
                return Results.Json(await ReadPrivateNetworkAsync(), statusCode: 202);
            case ("POST", "/v1/private-network/key"):
                if (fromLan)
                    throw new ApiError(403, L10n.Text("入网密钥只能在本机提交。"));
                await ApplyPrivateKeyAsync(Input<PrivateKeyInput>(body).Key);
                return Results.Json(await ReadPrivateNetworkAsync(), statusCode: 202);
            case ("PUT", "/v1/private-network/state"):
                await SetPrivateNetworkAsync(Input<ProxyInput>(body).Enabled ?? throw new ApiError(400, L10n.Text("请提供 enabled。")));
                return Results.Json(await ReadPrivateNetworkAsync());
            case ("DELETE", "/v1/private-network/membership"):
                await SavePrivateNetworkAsync(null);
                return Results.Json(await ReadPrivateNetworkAsync());
            case ("POST", "/v1/private-network/probe"):
                return Results.Json(await ProbePrivateNetworkAsync(Input<PrivateProbeInput>(body).Address));
            case ("PATCH", "/v1/device"):
            {
                string name = Input<DeviceNameInput>(body).DisplayName ?? throw new ApiError(400, L10n.Text("请提供 displayName。"));
                return Results.Json(RenameDevice(name));
            }
            case ("PUT", "/v1/proxy"):
            {
                bool enable = Input<ProxyInput>(body).Enabled ?? throw new ApiError(400, L10n.Text("请提供 enabled。"));
                await SetProxyEnabledAsync(enable);
                return Results.Json(ApiStatus());
            }
            case ("POST", "/v1/nodes"):
            {
                var input = Input<NodeInput>(body);
                var group = input.GroupId is Guid id ? FindGroup(id.ToString()) : null;
                if (group?.IsSubscription == true)
                    throw new ApiError(409, L10n.Text("订阅节点通过订阅刷新加入。请指定手动组。"));
                var node = ParseNode(input.Link);
                node = node with { Name = Subscription.SafeName(input.Name ?? "", node.Name) };
                var saved = await AddNodeAsync(node, group);
                return Results.Json(ApiNode(FindNode(saved.Id.ToString())), statusCode: 201);
            }
            case ("POST", "/v1/nodes/probe"):
                return await ProbeApiAsync(nodes.ToArray());
            case ("POST", "/v1/groups"):
                return await CreateGroupApiAsync(Input<GroupInput>(body));
            case ("PATCH", "/v1/config"):
            {
                var input = Input<ConfigInput>(body);
                if (input.GlobalTarget is not null)
                    throw new ApiError(422, L10n.Text("全局模式使用当前节点，请调用 /v1/nodes/{id}/select。"));
                if (input is { Bypass: null, MixedPort: null, Mode: null, CaptureMode: null })
                    throw new ApiError(400, L10n.Text("请提供需要修改的代理配置。"));
                var capture = input.CaptureMode?.ToLowerInvariant() switch
                {
                    null => Options.Capture,
                    "system" => CaptureMode.SystemProxy,
                    "manual" => CaptureMode.Manual,
                    "tun" when Program.IsElevated => CaptureMode.Tun,
                    "tun" => throw new ApiError(403, L10n.Text("请先以管理员身份重启这台 PC 上的 Byway，再切换到全流量模式。")),
                    _ => throw new ApiError(422, L10n.Text("接管方式须为 system、tun 或 manual。"))
                };
                string previousBypass = Options.Bypass;
                await ApplyProxyOptionsAsync(Options with { Bypass = input.Bypass ?? previousBypass,
                    MixedPort = input.MixedPort ?? Options.MixedPort, RouteMode = input.Mode is null ? Options.RouteMode : ParseMode(input.Mode), Capture = capture });
                if (BypassInput.Text == previousBypass.Replace(";", Environment.NewLine))
                    BypassInput.Text = Options.Bypass.Replace(";", Environment.NewLine);
                if (input.MixedPort is not null || input.Mode is not null || input.CaptureMode is not null)
                    SyncProxyControls();
                return Results.Json(ProxyConfiguration());
            }
            case ("POST", "/v1/config/shadowrocket/preview"):
            {
                string text = Input<RoutingPreviewInput>(body).Text ?? throw new ApiError(400, L10n.Text("请提供 text。"));
                return Results.Json(ShadowrocketConfiguration.Parse(text).Report());
            }
            case ("POST", "/v1/config/routing/test-rule"):
            {
                var input = Input<RoutingRuleTestInput>(body);
                return Results.Json(await TestRoutingRuleAsync(input.Id is Guid id ? FindRouting(id) : null, input.Host));
            }
            case ("POST", "/v1/config/shadowrocket"):
            {
                var input = Input<RoutingCreateInput>(body);
                string text = input.Text ?? throw new ApiError(400, L10n.Text("请提供 text。"));
                string name = input.Name ?? throw new ApiError(400, L10n.Text("请提供 name。"));
                if (CheckRoutingWarnings(ShadowrocketConfiguration.Parse(text), input.AcceptWarnings) is { } warning)
                    return warning;
                var entry = new ImportedRouting(Guid.NewGuid(), name, text);
                await SaveRoutingEntryAsync(entry, input.Activate == true);
                return Results.Json(RoutingDetails(FindRouting(entry.Id)), statusCode: 201);
            }
            case ("POST", "/v1/config/routing/preview"):
            {
                var input = Input<RoutingSourceInput>(body);
                var entry = await PrepareRoutingAsync(input.Text, input.Subscription);
                var parsed = entry.Parse();
                return Results.Json(new
                {
                    format = entry.IsClash ? "clash" : "shadowrocket",
                    report = parsed.Report(), groups = (parsed as ClashConfiguration)?.Groups
                });
            }
            case ("POST", "/v1/config/routing/migrate-clash/preview"):
            {
                var draft = await PreviewClashMigrationAsync();
                return Results.Json(new
                {
                    draft.Revision, draft.Entry.Name, draft.UpdatesExisting, report = draft.Configuration.Report(),
                    groups = draft.Configuration.Groups, subscription = draft.Entry.SubscriptionUrl is not null,
                    draft.BypassCount, mixedPort = draft.Settings.MixedPort, mode = draft.Settings.RouteMode.ToString().ToLowerInvariant()
                });
            }
            case ("POST", "/v1/config/routing/migrate-clash"):
            {
                var input = Input<ClashMigrationInput>(body);
                var draft = await PreviewClashMigrationAsync();
                if (input.Revision != draft.Revision)
                    throw new ApiError(409, L10n.Text("Clash 配置已变化，请重新预览后再迁移。"));
                if (CheckRoutingWarnings(draft.Configuration, input.AcceptWarnings) is { } warning)
                    return warning;
                await SaveClashMigrationAsync(draft);
                return Results.Json(RoutingDetails(draft.Entry));
            }
            case ("POST", "/v1/config/routing"):
            {
                var input = Input<RoutingCreateInput>(body);
                string name = input.Name ?? throw new ApiError(400, L10n.Text("请提供 name。"));
                var entry = (await PrepareRoutingAsync(input.Text, input.Subscription)) with
                {
                    Name = name, RefreshHours = input.RefreshHours ?? 24, Selections = input.Selections
                };
                var parsed = entry.Parse();
                if (input.Selections is { } choices && (parsed is not ClashConfiguration clash ||
                    choices.Any(choice => !clash.Groups.Any(group => group.Name == choice.Key && group.Selected == choice.Value))))
                    throw new InvalidDataException(L10n.Text("策略组或其成员不存在。"));
                if (CheckRoutingWarnings(parsed, input.AcceptWarnings) is { } warning)
                    return warning;
                await SaveRoutingEntryAsync(entry, input.Activate == true);
                return Results.Json(RoutingDetails(FindRouting(entry.Id)), statusCode: 201);
            }
            case ("PUT", "/v1/config/shadowrocket/active"):
            case ("PUT", "/v1/config/routing/active"):
            {
                var input = Input<RoutingSelectionInput>(body);
                if (!body.EnumerateObject().Any(item => item.NameEquals("id")))
                    throw new ApiError(400, L10n.Text("请明确提供 id。使用 null 切回默认配置。"));
                bool shadowrocketOnly = path == "/v1/config/shadowrocket/active";
                if (shadowrocketOnly && input.Id is Guid id)
                    FindRouting(id, shadowrocketOnly: true);
                await SelectRoutingAsync(input.Id);
                return Results.Json(RoutingSnapshot(shadowrocketOnly));
            }
            case ("PATCH", "/v1/settings"):
            {
                var input = Input<SettingsInput>(body);
                bool windowWidthOnly = input is { CloseToTray: null, StartAtLogin: null, ResumeProxy: null };
                if (windowWidthOnly && input.SidebarWidth is null)
                    throw new ApiError(400, L10n.Text("请提供需要修改的设置。"));
                if (input.SidebarWidth is double width && (!double.IsFinite(width) || width != ClampSidebarWidth(width)))
                    throw new ApiError(422, L10n.Format($"侧栏宽度须在 {SidebarColumn.MinWidth} 到 {SidebarColumn.MaxWidth} 之间。"));
                bool start = input.StartAtLogin ?? Options.StartAtLogin;
                var options = Options with
                {
                    CloseToTray = input.CloseToTray ?? Options.CloseToTray,
                    StartAtLogin = start,
                    ResumeProxy = input.ResumeProxy ?? (start && Options.ResumeProxy),
                    SidebarWidth = input.SidebarWidth ?? Options.SidebarWidth
                };
                if (windowWidthOnly)
                    SaveOptions(Options with { SidebarWidth = options.SidebarWidth });
                else
                {
                    ApplyStartupOptions(options);
                    ReadStartupControls();
                }
                if (input.SidebarWidth is not null)
                    ApplySidebarWidth();
                return Results.Json(DesktopSettings());
            }
            case ("DELETE", "/v1/connections"):
                await DisconnectAsync(null);
                return Results.Json(new { closed = "all" });
            case ("PATCH", "/v1/discovery"):
            {
                bool enabled = Input<DiscoveryInput>(body).Enabled ?? throw new ApiError(400, L10n.Text("请提供 enabled。"));
                return Results.Json(SetDiscoveryEnabled(enabled));
            }
            case ("PUT", "/v1/ai"):
            {
                RequireLocal(fromLan);
                bool enabled = Input<LanInput>(body).LanEnabled ?? throw new ApiError(400, L10n.Text("请提供 lanEnabled。"));
                await ChangeLanAsync(enabled);
                return Results.Json(ApiConnection());
            }
            case ("POST", "/v1/ai/rotate-token"):
                RequireLocal(fromLan);
                return Results.Json(new { token = ReplaceAiToken() });
            case ("POST", "/v1/import"):
                return await ImportApiCodeAsync(ReadImportCode(Input<ImportInput>(body)));
            case ("POST", "/v1/import/shadowrocket"):
            {
                if (body.ValueKind != JsonValueKind.Array)
                    throw new ApiError(400, L10n.Text("请上传 Shadowrocket 节点 JSON 数组。"));
                using var stream = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(body.GetRawText()));
                return Results.Json(await ImportAsync(NodeImport.Read(stream)));
            }
            case ("POST", "/v1/import/camera"):
            {
                ShowWindow();
                var dialog = new ScanDialog(this);
                if (dialog.ShowDialog() != true || dialog.Result is not { } scanned)
                    throw new ApiError(409, L10n.Text("扫码已取消。"));
                return await ImportApiCodeAsync(scanned);
            }
        }

        return segments switch
        {
            ["v1", "nodes", var id] => await ChangeNodeApiAsync(FindNode(id), method, body),
            ["v1", "nodes", var id, "probe"] when method == "POST" => await ProbeApiAsync([FindNode(id)]),
            ["v1", "nodes", var id, "select"] when method == "POST" => await SelectApiAsync(FindNode(id)),
            ["v1", "groups", var id] => await ChangeGroupApiAsync(FindGroup(id), method, body),
            ["v1", "groups", var id, "probe"] when method == "POST" =>
                await ProbeApiAsync(RowsInScope(new("", FindGroup(id).Id))),
            ["v1", "groups", var id, "refresh"] when method == "POST" => await RefreshGroupApiAsync(FindGroup(id)),
            ["v1", "config", "shadowrocket", var id] =>
                await ChangeRoutingApiAsync(FindRouting(RoutingId(id), shadowrocketOnly: true), method, body, shadowrocketOnly: true),
            ["v1", "config", "routing", var id] => await ChangeRoutingApiAsync(FindRouting(RoutingId(id)), method, body),
            ["v1", "config", "routing", var id, "refresh"] when method == "POST" => await RefreshRoutingApiAsync(RoutingId(id)),
            ["v1", "config", "routing", var id, "rules"] when method == "POST" =>
                await AddRoutingRuleApiAsync(FindRouting(RoutingId(id)), Input<RoutingRuleInput>(body)),
            ["v1", "config", "routing", _, "groups"] when method == "PUT" =>
                throw new ApiError(410, L10n.Text("所有代理规则使用当前节点，请调用 /v1/nodes/{id}/select。")),
            ["v1", "connections", var id] when method == "DELETE" => await CloseConnectionApiAsync(id),
            _ => throw new ApiError(404, L10n.Text("API 路径不存在。"))
        };
    }

    private static async Task<ImportedRouting> PrepareRoutingAsync(string? text, string? subscription)
    {
        if ((text is null) == (subscription is null))
            throw new ApiError(400, L10n.Text("请提供 text 或 subscription 中的一项。"));
        if (subscription is null)
            return new(Guid.NewGuid(), "", text!);
        var link = SubscriptionLink.Parse(subscription);
        return new(Guid.NewGuid(), "", await Subscription.FetchClashAsync(link.Address),
            link.Address.AbsoluteUri, RefreshedAt: DateTimeOffset.UtcNow);
    }

    private async Task<IResult> AddRoutingRuleApiAsync(ImportedRouting entry, RoutingRuleInput input)
    {
        bool changed = await AddRoutingRuleAsync(entry, input.Type, input.Value, input.Policy, input.NoResolve ?? false);
        return Results.Json(new { entry.Id, changed, active = entry.Id == profile.SelectedRouting });
    }

    private async Task<IResult> RefreshRoutingApiAsync(Guid id)
    {
        await RefreshRoutingEntryAsync(id);
        return Results.Json(RoutingDetails(FindRouting(id)));
    }

    private async Task<IResult> ChangeRoutingApiAsync(ImportedRouting entry, string method, JsonElement body, bool shadowrocketOnly = false)
    {
        if (method == "DELETE")
        {
            await DeleteRoutingAsync(entry.Id);
            return Results.Json(new { deleted = entry.Id, activeId = profile.SelectedRouting });
        }
        if (method != "PATCH")
            throw new ApiError(405, L10n.Text("支持 PATCH 或 DELETE。"));
        var input = Input<RoutingPatchInput>(body);
        if (input.Name is null && input.Text is null && input.Subscription is null && input.RefreshHours is null)
            throw new ApiError(400, L10n.Text("请提供要修改的配置字段。"));
        if (shadowrocketOnly && (input.Subscription is not null || input.RefreshHours is not null))
            throw new ApiError(400, L10n.Text("Clash 订阅使用 /v1/config/routing。"));
        var next = entry with { Name = input.Name ?? entry.Name, RefreshHours = input.RefreshHours ?? entry.RefreshHours };
        if (!string.IsNullOrEmpty(input.Subscription))
        {
            var source = await PrepareRoutingAsync(input.Text, input.Subscription);
            next = next with { Text = source.Text, SubscriptionUrl = source.SubscriptionUrl, RefreshedAt = source.RefreshedAt };
        }
        else
        {
            next = next with { Text = input.Text ?? entry.Text };
            if (input.Subscription == "")
                next = next with { SubscriptionUrl = null, RefreshedAt = null };
        }
        if (next.Text != entry.Text || next.IsClash != entry.IsClash)
        {
            var parsed = shadowrocketOnly ? (IRoutingConfiguration)ShadowrocketConfiguration.Parse(next.Text) : next.Parse();
            if (CheckRoutingWarnings(parsed, input.AcceptWarnings) is { } warning)
                return warning;
        }
        await SaveRoutingEntryAsync(next, activate: false);
        return Results.Json(RoutingDetails(FindRouting(entry.Id)));
    }

    private static IResult? CheckRoutingWarnings(IRoutingConfiguration configuration, bool? accepted)
    {
        var report = configuration.Report();
        return report.Warnings.Length > 0 && accepted != true
            ? Results.Json(new { error = L10n.Text("请先查看并确认兼容提示。"), report }, statusCode: 422) : null;
    }

    private static Guid RoutingId(string input) => Guid.TryParse(input, out var id) ? id
        : throw new ApiError(404, L10n.Text("分流配置不存在。"));

    private async Task<IResult> ChangeNodeApiAsync(NodeRow row, string method, JsonElement body)
    {
        if (method == "DELETE")
        {
            DeleteNode(row.Node);
            return Results.Json(new { deleted = row.Node.Id });
        }
        if (method != "PATCH")
            throw new ApiError(405, L10n.Text("支持 PATCH 或 DELETE。"));

        var input = Input<NodePatch>(body);
        if (input.Name is null && input.Link is null)
            throw new ApiError(400, L10n.Text("请提供 name 或 link。"));
        Node original = row.Node;
        Node edited = input.Link is null ? original : ParseNode(input.Link).WithId(original.Id);
        await EditNodeAsync(original, edited with { Name = Subscription.SafeName(input.Name ?? original.Name, original.Name) });
        return Results.Json(ApiNode(FindNode(original.Id.ToString())));
    }

    private async Task<IResult> CreateGroupApiAsync(GroupInput input)
    {
        if (input.Subscription is not null)
        {
            if (input.Members is not null)
                throw new ApiError(400, L10n.Text("订阅组的成员由订阅提供。"));
            var link = SubscriptionLink.Parse(input.Subscription);
            link = link with { Name = Subscription.SafeName(input.Name ?? "", link.Name) };
            Guid id = await AddSubscriptionAsync(link);
            return Results.Json(ApiGroup(FindGroup(id.ToString())), statusCode: 201);
        }

        string name = Subscription.SafeName(input.Name ?? "", "");
        if (name.Length == 0)
            throw new ApiError(400, L10n.Text("请提供手动组的名称。"));
        var group = new NodeGroup(Guid.NewGuid(), name, null, ValidateMembers(input.Members ?? []));
        await SaveGroupAsync(null, group);
        return Results.Json(ApiGroup(group), statusCode: 201);
    }

    private async Task<IResult> ChangeGroupApiAsync(NodeGroup group, string method, JsonElement body)
    {
        if (method == "DELETE")
        {
            RemoveGroup(group);
            return Results.Json(new { deleted = group.Id });
        }
        if (method != "PATCH")
            throw new ApiError(405, L10n.Text("支持 PATCH 或 DELETE。"));

        var input = Input<GroupInput>(body);
        if (input.Name is null && input.Members is null && input.Subscription is null)
            throw new ApiError(400, L10n.Text("请提供 name、members 或 subscription。"));
        if (group.IsSubscription ? input.Members is not null : input.Subscription is not null)
            throw new ApiError(409, L10n.Text("手动组编辑成员，订阅组编辑订阅地址。"));

        var updated = group with
        {
            Name = Subscription.SafeName(input.Name ?? group.Name, group.Name),
            Members = input.Members is null ? group.Members : ValidateMembers(input.Members),
            SubscriptionAddress = input.Subscription is null ? group.SubscriptionAddress : SubscriptionLink.Parse(input.Subscription).Address.AbsoluteUri
        };
        await SaveGroupAsync(group, updated);
        return Results.Json(ApiGroup(FindGroup(group.Id.ToString())));
    }

    private async Task<IResult> RefreshGroupApiAsync(NodeGroup group)
    {
        if (!group.IsSubscription)
            throw new ApiError(409, L10n.Text("只有订阅组支持刷新。"));
        await LoadSubscriptionAsync(group, isNew: false);
        return Results.Json(ApiGroup(FindGroup(group.Id.ToString())));
    }

    private async Task<IResult> SelectApiAsync(NodeRow row)
    {
        await ChooseAsync(row);
        return Results.Json(ApiStatus());
    }

    private async Task<IResult> ProbeApiAsync(IReadOnlyList<NodeRow> rows)
    {
        await ProbeAsync(rows);
        return Results.Json(rows.Select(ApiNode).ToArray());
    }

    private async Task<IResult> ImportApiCodeAsync(ImportCode input)
    {
        Guid id = await ImportCodeAsync(input);
        if (input is ImportCode.NodeCode)
            return Results.Json(new { kind = "node", node = ApiNode(FindNode(id.ToString())) });
        return Results.Json(new { kind = "group", group = ApiGroup(FindGroup(id.ToString())) });
    }

    private static ImportCode ReadImportCode(ImportInput input)
    {
        if (input.Link is not null && input.Parts is null)
            return ImportCode.Parse(input.Link);
        if (input.Link is not null || input.Parts is not { Length: > 0 })
            throw new ApiError(400, L10n.Text("请提供 link 或 parts。"));
        var collector = new QrParts();
        foreach (string part in input.Parts)
        {
            if (string.IsNullOrWhiteSpace(part))
                throw new ApiError(400, L10n.Text("二维码内容不能为空。"));
            string? code = collector.Accept(part.Trim(), out _);
            if (code is not null)
                return ImportCode.Parse(code);
        }
        throw new ApiError(422, L10n.Text("请提供同组的全部二维码内容。"));
    }

    private static async Task<IResult> ApiShareAsync(string value, string? qr)
    {
        string[] parts = QrParts.Split(value);
        if (qr is null)
            return Results.Json(new { link = value, qrCount = parts.Length });
        if (!int.TryParse(qr, out int page) || page < 1 || page > parts.Length)
            throw new ApiError(404, L10n.Text("二维码页码不存在。"));
        return Results.Bytes(await Task.Run(() => QrImage.Png(parts[page - 1])), "image/png");
    }

    private object ApiStatus()
    {
        var deviceInfo = TryReadDevice();
        return new
        {
            platform = "windows",
            version = typeof(MainWindow).Assembly.GetName().Version!.ToString(3),
            device = deviceInfo?.DisplayName ?? "Windows",
            deviceInfo,
            connected = active is not null && !restorePending,
            restorePending,
            busy,
            mixedEndpoint = mixed?.Endpoint,
            captureMode = active is not null && !restorePending ? CaptureCode(active.Capture) : null,
            mode = Options.RouteMode.ToString().ToLowerInvariant(),
            routingConfigurationId = profile.SelectedRouting,
            usesImportedConfiguration = active is not null && !restorePending && profile.ActiveRouting is not null,
            selectedNodeId = selected?.Node.Id,
            activeNodeId = !restorePending ? active?.Source?.Id : null
        };
    }

    private object ProxyConfiguration() => new
    {
        Options.Bypass, Options.MixedPort, mode = Options.RouteMode.ToString().ToLowerInvariant(),
        captureMode = CaptureCode(Options.Capture), tunAvailable = Program.IsElevated
    };

    private object DesktopSettings() => new { Options.CloseToTray, Options.StartAtLogin, Options.ResumeProxy,
        Options.ProxyWanted, sidebarWidth = ClampSidebarWidth(Options.SidebarWidth), startupRegistered = LoginStartup.IsRegistered };

    private static string CaptureCode(CaptureMode capture) => capture switch
    {
        CaptureMode.Manual => "manual",
        CaptureMode.Tun => "tun",
        _ => "system"
    };

    private static RoutingMode ParseMode(string mode) => mode.ToLowerInvariant() switch
    {
        "rule" => RoutingMode.Rule,
        "global" => RoutingMode.Global,
        "direct" => RoutingMode.Direct,
        _ => throw new ApiError(422, L10n.Text("路由模式须为 rule、global 或 direct。"))
    };

    private async Task<IResult> CloseConnectionApiAsync(string id)
    {
        if (!Guid.TryParse(id, out var connection))
            throw new ApiError(404, L10n.Text("连接不存在。"));
        await DisconnectAsync(connection);
        return Results.Json(new { closed = connection });
    }

    private static object ApiNode(NodeRow row) => new
    {
        row.Node.Id, row.Node.Name, row.Node.Host, row.Node.Port, protocol = NodeImport.Text(row.Node.Outbound, "type"),
        protocolLabel = row.Protocol, test = row.Test, probe = row.Probe, succeeded = row.Probe?.Succeeded,
        lastTestedAtUtc = row.LastTestedAtUtc,
        groups = row.Groups.Select(group => new { group.Id, group.Name, kind = group.IsSubscription ? "subscription" : "manual" }).ToArray()
    };

    private static object ApiGroup(NodeGroup group) => new
    {
        group.Id, group.Name, kind = group.IsSubscription ? "subscription" : "manual",
        members = group.Members.ToArray(),
        info = group.Info is { } info ? new { info.UploadBytes, info.DownloadBytes, info.TotalBytes, info.RemainingBytes, info.ExpiresAt } : null
    };

    private object ApiConnection()
    {
        var (hostAddress, addresses) = AiLanConnection();
        return new
        {
            localAddress = AiServer.LocalAddress,
            lanEnabled = LanActive,
            lanHostAddress = hostAddress,
            lanAddresses = addresses,
            discovery = DiscoveryState()
        };
    }

    private NodeRow FindNode(string id) => Guid.TryParse(id, out Guid parsed) &&
        nodes.Find(row => row.Node.Id == parsed) is { } node ? node : throw new ApiError(404, L10n.Text("节点不存在。"));

    private NodeGroup FindGroup(string id) => Guid.TryParse(id, out Guid parsed) &&
        Groups.Find(group => group.Id == parsed) is { } item ? item : throw new ApiError(404, L10n.Text("节点组不存在。"));

    private List<Guid> ValidateMembers(IEnumerable<Guid> members)
    {
        var unique = members.Distinct().ToList();
        if (unique.Any(id => !profile.Nodes.Exists(node => node.Id == id)))
            throw new ApiError(422, L10n.Text("组成员中包含不存在的节点。"));
        return unique;
    }

    private static Node ParseNode(string? link) =>
        !string.IsNullOrWhiteSpace(link) && ImportCode.Parse(link) is ImportCode.NodeCode code ? code.Node :
            throw new ApiError(400, L10n.Text("请提供单个节点链接。"));

    private static T Input<T>(JsonElement body) where T : class => body.ValueKind == JsonValueKind.Object
        ? body.Deserialize<T>(ApiJson) ?? throw new ApiError(400, L10n.Text("请提供 JSON 正文。"))
        : throw new ApiError(400, L10n.Text("请提供 JSON 对象。"));

    private static void RequireLocal(bool fromLan)
    {
        if (fromLan)
            throw new ApiError(403, L10n.Text("请在 Byway 所在电脑上更改授权。"));
    }

    private sealed record NodeInput(string? Link, string? Name, Guid? GroupId);
    private sealed record NodePatch(string? Link, string? Name);
    private sealed record GroupInput(string? Name, Guid[]? Members, string? Subscription);
    private sealed record ImportInput(string? Link, string[]? Parts);
    private sealed record ProxyInput(bool? Enabled);
    private sealed record PrivateKeyInput(string? Key);
    private sealed record PrivateProbeInput(string? Address);
    private sealed record ConfigInput(string? Bypass, int? MixedPort, string? Mode, string? GlobalTarget, string? CaptureMode);
    private sealed record ClashMigrationInput(string? Revision, bool? AcceptWarnings);
    private sealed record RoutingPreviewInput(string? Text);
    private sealed record RoutingSourceInput(string? Text, string? Subscription);
    private sealed record RoutingCreateInput(string? Name, string? Text, bool? AcceptWarnings, bool? Activate,
        string? Subscription, int? RefreshHours, Dictionary<string, string>? Selections);
    private sealed record RoutingPatchInput(string? Name, string? Text, bool? AcceptWarnings, string? Subscription, int? RefreshHours);
    private sealed record RoutingSelectionInput(Guid? Id);
    private sealed record RoutingRuleTestInput(Guid? Id, string? Host);
    private sealed record RoutingRuleInput(string? Type, string? Value, string? Policy, bool? NoResolve);
    private sealed record SettingsInput(bool? CloseToTray, bool? StartAtLogin, bool? ResumeProxy, double? SidebarWidth);
    private sealed record LanInput(bool? LanEnabled);
}
