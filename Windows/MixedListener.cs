using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;

namespace Byway;

internal sealed class MixedListener : IDisposable
{
    private readonly TcpListener listener;
    private readonly CancellationTokenSource stop = new();
    private readonly ConcurrentDictionary<int, string> clients = new();
    private int targetPort;

    internal int Port { get; }
    internal string Endpoint => $"127.0.0.1:{Port}";
    internal int TargetPort
    {
        get => Volatile.Read(ref targetPort);
        set => Volatile.Write(ref targetPort, value);
    }

    internal MixedListener(int port)
    {
        listener = new(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
        try { listener.Start(); }
        catch (SocketException error)
        {
            listener.Stop();
            stop.Dispose();
            if (error.SocketErrorCode is SocketError.AddressAlreadyInUse or SocketError.AccessDenied)
                throw new InvalidOperationException(L10n.Format($"无法使用端口 {port}。请退出占用该端口的代理，或在「配置」中更换端口。"), error);
            throw;
        }
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = AcceptAsync(stop.Token);
    }

    private async Task AcceptAsync(CancellationToken cancellation)
    {
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellation).ConfigureAwait(false);
                _ = ForwardAsync(client, TargetPort, cancellation);
            }
        }
        catch (Exception error) when (cancellation.IsCancellationRequested &&
            error is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }

    internal string SourceFor(string source) =>
        IPEndPoint.TryParse(source, out var endpoint) && clients.TryGetValue(endpoint.Port, out var original) ? original : source;

    private async Task ForwardAsync(TcpClient incoming, int port, CancellationToken cancellation)
    {
        using var client = incoming;
        if (port == 0)
            return;
        using var upstream = new TcpClient();
        using var session = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        int upstreamPort = 0;
        try
        {
            client.NoDelay = upstream.NoDelay = true;
            await upstream.ConnectAsync(IPAddress.Loopback, port, session.Token).ConfigureAwait(false);
            upstreamPort = ((IPEndPoint)upstream.Client.LocalEndPoint!).Port;
            clients[upstreamPort] = client.Client.RemoteEndPoint?.ToString() ?? "";
            await Task.WhenAll(CopyAsync(client, upstream, session), CopyAsync(upstream, client, session)).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or SocketException or OperationCanceledException or ObjectDisposedException) { }
        finally
        {
            if (upstreamPort != 0)
                clients.TryRemove(upstreamPort, out _);
        }
    }

    private static async Task CopyAsync(TcpClient source, TcpClient destination, CancellationTokenSource session)
    {
        try
        {
            await source.GetStream().CopyToAsync(destination.GetStream(), session.Token).ConfigureAwait(false);
            destination.Client.Shutdown(SocketShutdown.Send);
        }
        catch (Exception error) when (error is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
        {
            await session.CancelAsync().ConfigureAwait(false);
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        stop.Dispose();
    }
}
