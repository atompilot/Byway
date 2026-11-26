using System.Windows.Media;
using System.Windows.Media.Imaging;
using ZXing;
using ZXing.Common;

namespace Byway;

internal static class QrImage
{
    internal static string Read(string path)
    {
        using var stream = File.OpenRead(path);
        return Read(stream);
    }

    internal static string Read(Stream stream)
    {
        if (stream.Length > 20 * 1024 * 1024)
            throw new InvalidDataException(L10n.Text("二维码图片不能超过 20 MB。"));
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None).Frames[0];
        double ratio = Math.Min(1, 2000.0 / Math.Max(frame.PixelWidth, frame.PixelHeight));
        BitmapSource source = ratio < 1 ? new TransformedBitmap(frame, new ScaleTransform(ratio, ratio)) : frame;
        var bitmap = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int stride = bitmap.PixelWidth * 4;
        byte[] pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);
        return Decode(pixels, bitmap.PixelWidth, bitmap.PixelHeight)
            ?? throw new InvalidDataException(L10n.Text("图片中没有可识别的二维码。"));
    }

    internal static string? Decode(byte[] pixels, int width, int height)
    {
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.QR_CODE] }
        };
        return reader.Decode(pixels, width, height, RGBLuminanceSource.BitmapFormat.BGRA32)?.Text;
    }

    internal static BitmapSource Write(string text)
    {
        var writer = new BarcodeWriterPixelData
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new ZXing.QrCode.QrCodeEncodingOptions
            {
                Width = 720, Height = 720, Margin = 4, CharacterSet = "UTF-8",
                ErrorCorrection = ZXing.QrCode.Internal.ErrorCorrectionLevel.M
            }
        };
        var encoded = writer.Write(text);
        return BitmapSource.Create(encoded.Width, encoded.Height, 96, 96, PixelFormats.Bgra32, null, encoded.Pixels, encoded.Width * 4);
    }

    internal static byte[] Png(string text)
    {
        using var stream = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(Write(text)));
        encoder.Save(stream);
        return stream.ToArray();
    }
}
