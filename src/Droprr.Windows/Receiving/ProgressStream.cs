using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// Read-only pass-through stream that reports how many bytes have been read.
sealed class ProgressStream : Stream
{
    readonly Stream _inner;
    readonly Action<int> _onRead;

    public ProgressStream(Stream inner, Action<int> onRead)
    {
        _inner = inner;
        _onRead = onRead;
    }

    public override int Read(byte[] buffer, int offset, int count) => Counted(_inner.Read(buffer, offset, count));

    public override int Read(Span<byte> buffer) => Counted(_inner.Read(buffer));

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default) =>
        Counted(await _inner.ReadAsync(buffer, cancel));

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancel) =>
        ReadAsync(buffer.AsMemory(offset, count), cancel).AsTask();

    int Counted(int read)
    {
        if (read > 0)
            _onRead(read);
        return read;
    }

    public override bool CanRead => _inner.CanRead;
    public override bool CanSeek => _inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length => _inner.Length;

    public override long Position
    {
        get => _inner.Position;
        set => _inner.Position = value;
    }

    public override long Seek(long offset, SeekOrigin origin) => _inner.Seek(offset, origin);
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _inner.Dispose();
        base.Dispose(disposing);
    }
}
