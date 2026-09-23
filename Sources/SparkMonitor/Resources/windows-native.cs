// Windows SDK interfaces only. No third-party driver or monitoring service.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class SparkCounters : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Value { public uint Status; public double Number; }
    [StructLayout(LayoutKind.Sequential)] struct Item { public IntPtr Name; public Value Value; }
    [DllImport("pdh.dll", CharSet=CharSet.Unicode)] static extern uint PdhOpenQuery(string source, IntPtr user, out IntPtr query);
    [DllImport("pdh.dll", CharSet=CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr user, out IntPtr counter);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
    [DllImport("pdh.dll", CharSet=CharSet.Unicode)] static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bytes, out uint count, IntPtr items);
    [DllImport("pdh.dll")] static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, IntPtr type, out Value value);
    IntPtr query;
    Dictionary<string,IntPtr> counters = new Dictionary<string,IntPtr>();
    public Dictionary<string,string> Unavailable = new Dictionary<string,string>();
    public SparkCounters() { uint status=PdhOpenQuery(null,IntPtr.Zero,out query); if(status!=0) throw new Exception("PdhOpenQuery: "+status); }
    public void Add(string key,string path) {
        IntPtr handle; uint status=PdhAddEnglishCounter(query,path,IntPtr.Zero,out handle);
        if(status==0) counters[key]=handle; else Unavailable[key]=status.ToString("X8");
    }
    public void Collect() { uint status=PdhCollectQueryData(query); if(status!=0) throw new Exception("PdhCollectQueryData: "+status); }
    public double? Scalar(string key) {
        IntPtr handle; if(!counters.TryGetValue(key,out handle)) return null;
        Value v; if(PdhGetFormattedCounterValue(handle,0x8200,IntPtr.Zero,out v)!=0 || v.Status>1) return null;
        return v.Number;
    }
    public Dictionary<string,double> Values(string key) {
        var result=new Dictionary<string,double>(); IntPtr handle;
        if(!counters.TryGetValue(key,out handle)) return result;
        uint bytes=0,count; uint status=PdhGetFormattedCounterArray(handle,0x8200,ref bytes,out count,IntPtr.Zero);
        if(status!=0x800007D2 || bytes==0) return result; // PDH_MORE_DATA
        IntPtr buffer=Marshal.AllocHGlobal((int)bytes);
        try {
            if(PdhGetFormattedCounterArray(handle,0x8200,ref bytes,out count,buffer)!=0) return result;
            int size=Marshal.SizeOf(typeof(Item));
            for(int i=0;i<count;i++) {
                Item item=(Item)Marshal.PtrToStructure(IntPtr.Add(buffer,i*size),typeof(Item));
                if(item.Value.Status<=1) result[Marshal.PtrToStringUni(item.Name)]=item.Value.Number;
            }
        } finally { Marshal.FreeHGlobal(buffer); }
        return result;
    }
    public void Dispose() { if(query!=IntPtr.Zero) { PdhCloseQuery(query); query=IntPtr.Zero; } }
}

public static class SparkNative {
    [StructLayout(LayoutKind.Sequential)] struct ProcessBasicInfo {
        public IntPtr ExitStatus,PEB,Affinity,Priority,PID,ParentPID;
    }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int kind,out ProcessBasicInfo info,int size,out int returned);
    public static void ExitWithSSHSession() {
        // Windows exec wrappers can retain stdin handles after disconnect.
        // Bind the sampler to its actual per-connection sshd ancestor instead.
        var process=System.Diagnostics.Process.GetCurrentProcess();
        while(!process.ProcessName.StartsWith("sshd",StringComparison.OrdinalIgnoreCase)) {
            ProcessBasicInfo info; int length;
            int status=NtQueryInformationProcess(process.Handle,0,out info,Marshal.SizeOf(typeof(ProcessBasicInfo)),out length);
            if(status!=0) throw new Exception("Cannot identify SSH parent: "+status);
            int parent=info.ParentPID.ToInt32(); process.Dispose();
            process=System.Diagnostics.Process.GetProcessById(parent);
        }
        var ssh=process;
        var watcher=new System.Threading.Thread(delegate() { ssh.WaitForExit(); Environment.Exit(0); });
        watcher.IsBackground=true; watcher.Start();
    }
    [StructLayout(LayoutKind.Sequential)] public struct Performance {
        public uint Size;
        public UIntPtr CommitTotal,CommitLimit,CommitPeak,PhysicalTotal,PhysicalAvailable,SystemCache,KernelTotal,KernelPaged,KernelNonpaged,PageSize;
        public uint Handles,Processes,Threads;
    }
    [DllImport("psapi.dll",SetLastError=true)] static extern bool GetPerformanceInfo(ref Performance data,uint size);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    public static Performance Memory() {
        var p=new Performance(); p.Size=(uint)Marshal.SizeOf(typeof(Performance));
        if(!GetPerformanceInfo(ref p,p.Size)) throw new System.ComponentModel.Win32Exception(); return p;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct AdapterDesc {
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description;
        public uint Vendor,Device,Subsystem,Revision;
        public UIntPtr DedicatedVideo,DedicatedSystem,SharedSystem;
        public Luid Luid; public uint Flags;
    }
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid iid,out IntPtr factory);
    [DllImport("d3d12.dll")] static extern int D3D12CreateDevice(IntPtr adapter,uint level,ref Guid iid,IntPtr device);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapter(IntPtr self,uint index,out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDescription(IntPtr self,out AdapterDesc desc);
    public sealed class GPU {
        public string Name,Tag,DirectX,PCI; public uint Vendor; public ulong Dedicated,Shared; public Luid Luid;
    }
    public static GPU[] GPUs() {
        IntPtr factory; var iid=new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref iid,out factory));
        var result=new List<GPU>();
        try {
            var enumerate=(EnumAdapter)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(factory),12*IntPtr.Size),typeof(EnumAdapter));
            for(uint i=0;;i++) {
                IntPtr adapter; int hr=enumerate(factory,i,out adapter); if(hr==unchecked((int)0x887A0002)) break;
                Marshal.ThrowExceptionForHR(hr);
                try {
                    var describe=(GetDescription)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(adapter),10*IntPtr.Size),typeof(GetDescription));
                    AdapterDesc d; Marshal.ThrowExceptionForHR(describe(adapter,out d));
                    if((d.Flags&2)!=0) continue;
                    var gpu=new GPU {Name=d.Description,Vendor=d.Vendor,Dedicated=d.DedicatedVideo.ToUInt64(),Shared=d.SharedSystem.ToUInt64(),Luid=d.Luid,
                        Tag=String.Format("luid_0x{0:X8}_0x{1:X8}",d.Luid.High,d.Luid.Low)};
                    var deviceIID=new Guid("189819f1-1db6-4b57-be54-1821339b85f7");
                    foreach(uint level in new uint[]{0xc200,0xc100,0xc000,0xb100,0xb000}) {
                        if(D3D12CreateDevice(adapter,level,ref deviceIID,IntPtr.Zero)>=0) {
                            gpu.DirectX=String.Format("12 (FL {0}.{1})",level>>12,(level>>8)&15); break;
                        }
                    }
                    gpu.PCI=GPUAddress(gpu); result.Add(gpu);
                } finally { Marshal.Release(adapter); }
            }
        } finally { Marshal.Release(factory); }
        return result.ToArray();
    }
    [StructLayout(LayoutKind.Sequential)] struct OpenAdapter { public Luid Luid; public uint Handle; }
    [StructLayout(LayoutKind.Sequential)] struct Query { public uint Handle; public int Type; public IntPtr Data; public uint Size; }
    [StructLayout(LayoutKind.Sequential)] struct AdapterPerf {
        public uint PhysicalIndex; public ulong MemoryFrequency,MaxMemoryFrequency,MaxMemoryFrequencyOC,MemoryBandwidth,PCIEBandwidth;
        public uint FanRPM,Power,Temperature; public byte PowerState;
    }
    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromLuid(ref OpenAdapter adapter);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref Query query);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref uint handle);
    static string GPUAddress(GPU gpu) {
        var a=new OpenAdapter {Luid=gpu.Luid}; if(D3DKMTOpenAdapterFromLuid(ref a)!=0) return null;
        IntPtr buffer=Marshal.AllocHGlobal(12);
        try {
            var q=new Query {Handle=a.Handle,Type=6,Data=buffer,Size=12};
            if(D3DKMTQueryAdapterInfo(ref q)!=0) return null;
            return String.Format("PCI {0}:{1}:{2}",Marshal.ReadInt32(buffer),Marshal.ReadInt32(buffer,4),Marshal.ReadInt32(buffer,8));
        } finally { Marshal.FreeHGlobal(buffer); D3DKMTCloseAdapter(ref a.Handle); }
    }
    public static double? GPUTemperature(GPU gpu) {
        var a=new OpenAdapter {Luid=gpu.Luid}; if(D3DKMTOpenAdapterFromLuid(ref a)!=0) return null;
        int size=Marshal.SizeOf(typeof(AdapterPerf)); IntPtr buffer=Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(new AdapterPerf(),buffer,false);
            var q=new Query {Handle=a.Handle,Type=62,Data=buffer,Size=(uint)size};
            if(D3DKMTQueryAdapterInfo(ref q)!=0) return null;
            var p=(AdapterPerf)Marshal.PtrToStructure(buffer,typeof(AdapterPerf));
            // Power here is a percentage, not watts. Never expose it as power.draw.
            return p.Temperature>0 ? (double?)(p.Temperature/10.0) : null;
        } finally { Marshal.FreeHGlobal(buffer); D3DKMTCloseAdapter(ref a.Handle); }
    }
    [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version,IntPtr reserved,out uint negotiated,out IntPtr handle);
    [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle,IntPtr reserved);
    [DllImport("wlanapi.dll")] static extern uint WlanQueryInterface(IntPtr handle,ref Guid id,uint opcode,IntPtr reserved,out uint size,out IntPtr data,out uint type);
    [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr data);
    public static Dictionary<string,object> Wifi(string id) {
        var result=new Dictionary<string,object>(); IntPtr handle; uint version;
        if(WlanOpenHandle(2,IntPtr.Zero,out version,out handle)!=0) return result;
        try {
            Guid guid=new Guid(id); uint size,type; IntPtr data;
            if(WlanQueryInterface(handle,ref guid,7,IntPtr.Zero,out size,out data,out type)!=0) return result;
            try {
                if(Marshal.ReadInt32(data)!=1) return result;
                int length=Marshal.ReadInt32(data,520); byte[] ssid=new byte[length]; Marshal.Copy(IntPtr.Add(data,524),ssid,0,length);
                result["ssid"]=Encoding.UTF8.GetString(ssid);
                result["signal"]=Marshal.ReadInt32(data,576);
                result["rxSpeed"]=Marshal.ReadInt32(data,580)/1000.0; result["txSpeed"]=Marshal.ReadInt32(data,584)/1000.0;
                int phy=Marshal.ReadInt32(data,568);
                result["protocol"]=phy==11?"802.11ax":phy==10?"802.11ac":phy==9?"802.11n":phy==12?"802.11be":"Wi-Fi";
            } finally { WlanFreeMemory(data); }
        } finally { WlanCloseHandle(handle,IntPtr.Zero); }
        return result;
    }
}
