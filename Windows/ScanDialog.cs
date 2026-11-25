using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

namespace Byway;

internal sealed class ScanDialog : Window
{
    private readonly QrParts parts = new();
    private readonly Button cameraButton = new() { Content = "开启相机", Margin = new Thickness(0, 0, 8, 0) };
    private readonly Button imageButton = new() { Content = "选择本地图片…", Margin = new Thickness(0, 0, 8, 0) };
    private readonly ComboBox cameras = new() { DisplayMemberPath = "DisplayName", Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 10) };
    private readonly Image preview = new() { Height = 294, Stretch = Stretch.Uniform, Visibility = Visibility.Collapsed };
    private readonly TextBlock status = new() { Text = "扫描节点或订阅二维码，或选择保存的二维码图片。", TextWrapping = TextWrapping.Wrap };
    private MediaCapture? camera;
    private MediaFrameReader? reader;
    private long lastFrame;
    private int handlingFrame;
    private volatile bool closed;
    private bool choosingImage;
    internal ImportCode? Result { get; private set; }

    internal ScanDialog(Window owner)
    {
        Owner = owner;
        Title = "扫码导入";
        Width = 578;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var content = new StackPanel { Margin = new Thickness(20) };
        Content = content;
        System.Windows.Automation.AutomationProperties.SetName(cameras, "相机");
        System.Windows.Automation.AutomationProperties.SetAutomationId(status, "ScanStatus");
        System.Windows.Automation.AutomationProperties.SetLiveSetting(status, System.Windows.Automation.AutomationLiveSetting.Polite);
        content.Children.Add(cameras);
        content.Children.Add(preview);
        status.Margin = new Thickness(0, 0, 0, 14);
        content.Children.Add(status);
        var controls = new DockPanel { LastChildFill = false };
        content.Children.Add(controls);
        var cancel = new Button { Content = "取消", IsCancel = true };
        DockPanel.SetDock(cancel, Dock.Right);
        controls.Children.Add(cancel);
        controls.Children.Add(cameraButton);
        controls.Children.Add(imageButton);
        var paste = new Button { Content = "粘贴链接" };
        controls.Children.Add(paste);
        cameraButton.Click += async (_, _) => await ToggleCameraAsync();
        imageButton.Click += async (_, _) => await OpenImageAsync();
        paste.Click += (_, _) =>
        {
            try { Accept(Clipboard.GetText()); }
            catch (ExternalException) { status.Text = "无法读取剪贴板，请重试。"; }
        };
        Closed += async (_, _) =>
        {
            closed = true;
            await StopCameraAsync();
        };
    }

    private void Accept(string text)
    {
        if (closed)
            return;
        try
        {
            string? value = parts.Accept(text.Trim(), out string? progress);
            if (value is null)
            {
                status.Text = progress;
                return;
            }
            Result = ImportCode.Parse(value);
            DialogResult = true;
        }
        catch (InvalidDataException error) { status.Text = error.Message; }
    }

    private async Task OpenImageAsync()
    {
        var picker = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择二维码图片",
            Filter = "图片 (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff"
        };
        choosingImage = true;
        imageButton.IsEnabled = false;
        try
        {
            if (picker.ShowDialog(this) != true)
                return;
            string path = picker.FileName;
            Accept(await Task.Run(() => QrImage.Read(path)));
        }
        catch (InvalidDataException error) { status.Text = error.Message; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException or FormatException)
        {
            status.Text = "无法读取这张图片。";
        }
        finally
        {
            choosingImage = false;
            imageButton.IsEnabled = true;
        }
    }

    private async Task ToggleCameraAsync()
    {
        cameraButton.IsEnabled = false;
        try
        {
            if (reader is not null)
            {
                await StopCameraAsync();
                preview.Source = null;
                preview.Visibility = Visibility.Collapsed;
                cameraButton.Content = "开启相机";
                cameras.IsEnabled = true;
                status.Text = "相机已关闭，可继续选择图片或粘贴链接。";
                return;
            }
            status.Text = "正在查找相机…";
            if (cameras.ItemsSource is null)
            {
                var options = (await MediaFrameSourceGroup.FindAllAsync())
                    .Where(group => group.SourceInfos.Any(source => source.SourceKind == MediaFrameSourceKind.Color)).ToList();
                if (closed)
                    return;
                if (options.Count == 0)
                {
                    status.Text = "未找到可用相机，可以选择本地图片扫码。";
                    return;
                }
                cameras.ItemsSource = options;
                cameras.SelectedIndex = 0;
                cameras.Visibility = options.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            }
            status.Text = "正在开启相机…";
            await StartCameraAsync((MediaFrameSourceGroup)cameras.SelectedItem);
            if (!closed)
            {
                preview.Visibility = Visibility.Visible;
                cameras.IsEnabled = false;
                cameraButton.Content = "关闭相机";
                status.Text = "将二维码对准相机。";
            }
        }
        catch (Exception error) when (error is UnauthorizedAccessException or COMException or InvalidOperationException)
        {
            status.Text = error is UnauthorizedAccessException
                ? "相机权限不可用，请检查 Windows 的桌面应用相机权限，或选择本地图片。"
                : "无法开启相机，请检查设备是否可用，或选择本地图片。";
        }
        finally { cameraButton.IsEnabled = true; }
    }

    private async Task StartCameraAsync(MediaFrameSourceGroup group)
    {
        var capture = new MediaCapture();
        MediaFrameReader? frames = null;
        bool adopted = false;
        try
        {
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = group, SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu, StreamingCaptureMode = StreamingCaptureMode.Video
            });
            if (closed)
                return;
            var source = capture.FrameSources.Values.Where(item => item.Info.SourceKind == MediaFrameSourceKind.Color)
                .OrderByDescending(item => item.Info.MediaStreamType == MediaStreamType.VideoPreview).FirstOrDefault();
            if (source is null)
                throw new InvalidOperationException();
            var format = source.CurrentFormat.VideoFormat;
            double scale = Math.Min(1, 960.0 / Math.Max(1, Math.Max(format.Width, format.Height)));
            var size = new BitmapSize
            {
                Width = Math.Max(1, (uint)(format.Width * scale)), Height = Math.Max(1, (uint)(format.Height * scale))
            };
            frames = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Argb32, size);
            frames.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            frames.FrameArrived += FrameArrived;
            if (await frames.StartAsync() != MediaFrameReaderStartStatus.Success)
                throw new InvalidOperationException();
            if (closed)
                return;
            reader = frames;
            camera = capture;
            adopted = true;
        }
        finally
        {
            if (!adopted)
                await ReleaseCameraAsync(frames, capture);
        }
    }

    private void FrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (closed || reader != sender || Interlocked.CompareExchange(ref handlingFrame, 1, 0) != 0)
            return;
        try
        {
            long now = Stopwatch.GetTimestamp();
            if (Stopwatch.GetElapsedTime(lastFrame, now).TotalMilliseconds < 150)
                return;
            lastFrame = now;
            using var frame = sender.TryAcquireLatestFrame();
            using var source = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (source is null)
                return;
            using var converted = source.BitmapPixelFormat == BitmapPixelFormat.Bgra8
                ? null : SoftwareBitmap.Convert(source, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            SoftwareBitmap bitmap = converted ?? source;
            int width = bitmap.PixelWidth, height = bitmap.PixelHeight;
            var pixels = new byte[checked(width * height * 4)];
            var buffer = new Windows.Storage.Streams.Buffer((uint)pixels.Length) { Length = (uint)pixels.Length };
            bitmap.CopyToBuffer(buffer);
            using (var data = DataReader.FromBuffer(buffer))
                data.ReadBytes(pixels);
            string? code = QrImage.Decode(pixels, width, height);
            var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
            image.Freeze();
            Dispatcher.InvokeAsync(() =>
            {
                if (closed || reader != sender)
                    return;
                preview.Source = image;
                if (code is not null && !choosingImage)
                    Accept(code);
            });
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException)
        {
            // A frame can become unavailable while a camera is being disconnected or closed.
        }
        finally { Volatile.Write(ref handlingFrame, 0); }
    }

    private async Task StopCameraAsync()
    {
        var previousReader = reader;
        var previousCamera = camera;
        reader = null;
        camera = null;
        await ReleaseCameraAsync(previousReader, previousCamera);
    }

    private async Task ReleaseCameraAsync(MediaFrameReader? frames, MediaCapture? capture)
    {
        try
        {
            if (frames is not null)
            {
                frames.FrameArrived -= FrameArrived;
                await frames.StopAsync();
            }
        }
        catch (Exception error) when (error is COMException or InvalidOperationException) { }
        finally
        {
            frames?.Dispose();
            capture?.Dispose();
        }
    }
}
