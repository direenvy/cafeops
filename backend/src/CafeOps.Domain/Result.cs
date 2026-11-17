namespace CafeOps.Domain;

/// <summary>
/// Why an operation was refused. These map onto HTTP status codes at the edge,
/// which keeps the domain free of any dependency on ASP.NET Core.
/// </summary>
public enum ErrorKind
{
    /// <summary>The request itself is malformed. 400.</summary>
    Validation,

    /// <summary>The caller is not allowed to do this. 403.</summary>
    Forbidden,

    /// <summary>Something referenced does not exist. 404.</summary>
    NotFound,

    /// <summary>The request is well formed but the current state refuses it. 409.</summary>
    Conflict,
}

/// <summary>A single refusal, with a stable machine-readable code.</summary>
/// <param name="Kind">How the edge should translate this.</param>
/// <param name="Code">Stable identifier, e.g. <c>stock.insufficient</c>.</param>
/// <param name="Message">Human-readable detail, safe to show a user.</param>
public sealed record DomainError(ErrorKind Kind, string Code, string Message)
{
    public static DomainError Validation(string code, string message) =>
        new(ErrorKind.Validation, code, message);

    public static DomainError Forbidden(string code, string message) =>
        new(ErrorKind.Forbidden, code, message);

    public static DomainError NotFound(string code, string message) =>
        new(ErrorKind.NotFound, code, message);

    public static DomainError Conflict(string code, string message) =>
        new(ErrorKind.Conflict, code, message);
}

/// <summary>
/// The outcome of an operation that can fail for expected reasons.
/// </summary>
/// <remarks>
/// Expected failures — an out-of-stock ingredient, an order that is already
/// paid — are return values here rather than exceptions. Exceptions are kept
/// for genuine faults, so the logs stay meaningful.
/// </remarks>
public readonly struct Result<T>
{
    private readonly T? _value;

    private Result(T value)
    {
        _value = value;
        Error = null;
    }

    private Result(DomainError error)
    {
        _value = default;
        Error = error;
    }

    public DomainError? Error { get; }

    public bool IsSuccess => Error is null;

    public T Value => IsSuccess
        ? _value!
        : throw new InvalidOperationException(
            $"Cannot read the value of a failed result ({Error!.Code}).");

    public static Result<T> Success(T value) => new(value);

    public static Result<T> Failure(DomainError error) => new(error);

    public static implicit operator Result<T>(T value) => Success(value);

    public static implicit operator Result<T>(DomainError error) => Failure(error);

    public TOut Match<TOut>(Func<T, TOut> onSuccess, Func<DomainError, TOut> onFailure) =>
        IsSuccess ? onSuccess(_value!) : onFailure(Error!);
}
