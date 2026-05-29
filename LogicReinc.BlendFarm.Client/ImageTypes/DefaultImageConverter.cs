using SkiaSharp;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Client.ImageTypes
{
    public class DefaultImageConverter : IImageConverter
    {
        public SKBitmap FromStream(Stream str)
        {
            return SKBitmap.Decode(str);
        }
    }
}
