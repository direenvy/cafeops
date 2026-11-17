using CafeOps.Domain;
using Microsoft.AspNetCore.Mvc;

namespace CafeOps.Api;

/// <summary>
/// Translates domain refusals into HTTP, in one place.
/// </summary>
/// <remarks>
/// Every failure comes back as RFC 9457 problem details carrying the domain's
/// stable error code, so the Flutter client can branch on
/// <c>stock.insufficient</c> rather than parsing an English sentence.
/// </remarks>
public static class ApiResults
{
    public static ActionResult Problem(this ControllerBase controller, DomainError error)
    {
        ArgumentNullException.ThrowIfNull(controller);
        ArgumentNullException.ThrowIfNull(error);

        var status = error.Kind switch
        {
            ErrorKind.Validation => StatusCodes.Status400BadRequest,
            ErrorKind.Forbidden => StatusCodes.Status403Forbidden,
            ErrorKind.NotFound => StatusCodes.Status404NotFound,
            ErrorKind.Conflict => StatusCodes.Status409Conflict,
            _ => StatusCodes.Status500InternalServerError,
        };

        var problem = controller.ProblemDetails(error, status);

        return new ObjectResult(problem)
        {
            StatusCode = status,
            ContentTypes = { "application/problem+json" },
        };
    }

    private static ProblemDetails ProblemDetails(
        this ControllerBase controller,
        DomainError error,
        int status) => new()
    {
        Status = status,
        Title = error.Kind switch
        {
            ErrorKind.Validation => "Invalid request",
            ErrorKind.Forbidden => "Not allowed",
            ErrorKind.NotFound => "Not found",
            ErrorKind.Conflict => "Cannot do that right now",
            _ => "Unexpected error",
        },
        Detail = error.Message,
        Instance = controller.HttpContext.Request.Path,
        Extensions =
        {
            ["code"] = error.Code,
        },
    };

    /// <summary>
    /// Unwraps a <see cref="Result{T}"/> into either a 200 or a problem.
    /// </summary>
    public static ActionResult ToActionResult<T>(this Result<T> result, ControllerBase controller)
    {
        ArgumentNullException.ThrowIfNull(controller);

        return result.IsSuccess
            ? new OkObjectResult(result.Value)
            : controller.Problem(result.Error!);
    }
}
