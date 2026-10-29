using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// DNS-SD (mDNS) through Windows' own dnsapi.dll (Windows 10 1809 and later): register a service instance, browse
// for instances of a type, and resolve one to its addresses, port, and TXT record. Works in an unpackaged app.
static class Dnssd
{
    public sealed record Instance(string FullName, IReadOnlyList<IPAddress> Addresses, int Port, IReadOnlyDictionary<string, string> Txt);

    const uint QueryRequestVersion1 = 1;
    const int RequestPending = 9506; // DNS_REQUEST_PENDING
    const ushort TypePtr = 12;

    // One registration: keep it to unregister. Dispose unregisters.
    public sealed class Registration : IDisposable
    {
        internal IntPtr Instance;
        internal RegisterRequest Request;
        bool _disposed;

        public void Dispose()
        {
            if (_disposed)
                return;
            _disposed = true;
            var request = Request;
            try { DnsServiceDeRegister(ref request, IntPtr.Zero); } catch (Exception) { /* best effort */ }
            // dnsapi may still reference the instance until deregistration completes; leaking one small
            // allocation per registration is safer than freeing it early.
        }
    }

    // Registers "<name>.<type>.local" on one interface (0 for all) with the given port and TXT record.
    public static Registration? Register(string name, string type, int port, IReadOnlyDictionary<string, string> txt,
        uint interfaceIndex, IPAddress? ipv4)
    {
        var keys = txt.Keys.ToArray();
        var values = keys.Select(k => txt[k]).ToArray();
        var host = Dns.GetHostName() + ".local";
        var addressPointer = IntPtr.Zero;
        if (ipv4 is not null)
        {
            addressPointer = Marshal.AllocHGlobal(4);
            Marshal.Copy(ipv4.GetAddressBytes(), 0, addressPointer, 4);
        }
        var instance = DnsServiceConstructInstance($"{Escape(name)}.{type}.local", host, addressPointer, IntPtr.Zero,
            (ushort)port, 0, 0, (uint)keys.Length, keys, values);
        if (instance == IntPtr.Zero)
            return null;
        var request = new RegisterRequest
        {
            Version = QueryRequestVersion1,
            InterfaceIndex = interfaceIndex,
            ServiceInstance = instance,
            Callback = Marshal.GetFunctionPointerForDelegate(RegisterDone),
        };
        var status = DnsServiceRegister(ref request, IntPtr.Zero);
        if (status != RequestPending)
        {
            DnsServiceFreeInstance(instance);
            RequestLog.Note($"local network: DnsServiceRegister failed ({status})");
            return null;
        }
        return new Registration { Instance = instance, Request = request };
    }

    // Instance names ("." and "\" escaped) can't hold a raw dot.
    static string Escape(string name) => name.Replace("\\", "\\\\").Replace(".", "\\.");

    // Browses for `type` for `duration`, then resolves every instance found. Results don't include instances
    // that didn't resolve within the timeout.
    public static async Task<IReadOnlyList<Instance>> BrowseAsync(string type, TimeSpan duration, CancellationToken cancel)
    {
        var names = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        var context = GCHandle.Alloc(names);
        var query = Marshal.StringToHGlobalUni(type + ".local");
        try
        {
            var request = new BrowseRequest
            {
                Version = QueryRequestVersion1,
                QueryName = query,
                Callback = Marshal.GetFunctionPointerForDelegate(BrowseFound),
                Context = GCHandle.ToIntPtr(context),
            };
            var cancelHandle = new CancelHandle();
            var status = DnsServiceBrowse(ref request, ref cancelHandle);
            if (status != RequestPending)
            {
                RequestLog.Note($"local network: DnsServiceBrowse failed ({status})");
                return [];
            }
            try
            {
                await Task.Delay(duration, cancel);
            }
            finally
            {
                DnsServiceBrowseCancel(ref cancelHandle);
            }
        }
        catch (OperationCanceledException)
        {
            return [];
        }
        finally
        {
            // Give a callback already in flight time to finish before the handle goes away.
            await Task.Delay(200, CancellationToken.None);
            context.Free();
            Marshal.FreeHGlobal(query);
        }

        var resolved = await Task.WhenAll(names.Keys.Select(name => ResolveAsync(name, TimeSpan.FromSeconds(3))));
        return resolved.OfType<Instance>().ToList();
    }

    static async Task<Instance?> ResolveAsync(string fullName, TimeSpan timeout)
    {
        var result = new TaskCompletionSource<Instance?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = GCHandle.Alloc(result);
        var query = Marshal.StringToHGlobalUni(fullName);
        var cancelHandle = new CancelHandle();
        try
        {
            var request = new ResolveRequest
            {
                Version = QueryRequestVersion1,
                QueryName = query,
                Callback = Marshal.GetFunctionPointerForDelegate(ResolveDone),
                Context = GCHandle.ToIntPtr(context),
            };
            if (DnsServiceResolve(ref request, ref cancelHandle) != RequestPending)
                return null;
            var done = await Task.WhenAny(result.Task, Task.Delay(timeout));
            if (done != result.Task)
            {
                DnsServiceResolveCancel(ref cancelHandle);
                await Task.WhenAny(result.Task, Task.Delay(500));
            }
            return result.Task.IsCompletedSuccessfully ? result.Task.Result : null;
        }
        finally
        {
            context.Free();
            Marshal.FreeHGlobal(query);
        }
    }

    // Callbacks: static delegates, so the garbage collector never frees one dnsapi still holds.
    static readonly RegisterCallback RegisterDone = (status, _, instance) =>
    {
        if (status != 0)
            RequestLog.Note($"local network: registration finished with status {status}");
    };

    static readonly BrowseCallback BrowseFound = (status, context, records) =>
    {
        try
        {
            if (status != 0 || context == IntPtr.Zero || GCHandle.FromIntPtr(context).Target is not ConcurrentDictionary<string, byte> names)
                return;
            // DNS_RECORD: pNext at 0, pName at 8, wType at 16, Data (PTR: pNameHost) at 32.
            for (var record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record, 0))
            {
                if ((ushort)Marshal.ReadInt16(record, 16) == TypePtr && Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, 32)) is { Length: > 0 } name)
                    names.TryAdd(name, 0);
            }
        }
        catch (InvalidOperationException)
        {
            // The browse already finished and its handle was freed.
        }
        finally
        {
            if (records != IntPtr.Zero)
                DnsRecordListFree(records, 1 /* DnsFreeRecordList */);
        }
    };

    static readonly ResolveCallback ResolveDone = (status, context, instance) =>
    {
        TaskCompletionSource<Instance?>? result = null;
        try
        {
            result = GCHandle.FromIntPtr(context).Target as TaskCompletionSource<Instance?>;
            if (status != 0 || instance == IntPtr.Zero)
            {
                result?.TrySetResult(null);
                return;
            }
            // DNS_SERVICE_INSTANCE: pszInstanceName 0, pszHostName 8, ip4Address 16, ip6Address 24, wPort 32,
            // dwPropertyCount 40, keys 48, values 56.
            var addresses = new List<IPAddress>();
            if (Marshal.ReadIntPtr(instance, 16) is var ip4 && ip4 != IntPtr.Zero)
                addresses.Add(new IPAddress(BitConverter.GetBytes(Marshal.ReadInt32(ip4))));
            if (Marshal.ReadIntPtr(instance, 24) is var ip6 && ip6 != IntPtr.Zero)
            {
                var bytes = new byte[16];
                Marshal.Copy(ip6, bytes, 0, 16);
                addresses.Add(new IPAddress(bytes));
            }
            var port = (ushort)Marshal.ReadInt16(instance, 32);
            var count = Marshal.ReadInt32(instance, 40);
            var keys = Marshal.ReadIntPtr(instance, 48);
            var values = Marshal.ReadIntPtr(instance, 56);
            var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < count; i++)
            {
                var key = Marshal.PtrToStringUni(Marshal.ReadIntPtr(keys, i * IntPtr.Size));
                var value = values == IntPtr.Zero ? null : Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                if (!string.IsNullOrEmpty(key))
                    txt[key] = value ?? "";
            }
            var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(instance, 0)) ?? "";
            result?.TrySetResult(new Instance(name, addresses, port, txt));
        }
        catch (Exception)
        {
            result?.TrySetResult(null);
        }
        finally
        {
            if (instance != IntPtr.Zero)
                DnsServiceFreeInstance(instance);
        }
    };

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RegisterCallback(int status, IntPtr context, IntPtr instance);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void BrowseCallback(int status, IntPtr context, IntPtr records);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void ResolveCallback(int status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    internal struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr Callback;
        public IntPtr Context;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BrowseRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr Callback;
        public IntPtr Context;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ResolveRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public IntPtr Callback;
        public IntPtr Context;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CancelHandle
    {
        public IntPtr Reserved;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6,
        ushort port, ushort priority, ushort weight, uint propertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll")]
    static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceDeRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceBrowse(ref BrowseRequest request, ref CancelHandle cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceBrowseCancel(ref CancelHandle cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceResolve(ref ResolveRequest request, ref CancelHandle cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceResolveCancel(ref CancelHandle cancel);

    [DllImport("dnsapi.dll")]
    static extern void DnsRecordListFree(IntPtr records, int freeType);
}
