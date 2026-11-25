using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Byway;

internal static class LanFirewall
{
    internal const string ProvisionArgument = "--authorize-lan-firewall";
    private const int PrivateProfile = 2;
    private const int Tcp = 6;
    private const int Inbound = 1;
    private const int Allow = 1;
    private const int Cancelled = 1223;
    private const int RuleNotFound = unchecked((int)0x80070002);
    private const string LocalSubnet = "LocalSubnet";
    private static readonly string Port = AiServer.LanPort.ToString(CultureInfo.InvariantCulture);
    private static readonly string Executable = Environment.ProcessPath!;
    private static readonly string RuleName = "Byway-AI-LAN-" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Executable.ToUpperInvariant())))[..16];

    internal static bool IsAuthorized()
    {
        dynamic policy = Create("HNetCfg.FwPolicy2");
        dynamic? rules = null;
        try
        {
            rules = policy.Rules;
            return HasRule(rules);
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("无法读取 Windows 防火墙规则。", error);
        }
        finally
        {
            Release(rules);
            Release(policy);
        }
    }

    internal static async Task EnsureAuthorizedAsync(bool interactive)
    {
        if (IsAuthorized())
            return;
        if (!interactive)
            throw new ApiError(403, "当前版本需要 Windows 防火墙授权。请在 Byway 的「AI」页开启局域网控制。");

        if (Program.IsElevated)
            Provision();
        else
        {
            var info = new ProcessStartInfo(Executable) { UseShellExecute = true, Verb = "runas" };
            info.ArgumentList.Add(ProvisionArgument);
            try
            {
                using var helper = Process.Start(info) ?? throw new InvalidOperationException("无法启动 Windows 防火墙授权。");
                await helper.WaitForExitAsync();
                if (helper.ExitCode != 0)
                    throw new InvalidOperationException("Windows 防火墙未能授权当前 Byway。请检查防火墙或组织策略。");
            }
            catch (Win32Exception error) when (error.NativeErrorCode == Cancelled)
            {
                throw new InvalidOperationException("已取消 Windows 授权，局域网控制未开启。");
            }
            catch (Win32Exception error)
            {
                throw new InvalidOperationException("无法请求 Windows 防火墙授权。", error);
            }
        }

        if (!IsAuthorized())
            throw new InvalidOperationException("Windows 防火墙尚未放行当前版本。");
    }

    internal static int RunProvisioning()
    {
        if (!Program.IsElevated)
            return 1;
        try
        {
            Provision();
            return IsAuthorized() ? 0 : 1;
        }
        catch (Exception)
        {
            return 1;
        }
    }

    private static void Provision()
    {
        dynamic policy = Create("HNetCfg.FwPolicy2");
        dynamic? rules = null;
        dynamic? rule = null;
        try
        {
            rules = policy.Rules;
            if (HasRule(rules))
                return;
            rule = Create("HNetCfg.FWRule");
            rule.Name = RuleName;
            rule.Description = "Byway LAN API from the local subnet on private networks";
            rule.ApplicationName = Executable;
            rule.Protocol = Tcp;
            rule.LocalPorts = Port;
            rule.RemoteAddresses = LocalSubnet;
            rule.Profiles = PrivateProfile;
            rule.Direction = Inbound;
            rule.Action = Allow;
            rule.EdgeTraversal = false;
            rule.Enabled = true;
            rules.Add(rule);
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("Windows 防火墙未能授权当前 Byway。请检查防火墙或组织策略。", error);
        }
        finally
        {
            Release(rule);
            Release(rules);
            Release(policy);
        }
    }

    private static bool HasRule(dynamic rules)
    {
        dynamic? rule = null;
        try
        {
            rule = rules.Item(RuleName);
            return (bool)rule.Enabled && (int)rule.Profiles == PrivateProfile &&
                (int)rule.Direction == Inbound && (int)rule.Action == Allow &&
                (int)rule.Protocol == Tcp && !(bool)rule.EdgeTraversal &&
                string.Equals((string)rule.ApplicationName, Executable, StringComparison.OrdinalIgnoreCase) &&
                string.Equals((string)rule.LocalPorts, Port, StringComparison.Ordinal) &&
                string.Equals((string)rule.RemoteAddresses, LocalSubnet, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error.HResult == RuleNotFound)
        {
            return false;
        }
        finally { Release(rule); }
    }

    private static object Create(string progId)
    {
        var type = Type.GetTypeFromProgID(progId) ?? throw new InvalidOperationException("Windows 防火墙服务不可用。");
        return Activator.CreateInstance(type) ?? throw new InvalidOperationException("无法访问 Windows 防火墙服务。");
    }

    private static void Release(object? instance)
    {
        if (instance is not null)
            Marshal.ReleaseComObject(instance);
    }
}
