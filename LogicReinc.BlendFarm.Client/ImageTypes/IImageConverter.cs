using SkiaSharp;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Client.ImageTypes
{
    public static class ImageConverter
    {
        public static DefaultImageConverter Default { get; } = new DefaultImageConverter();

        public static SKBitmap Convert(byte[] bytes, string format)
        {
            using (MemoryStream str = new MemoryStream(bytes))
                return Convert(str, format);
        }
        public static SKBitmap Convert(Stream str, string format)
        {
            format = format.ToUpper().Trim();
            switch (format)
            {
                case "":
                case "BMP":
                case "PNG":
                case "JPEG":
                case "TIFF":
                    return Default.FromStream(str);
                default:
                    return null;
            }
        }
    }

    public interface IImageConverter
    {
        SKBitmap FromStream(Stream str);
    }
}
