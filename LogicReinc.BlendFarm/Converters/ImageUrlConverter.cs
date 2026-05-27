using Avalonia.Data.Converters;
using Avalonia.Media.Imaging;
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Converters
{
    public class ImageUrlConverter : IValueConverter
    {
        private static readonly Dictionary<string, Bitmap> _cache = [];
        private static readonly HttpClient _httpClient = new();

        public object Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture)
        {
            string url = value as string;

            if (_cache.TryGetValue(url, out Bitmap cachedBitmap))
                return cachedBitmap;

            using (MemoryStream stream = new(_httpClient.GetByteArrayAsync(url).GetAwaiter().GetResult()))
            {
                Bitmap bitmap = new(stream);
                _cache.Add(url, bitmap);
            }
            return _cache[url];
        }

        public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture)
        {
            throw new NotImplementedException();
        }
    }
}
