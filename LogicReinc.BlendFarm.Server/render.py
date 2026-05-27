# Script used by LogicReinc.BlendFarm.Server for rendering in Blender
# Assumes usage of structures from said assembly


#Workaround refers to:
# A sad requirement that works around a problem in Blender.
# Blender doesn't properly update before rendering in subsequent tasks in a batch
# It changes both rendering at the node as well as handling of incoming tiles
# It may cause artifacts and inaccuracies. And a newer (or perhaps even older) version of blender may have this fixed.
# Currently enabled by default because 2.91.0 has this issue.



#Start
import bpy
import sys
import json
import time
import os
import re
from multiprocessing import cpu_count

isPre3 = bpy.app.version < (3,0,0);
isPreEeveeRename = bpy.app.version < (4, 2, 0);

if(isPre3):
    print('Detected Blender >= 3.0.0\n');

argv = sys.argv
argv = argv[argv.index("--") + 1:]

scn = bpy.context.scene

jsonPathInitial = argv[0];
useContinue = len(argv) > 1 and argv[1] == 'True';

if(useContinue):
    print('Continuation enabled\n');
    

def useDevices(type, allowGPU, allowCPU):
    cyclesPref = bpy.context.preferences.addons["cycles"].preferences;
    
    #For older Blender Builds
    if (isPre3):
        cyclesPref.compute_device_type = type
        devs = cyclesPref.get_devices()
        cuda_devices, opencl_devices = cyclesPref.get_devices()
        print(cyclesPref.compute_device_type)
        
        devices = None;
        if(type == "CUDA"):
            devices = cuda_devices;
        elif(type == "OPTIX"):
            devices = cuda_devices;
        else:
            devices = opencl_devices;
        for d in devices:
            d.use = (allowCPU and d.type == "CPU") or (allowGPU and d.type != "CPU");
            print(type + " Device:", d["name"], d["use"]);
    #For Blender Builds >= 3.0
    else:
        cyclesPref.compute_device_type = type
        
        print(cyclesPref.compute_device_type)
        
        devices = None;
        if(type == "CUDA"):
            devices = cyclesPref.get_devices_for_type("CUDA");
        elif(type == "OPTIX"):
            devices = cyclesPref.get_devices_for_type("OPTIX");
        elif(type == "HIP"):
            devices = cyclesPref.get_devices_for_type("HIP");
        elif(type == "METAL"):
            devices = cyclesPref.get_devices_for_type("METAL");
        elif(type == "ONEAPI"):
            devices = cyclesPref.get_devices_for_type("ONEAPI");
        else:
            devices = cyclesPref.get_devices_for_type("OPENCL");
        print("Devices Found:", devices);
        if(len(devices) == 0):
            raise Exception("No devices found for type " + type + ", Unsupported hardware or platform?");
        for d in devices:
            d.use = (allowCPU and d.type == "CPU") or (allowGPU and d.type != "CPU");
            print(type + " Device:", d["name"], d["use"]);

progress_file_path = None
render_task_id = None
render_stats_count = 0
render_stats_total = 100
render_stats_phase = 0
render_start_time = 0.0
render_heartbeat_warned = False

# Cycles emits stats strings like "Sample 50/100" or "Path Tracing Sample 50/100";
# older tile-based output uses "Rendered 5/16 Tiles".
_SAMPLE_PATTERN = re.compile(r'Sample[s]?\s*(\d+)\s*/\s*(\d+)', re.IGNORECASE)
_TILE_PATTERN = re.compile(r'(?:Rendered|Tile)\s*(\d+)\s*/\s*(\d+)', re.IGNORECASE)

# A render goes through three observable phases: scene/kernel preparation,
# the actual sample loop, and post-processing/file write. Cycles re-uses the
# same N/M counter for each, so the progress bar naturally cycles 0→100% three
# times. Labelling the phase tells the user which one they're watching.
_PHASE_NAMES = ("Loading", "Rendering", "Saving")
_PHASE_KEYWORDS = (
    # Order matters: more specific/late-stage phases checked first so a stray
    # "loading" message during saving doesn't drag the label backward.
    (2, ("saving", "compositing", "writing", "denois", "merg", "finaliz", "wrote")),
    (1, ("sample",)),
    (0, ("loading", "building", "compiling", "synchroniz", "kernel", "bvh", "updat")),
)

def _detect_phase(stats_str):
    if not stats_str:
        return None
    s = stats_str.lower()
    for idx, keywords in _PHASE_KEYWORDS:
        for kw in keywords:
            if kw in s:
                return idx
    return None

def write_progress(task_id, tiles_finished, tiles_total, phase=None, elapsed=0.0, remaining=-1.0):
    """Write progress to JSON file"""
    global progress_file_path
    if progress_file_path:
        try:
            progress_data = {
                "TaskID": task_id,
                "TilesFinished": tiles_finished,
                "TilesTotal": tiles_total,
                "Phase": phase,
                "Elapsed": elapsed,
                "Remaining": remaining,
                "Timestamp": time.time()
            }
            with open(progress_file_path, 'w') as f:
                json.dump(progress_data, f)
        except:
            pass

def on_render_stats(*args):
    """Render-engine stats callback. Invoked by Blender's render engine
    (BKE_callback_exec_string) from the render thread, so it fires during
    bpy.ops.render.render() — including for OptiX/HIP/CUDA where stdout
    progress lines are unreliable. bpy.app.timers cannot be used here
    because the event loop is blocked while rendering."""
    global progress_file_path, render_task_id, render_stats_count, render_stats_total
    global render_stats_phase, render_start_time, render_heartbeat_warned

    if not progress_file_path or not render_task_id:
        return

    render_stats_count += 1

    parsed_current = None
    parsed_total = None
    detected_phase = None
    status_message = None
    for a in args:
        if isinstance(a, str):
            if status_message is None:
                status_message = a
            if parsed_current is None:
                m = _SAMPLE_PATTERN.search(a) or _TILE_PATTERN.search(a)
                if m:
                    parsed_current = int(m.group(1))
                    parsed_total = int(m.group(2))
            if detected_phase is None:
                detected_phase = _detect_phase(a)
            if parsed_current is not None and detected_phase is not None:
                break

    # Phase only advances forward, so an unrelated message during a later phase
    # can't drag the label back to "Loading".
    if detected_phase is not None and detected_phase > render_stats_phase:
        render_stats_phase = detected_phase

    # Step counts (current/total) only meaningful during rendering phase
    if render_stats_phase == 1:
        if parsed_current is not None:
            current = parsed_current
            total = parsed_total
            render_stats_total = total
        else:
            # No parseable string — fall back to a heartbeat counter. Warn once so
            # users running an older Blender (where stats handlers don't receive
            # the stats string as a positional arg) understand why the bar is rough.
            if not render_heartbeat_warned:
                render_heartbeat_warned = True
                print("WARN: render_stats provided no parseable progress string; "
                      "falling back to heartbeat-based estimation. Per-sample "
                      "progress unavailable on this Blender build.", flush=True)
            current = render_stats_count
            total = render_stats_total

        # Don't appear complete before render_complete actually fires (post-processing,
        # denoising, file write all happen after the last sample).
        if current >= total:
            current = max(1, total - 1)
    else:
        # Loading and Saving phases: no step counter
        current = 0
        total = 0

    elapsed = time.time() - render_start_time
    remaining = -1.0
    # Need a few percent of progress to make a remaining-time estimate that
    # isn't wildly noisy. The estimate is phase-local (we don't know phase
    # weights), but the user's elapsed clock keeps running across all phases.
    if render_stats_phase == 1 and current >= max(2, total * 0.05) and total > 0:
        remaining = max(0.0, (elapsed / current) * (total - current))

    write_progress(render_task_id, current, total,
                   status_message or _PHASE_NAMES[render_stats_phase], elapsed, remaining)

def on_render_complete(*args):
    """Frame finished — flush 100% so the client sees completion immediately."""
    global progress_file_path, render_task_id, render_stats_total, render_start_time
    if progress_file_path and render_task_id:
        elapsed = time.time() - render_start_time
        write_progress(render_task_id, render_stats_total, render_stats_total,
                       _PHASE_NAMES[-1], elapsed, 0.0)

def on_render_cancel(*args):
    on_render_complete(*args)

#Renders provided settings with id to path
def renderWithSettings(renderSettings, id, path):
        #Dump
        print(json.dumps(renderSettings, indent = 4) + "\n");
        
        global scn;

        scen = renderSettings["Scene"];
        if(scen is None):
            scen = "";
        if(scen != ""):
            print("Rendering specified scene " + scen + "\n");
            scn = bpy.data.scenes[scen];
            if(scn is None):
                raise Exception("Unknown Scene :" + scen);


        # Parse Parameters
        frame = int(renderSettings["Frame"])

        # Set threading
        scn.render.threads_mode = 'FIXED';
        scn.render.threads = max(cpu_count(), int(renderSettings["Cores"]));
        
        if (isPre3):
            scn.render.tile_x = int(renderSettings["TileWidth"]);
            scn.render.tile_y = int(renderSettings["TileHeight"]);
        else:
            print("Blender > 3.0 doesn't support tile size, thus ignored");
        

        # Set constraints
        scn.render.use_border = True
        scn.render.use_crop_to_border = renderSettings["Crop"];
        if not renderSettings["Crop"]:
            scn.render.film_transparent = True;

        scn.render.border_min_x = float(renderSettings["X"])
        scn.render.border_max_x = float(renderSettings["X2"])
        scn.render.border_min_y = float(renderSettings["Y"])
        scn.render.border_max_y = float(renderSettings["Y2"])

        #Set Camera
        camera = renderSettings["Camera"];
        if(camera != None and camera != "" and bpy.data.objects[camera]):
            scn.camera = bpy.data.objects[camera];

        #Set Resolution
        scn.render.resolution_x = int(renderSettings["Width"]);
        scn.render.resolution_y = int(renderSettings["Height"]);
        scn.render.resolution_percentage = 100;

        #Set Samples
        scn.cycles.samples = int(renderSettings["Samples"]);

        scn.render.use_persistent_data = True;

        #Render Device
        renderType = int(renderSettings["ComputeUnit"]);
        engine = int(renderSettings["Engine"]);

        if(engine == 2): #Optix
            optixGPU = renderType == 1 or renderType == 3 or renderType == 11 or renderType == 12; #CUDA or CUDA_GPU_ONLY
            optixCPU = renderType != 3 and renderType != 12; #!CUDA_GPU_ONLY && !OPTIX_GPU_ONLY
            if(optixCPU and not optixGPU):
                scn.cycles.device = "CPU";
            else:
                scn.cycles.device = "GPU";
            useDevices("OPTIX", optixGPU, optixCPU);
        else: #Cycles/Eevee
            if renderType == 0: #CPU
                scn.cycles.device = "CPU";
                print("Use CPU");
            elif renderType == 1: #Cuda
                useDevices("CUDA", True, True);
                scn.cycles.device = "GPU";
                print("Use Cuda");
            elif renderType == 2: #OpenCL
                useDevices("OPENCL", True, True);
                scn.cycles.device = "GPU";
                print("Use OpenCL");
            elif renderType == 3: #Cuda (GPU Only)
                useDevices("CUDA", True, False);
                scn.cycles.device = 'GPU';
                print("Use Cuda (GPU)");
            elif renderType == 4: #OpenCL (GPU Only)
                useDevices("OPENCL", True, False);
                scn.cycles.device = 'GPU';
                print("Use OpenCL (GPU)");
            elif renderType == 5: #HIP
                useDevices("HIP", True, False);
                scn.cycles.device = 'GPU';
                print("Use HIP");
            elif renderType == 6: #HIP (GPU Only)
                useDevices("HIP", True, True);
                scn.cycles.device = 'GPU';
                print("Use HIP (GPU)");
            elif renderType == 7: #METAL
                useDevices("METAL", True, True);
                scn.cycles.device = 'GPU';
                print("Use METAL");
            elif renderType == 8: #METAL (GPU Only)
                useDevices("METAL", True, False);
                scn.cycles.device = 'GPU';
                print("Use METAL (GPU)");
            elif renderType == 9: #ONEAPI
                useDevices("ONEAPI", True, True);
                scn.cycles.device = 'GPU';
                print("Use ONEAPI");
            elif renderType == 10: #ONEAPI (GPU Only)
                useDevices("ONEAPI", True, False);
                scn.cycles.device = 'GPU';
                print("Use ONEAPI (GPU)");
            elif renderType == 11: #OptiX
                useDevices("OPTIX", True, True);
                scn.cycles.device = "GPU";
                print("Use OptiX");
            elif renderType == 12: #OptiX (GPU Only)
                useDevices("OPTIX", True, False);
                scn.cycles.device = "GPU";
                print("Use OptiX (GPU)");
        

        #Denoiser
        denoise = renderSettings["Denoiser"];
        if denoise is not None:
            if denoise == "None":
                scn.cycles.use_denoising = False;
            elif len(denoise) > 0:
                scn.cycles.use_denoising = True;
                scn.cycles.denoiser = denoise;

        fps = renderSettings["FPS"];
        if fps is not None and fps > 0:
            scn.render.fps = fps;

        if(engine == 1): #Eevee
            if(isPreEeveeRename):
                print("Using EEVEE");
                scn.render.engine = "BLENDER_EEVEE";
            else:
                print("Using EEVEE_NEXT");
                scn.render.engine = "BLENDER_EEVEE_NEXT";
        else:
            scn.render.engine = "CYCLES";

        # Set frame
        scn.frame_set(frame)
        
        # Set Output
        scn.render.filepath = path;

        # Setup progress tracking
        global progress_file_path, render_task_id, render_stats_count, render_stats_total
        global render_stats_phase, render_start_time, render_heartbeat_warned
        import tempfile
        temp_dir = tempfile.gettempdir()
        progress_dir = os.path.join(temp_dir, "BlendFarmProgress")
        os.makedirs(progress_dir, exist_ok=True)
        progress_file_path = os.path.join(progress_dir, str(id) + ".progress.json")
        render_task_id = str(id)

        render_stats_count = 0
        render_stats_phase = 0
        render_heartbeat_warned = False
        render_start_time = time.time()
        if scn.render.engine == "CYCLES":
            render_stats_total = max(1, scn.cycles.samples)
        else:
            render_stats_total = 100

        # Initialize progress file
        write_progress(str(id), 0, render_stats_total, _PHASE_NAMES[0], 0.0, -1.0)

        # Register render-engine handlers. render_stats fires from the render
        # thread during bpy.ops.render.render() for every device backend
        # (CPU, CUDA, OptiX, HIP, Metal, ONEAPI), so progress is reported even
        # when GPU backends don't print "Sample N/M" lines to stdout.
        if on_render_stats not in bpy.app.handlers.render_stats:
            bpy.app.handlers.render_stats.append(on_render_stats)
        if on_render_complete not in bpy.app.handlers.render_complete:
            bpy.app.handlers.render_complete.append(on_render_complete)
        if on_render_cancel not in bpy.app.handlers.render_cancel:
            bpy.app.handlers.render_cancel.append(on_render_cancel)

        # Render
        print("RENDER_START:" + str(id) + "\n", flush=True);

        try:
            bpy.ops.render.render(animation=False, write_still=True, use_viewport=False, layer="", scene = scen)
        finally:
            # Unregister handlers
            for handler_list, handler in (
                (bpy.app.handlers.render_stats, on_render_stats),
                (bpy.app.handlers.render_complete, on_render_complete),
                (bpy.app.handlers.render_cancel, on_render_cancel),
            ):
                try:
                    handler_list.remove(handler)
                except ValueError:
                    pass

            # Write final progress
            final_elapsed = time.time() - render_start_time
            write_progress(str(id), render_stats_total, render_stats_total,
                           _PHASE_NAMES[-1], final_elapsed, 0.0)

            # Cleanup progress file after a short delay to allow client to read it
            import time as time_module
            time_module.sleep(0.5)
            if progress_file_path:
                try:
                    if os.path.exists(progress_file_path):
                        os.remove(progress_file_path)
                except:
                    pass
            progress_file_path = None
            render_task_id = None

        print("SUCCESS:" + str(id) + "\n", flush=True);




def runBatch(jsonPath):
    print("Json Path:" + jsonPath + "\n");

    # Load Json
    print("Reading Json Config\n");
    jsonFile = open(jsonPath);
    jsonData = jsonFile.read();
    jsonFile.close();

    # Parse Json
    print("Parsing Json Config\n");
    renderSettingsBatch = json.loads(jsonData);

    isFirst = True
        
    scn.render.engine = "CYCLES"
    

    # Loop over batches
    for i in range(len(renderSettingsBatch)):
        current = renderSettingsBatch[i];
        renderSettings = current;
        
        renderFormat = renderSettings["RenderFormat"];
        if (not renderFormat):
            scn.render.image_settings.file_format = "PNG";
        else:
            scn.render.image_settings.file_format = renderFormat;

        output = renderSettings["Output"];
        id = renderSettings["TaskID"];

        #Workaround for scene not updating...
        if not isFirst and renderSettings["Workaround"] and (len(renderSettingsBatch) > 1 and i < len(renderSettingsBatch)):
            previous = renderSettingsBatch[i - 1];
            output = previous["Output"];
            id = previous["TaskID"];
            
        renderWithSettings(renderSettings, id, output);
        
        #Workaround for scene not updating...
        if (renderSettings["Workaround"] and len(renderSettingsBatch) > 1 and i == len(renderSettingsBatch) - 1):
            renderWithSettings(current, current["TaskID"], current["Output"]);

        isFirst = False

    print("BATCH_COMPLETE\n");

#Main

try:
    newJsonPath = jsonPathInitial;
    count = 0;
    while newJsonPath.strip():
        if(count > 0):
            print("Continue count: " + str(count));

        runBatch(newJsonPath);
        newJsonPath = "";
        
        if(useContinue):
            print("AWAITING CONTINUE:\n");
            newInput = input("");
            newInput = newInput.strip();
            print("Received:" + newInput + "\n");
            if(newInput):
                newJsonPath = newInput;
                count = count + 1;
            else:
                break;
        
except Exception as e:
    print("EXCEPTION:" + str(e));