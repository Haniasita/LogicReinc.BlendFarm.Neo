using SkiaSharp;
using System;
using System.Collections.Generic;
using System.Text;

namespace LogicReinc.BlendFarm.Client.Tasks
{
    public interface IImageTask
    {
        SKBitmap FinalImage { get; }
    }
}
