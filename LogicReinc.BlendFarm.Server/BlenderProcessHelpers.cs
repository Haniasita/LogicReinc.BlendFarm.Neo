using System.Text.RegularExpressions;

namespace LogicReinc.BlendFarm.Server
{
    internal static partial class BlenderProcessHelpers
    {
        [GeneratedRegex("Fra:.*Time:(.*?)\\|.*?Remaining:(.*?)\\|.*?Sample(.*?)\\/([0-9]*)")]
        private static partial Regex BlenderRegex2();
    }
}