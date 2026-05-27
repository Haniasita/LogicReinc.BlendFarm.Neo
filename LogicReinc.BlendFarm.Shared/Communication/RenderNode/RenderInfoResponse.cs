using System;
using System.Collections.Generic;
using System.Text;

namespace LogicReinc.BlendFarm.Shared.Communication.RenderNode
{
    //Packets for updating render info (singular)

    [BlendFarmHeader("renderInfoResp")]
    public class RenderInfoResponse : BlendFarmMessage
    {
        public string TaskID { get; set; }

        public int TilesTotal { get; set; }
        public int TilesFinished { get; set; }

        public int Time { get; set; }
        public int TimeRemaining { get; set; }

        // Render phase label ("Loading", "Rendering", "Saving"). Cycles
        // reuses the N/M counter for each phase, so the bar visibly cycles
        // 0→100% three times; the label disambiguates which one.
        public string Phase { get; set; }
    }
}


