using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Droprr;

// The one-time access code for Browser access (docs/PROTOCOL.md, "Browser access"). It exists only while the
// "Open in a browser" window is open, for at most 10 minutes, and works once. Five wrong codes close it.
// Never saved or logged.
sealed class BrowserAccess
{
    static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);
    const int MaxWrong = 5;
    const int Length = 8;

    // Crockford base32: no I, L, O, or U, so a code read off a screen can't be mistyped as another letter.
    const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    public enum Result { Accepted, Wrong, Closed }

    readonly object _gate = new();
    string? _code;
    DateTime _expires;
    int _wrong;

    // Raised on a server thread when the code stops working: used, or closed after too many wrong tries.
    public event Action<bool>? Ended;

    // A fresh code, replacing any earlier one.
    public string Open()
    {
        var bytes = RandomNumberGenerator.GetBytes(Length);
        var code = new string(bytes.Select(b => Alphabet[b % Alphabet.Length]).ToArray());
        lock (_gate)
        {
            _code = code;
            _expires = DateTime.UtcNow + Lifetime;
            _wrong = 0;
        }
        return code;
    }

    public void Close()
    {
        lock (_gate)
            _code = null;
    }

    // "XXXX-XXXX", for showing and typing.
    public static string Format(string code) => code.Length == Length ? $"{code[..4]}-{code[4..]}" : code;

    // Upper case, without separators, with the letters Crockford reads as digits (O as 0, I and L as 1).
    static string Normalize(string given) => new(given.ToUpperInvariant()
        .Select(c => c switch { 'O' => '0', 'I' or 'L' => '1', _ => c })
        .Where(c => Alphabet.Contains(c))
        .ToArray());

    public Result TryUse(string? given)
    {
        bool ended;
        Result result;
        lock (_gate)
        {
            if (_code is null || DateTime.UtcNow >= _expires)
            {
                _code = null;
                return Result.Closed;
            }
            var match = CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(Normalize(given ?? "")), Encoding.ASCII.GetBytes(_code));
            if (match)
            {
                _code = null;
                result = Result.Accepted;
                ended = true;
            }
            else
            {
                ended = ++_wrong >= MaxWrong;
                if (ended)
                    _code = null;
                result = Result.Wrong;
            }
        }
        if (ended)
            Ended?.Invoke(result == Result.Accepted);
        return result;
    }
}
