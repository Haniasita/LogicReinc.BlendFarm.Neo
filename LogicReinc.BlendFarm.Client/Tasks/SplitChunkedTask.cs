using LogicReinc.BlendFarm.Client.ImageTypes;
using LogicReinc.BlendFarm.Shared;
using SkiaSharp;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Client.Tasks
{
    public class SplitChunkedTask : RenderTask, IImageTask
    {
        public SKBitmap FinalImage { get; private set; }

        public SplitChunkedTask(List<RenderNode> nodes, string session, string version, long fileId, RenderManagerSettings settings = null) : base(nodes, session, version, fileId, settings)
        {
        }

        protected override async Task<bool> Execute()
        {
            object drawLock = new object();
            SKBitmap result = new SKBitmap(Settings.OutputWidth, Settings.OutputHeight);
            SKCanvas g = new SKCanvas(result);
            try
            {

                Dictionary<RenderNode, decimal> shares = GetRelativePerformance(_usedNodes);

                List<RenderSubTask> tasks = GetChunkedSubTasks();

                ConcurrentQueue<RenderSubTask> queue = GetTaskQueueInOrder(tasks, Settings.Order);

                Dictionary<RenderNode, List<RenderSubTask>> assignment = _usedNodes.ToDictionary(x => x, y => new List<RenderSubTask>());

                //Divide Tasks
                //Assume every core has the same performance..
                while (queue.Count > 0)
                {
                    queue.TryDequeue(out RenderSubTask nextTask); //Single threaded, always true

                    RenderNode nextNode = _usedNodes.OrderBy(node =>
                    {
                        int nrTiles = assignment[node].Count;
                        return nrTiles * (1 / shares[node]);
                    }).FirstOrDefault();
                    assignment[nextNode].Add(nextTask);
                }

                //Run tasks over all rendernodes
                await Task.Run(() =>
                {
                    ForceParallel(_usedNodes, (node) =>
                    {
                        List<RenderSubTask> nodeTasks = assignment[node];
                        if (nodeTasks.Count == 0)
                            return;

                        try
                        {
                            SubTaskBatchResult resp = ExecuteSubTasks(node, (rsbt, rbr) =>
                            {
                                using (SKBitmap img = ImageTypes.ImageConverter.Convert(rbr.Data, Settings.RenderFormat))
                                    ProcessTile(rsbt, img, ref g, ref result, ref drawLock);

                                ChangeProgress(Progress + rsbt.Value);
                            }, assignment[node].ToArray());
                            if (resp?.Exception != null)
                                node.UpdateException(resp.Exception.Message);
                        }
                        catch (TaskCanceledException)
                        {
                            node.UpdateException("Cancelled");
                            return;
                        }
                        catch (AggregateException ex)
                        {
                            node.UpdateException(string.Join(", ", ex.InnerExceptions.Select(x => x.Message)));
                        }
                        catch (Exception ex)
                        {
                            node.UpdateException(ex.Message);
                        }
                    });

                    g?.Dispose();
                    return result;
                });
            }
            finally
            {
                g?.Dispose();
            }
            FinalImage = result;

            return true;
        }
    }
}

