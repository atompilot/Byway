using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Byway;

internal sealed class ShareDialog : Window
{
    internal ShareDialog(Window owner, string name, string code, bool bywayOnly)
    {
        Owner = owner;
        Title = "分享二维码";
        Width = 505;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        string[] pages = QrParts.Split(code);
        int page = 0;
        var panel = new StackPanel { Margin = new Thickness(20) };
        Content = panel;
        panel.Children.Add(new TextBlock { Text = name, FontSize = 19, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        var image = new Image { Width = 340, Height = 340, Margin = new Thickness(0, 12, 0, 12) };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        System.Windows.Automation.AutomationProperties.SetName(image, "分享二维码图像");
        panel.Children.Add(image);

        var hint = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        panel.Children.Add(hint);
        var pager = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        var previous = new Button { Content = "上一张", Margin = new Thickness(0, 0, 8, 0) };
        var next = new Button { Content = "下一张" };
        pager.Children.Add(previous);
        pager.Children.Add(next);
        if (pages.Length > 1)
            panel.Children.Add(pager);

        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        System.Windows.Automation.AutomationProperties.SetAutomationId(status, "ShareStatus");
        panel.Children.Add(status);
        var actions = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 10, 0, 0) };
        panel.Children.Add(actions);
        var done = new Button { Content = "完成", IsCancel = true };
        DockPanel.SetDock(done, Dock.Right);
        actions.Children.Add(done);
        var copy = new Button { Content = "复制链接", Margin = new Thickness(0, 0, 8, 0) };
        var save = new Button { Content = "保存二维码…" };
        actions.Children.Add(copy);
        actions.Children.Add(save);

        void Update()
        {
            image.Source = QrImage.Write(pages[page]);
            previous.IsEnabled = page > 0;
            next.IsEnabled = page + 1 < pages.Length;
            hint.Text = pages.Length > 1 ? $"第 {page + 1} / {pages.Length} 张。请用 Byway 扫描全部二维码。"
                : bywayOnly ? "对方可用 Byway 扫码导入整组。" : "对方扫码即可导入。";
        }

        previous.Click += (_, _) => { page--; Update(); };
        next.Click += (_, _) => { page++; Update(); };
        copy.Click += (_, _) =>
        {
            try { Clipboard.SetText(code); status.Text = "链接已复制。"; }
            catch (ExternalException) { status.Text = "无法写入剪贴板，请重试。"; }
        };
        save.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = "保存二维码", Filter = "PNG 图片 (*.png)|*.png", AddExtension = true,
                FileName = pages.Length == 1 ? "Byway-QR.png" : $"Byway-QR-{page + 1}-of-{pages.Length}.png"
            };
            if (dialog.ShowDialog(this) != true)
                return;
            try
            {
                using var file = File.Open(dialog.FileName, FileMode.CreateNew);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create((BitmapSource)image.Source));
                encoder.Save(file);
                status.Text = "二维码已保存。";
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                status.Text = "无法保存。请检查目录权限，并使用尚未存在的文件名。";
            }
        };
        Update();
    }
}
