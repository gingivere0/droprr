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
//
// dnsapi keeps using a request (and the cancel handle and strings it points to) after the call returns, and calls
// back on its own threads, sometimes after a network change has already ended the operation. So every request,
// cancel handle, and string lives in unmanaged memory that's freed only well after the operation is over, an
// operation is cancelled only while it's still running, and callbacks never touch freed state.
static class Dnssd
{
    public sealed record Instance(string FullName, IReadOnlyList<IPAddress> Addresses, int Port, IReadOnlyDictionary<string, string> Txt);

    const uint QueryRequestVersion1 = 1;
    const int RequestPending = 9506; // DNS_REQUEST_PENDING
    const ushort TypePtr = 12;

    // How long freed-looking memory is kept after an operation ends, in case dnsapi still has a callback in flight.
    static readonly TimeSpan Linger = TimeSpan.FromSeconds(30);

    // One registration: keep it to unregister. Dispose unregisters. Its request and instance are never freed:
    // dnsapi may hold them until deregistration completes, and there's one per network interface per restart.
    public sealed class Registration : IDisposable
    {
        internal IntPtr Request;
        int _disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;
            try
            {
                var status = DnsServiceDeRegister(Request, IntPtr.Zero);
                if (status != RequestPending && status != 0)
                    RequestLog.Note($"local network: DnsServiceDeRegister failed ({status})");
            }
            catch (Exception)
            {
                // Best effort.
            }
        }
    }

    // Registers "<name>.<type>.local" on one interface (0 for all) with the given port and TXT record.
    public static Registration? Register(string name, string type, int port, IReadOnlyDictionary<string, string> txt,
        uint interfaceIndex, IPAddress? ipv4)
    {
        var keys = txt.Keys.ToArray();
        var values = keys.Select(k => txt[k]).ToArray();
        var host = Dns.GetHostName() + ".local";
        var address = IntPtr.Zero;
        if (ipv4 is not null)
        {
            address = Marshal.AllocHGlobal(4);
            Marshal.Copy(ipv4.GetAddressBytes(), 0, address, 4);
        }
        var instance = DnsServiceConstructInstance($"{Escape(name)}.{type}.local", host, address, IntPtr.Zero,
            (ushort)port, 0, 0, (uint)keys.Length, keys, values);
        if (instance == IntPtr.Zero)
            return null;
        var request = Alloc(new RegisterRequest
        {
            Version = QueryRequestVersion1,
            InterfaceIndex = interfaceIndex,
            ServiceInstance = instance,
            Callback = Marshal.GetFunctionPointerForDelegate(RegisterDone),
        });
        var status = DnsServiceRegister(request, IntPtr.Zero);
        if (status != RequestPending)
        {
            RequestLog.Note($"local network: DnsServiceRegister failed ({status})");
            return null;
        }
        return new Registration { Request = request };
    }

    // Instance names ("." and "\" escaped) can't hold a raw dot.
    static string Escape(string name) => name.Replace("\\", "\\\\").Replace(".", "\\.");

    sealed class BrowseState
    {
        public readonly ConcurrentDictionary<string, byte> Names = new(StringComparer.OrdinalIgnoreCase);
        // Set by dnsapi's final callback (an error, or the cancel completing): the browse is over.
        public volatile bool Ended;
    }

    // Browses for `type` for `duration`, then resolves every instance found. Results don't include instances
    // that didn't resolve within the timeout.
    public static async Task<IReadOnlyList<Instance>> BrowseAsync(string type, TimeSpan duration, CancellationToken cancel)
    {
        var state = new BrowseState();
        var context = GCHandle.Alloc(state);
        var query = Marshal.StringToHGlobalUni(type + ".local");
        var request = Alloc(new BrowseRequest
        {
            Version = QueryRequestVersion1,
            QueryName = query,
            Callback = Marshal.GetFunctionPointerForDelegate(BrowseFound),
            Context = GCHandle.ToIntPtr(context),
        });
        var cancelHandle = Alloc(new CancelHandle());
        var started = DnsServiceBrowse(request, cancelHandle) == RequestPending;
        try
        {
            if (!started)
                return [];
            try
            {
                await Task.Delay(duration, cancel);
            }
            catch (OperationCanceledException)
            {
                return [];
            }
        }
        finally
        {
            // Only a browse that's still running can be cancelled; one a network change ended already can't.
            if (started && !state.Ended)
                DnsServiceBrowseCancel(cancelHandle);
            FreeLater(context, query, request, cancelHandle);
        }

        var resolved = await Task.WhenAll(state.Names.Keys.Select(name => ResolveAsync(name, TimeSpan.FromSeconds(3))));
        return resolved.OfType<Instance>().ToList();
    }

    sealed class ResolveState
    {
        public readonly TaskCompletionSource<Instance?> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    static async Task<Instance?> ResolveAsync(string fullName, TimeSpan timeout)
    {
        var state = new ResolveState();
        var context = GCHandle.Alloc(state);
        var query = Marshal.StringToHGlobalUni(fullName);
        var request = Alloc(new ResolveRequest
        {
            Version = QueryRequestVersion1,
            QueryName = query,
            Callback = Marshal.GetFunctionPointerForDelegate(ResolveDone),
            Context = GCHandle.ToIntPtr(context),
        });
        var cancelHandle = Alloc(new CancelHandle());
        try
        {
            if (DnsServiceResolve(request, cancelHandle) != RequestPending)
                return null;
            if (await Task.WhenAny(state.Result.Task, Task.Delay(timeout)) != state.Result.Task && !state.Result.Task.IsCompleted)
            {
                DnsServiceResolveCancel(cancelHandle);
                await Task.WhenAny(state.Result.Task, Task.Delay(500));
            }
            return state.Result.Task.IsCompletedSuccessfully ? state.Result.Task.Result : null;
        }
        finally
        {
            FreeLater(context, query, request, cancelHandle);
        }
    }

    static IntPtr Alloc<T>(T value) where T : struct
    {
        var memory = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        Marshal.StructureToPtr(value, memory, false);
        return memory;
    }

    // Frees an operation's memory once dnsapi can't be using it any more.
    static void FreeLater(GCHandle context, params IntPtr[] memory) => _ = Task.Delay(Linger).ContinueWith(_ =>
    {
        foreach (var block in memory)
            Marshal.FreeHGlobal(block);
        context.Free();
    }, TaskScheduler.Default);

    // Callbacks: static delegates, so the garbage collector never frees one dnsapi still holds. They never throw.
    static readonly RegisterCallback RegisterDone = (status, _, _) =>
    {
        if (status != 0)
            RequestLog.Note($"local network: registration finished with status {status}");
    };

    static readonly BrowseCallback BrowseFound = (status, context, records) =>
    {
        try
        {
            if (context != IntPtr.Zero && GCHandle.FromIntPtr(context).Target is BrowseState state)
            {
                if (status != 0)
                    state.Ended = true;
                // DNS_RECORD: pNext at 0, pName at 8, wType at 16, Data (PTR: pNameHost) at 32.
                for (var record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record, 0))
                {
                    if ((ushort)Marshal.ReadInt16(record, 16) == TypePtr && Marshal.PtrToStringUni(Marshal.ReadIntPtr(record, 32)) is { Length: > 0 } name)
                        state.Names.TryAdd(name, 0);
                }
            }
        }
        catch (Exception)
        {
            // Never let an exception unwind into dnsapi.
        }
        finally
        {
            if (records != IntPtr.Zero)
                DnsRecordListFree(records, 1 /* DnsFreeRecordList */);
        }
    };

    static readonly ResolveCallback ResolveDone = (status, context, instance) =>
    {
        ResolveState? state = null;
        try
        {
            state = GCHandle.FromIntPtr(context).Target as ResolveState;
            if (status != 0 || instance == IntPtr.Zero)
            {
                state?.Result.TrySetResult(null);
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
            for (var i = 0; i < count && keys != IntPtr.Zero; i++)
            {
                var key = Marshal.PtrToStringUni(Marshal.ReadIntPtr(keys, i * IntPtr.Size));
                var value = values == IntPtr.Zero ? null : Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                if (!string.IsNullOrEmpty(key))
                    txt[key] = value ?? "";
            }
            var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(instance, 0)) ?? "";
            state?.Result.TrySetResult(new Instance(name, addresses, port, txt));
        }
        catch (Exception)
        {
            state?.Result.TrySetResult(null);
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
    struct RegisterRequest
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
    static extern int DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceDeRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceBrowse(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceBrowseCancel(IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceResolve(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern int DnsServiceResolveCancel(IntPtr cancel);

    [DllImport("dnsapi.dll")]
    static extern void DnsRecordListFree(IntPtr records, int freeType);
}
