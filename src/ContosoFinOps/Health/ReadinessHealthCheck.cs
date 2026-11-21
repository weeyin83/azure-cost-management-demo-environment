using Azure.Storage.Blobs;
using DotNetCoreSqlDb.Configuration;
using DotNetCoreSqlDb.Data;
using DotNetCoreSqlDb.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace DotNetCoreSqlDb.Health;

public sealed class ReadinessHealthCheck(IServiceProvider services, DeploymentOptions deployment,
    ILogger<ReadinessHealthCheck> logger) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken ct)
    {
        try
        {
            if (deployment.UsesSql)
                _ = await services.GetRequiredService<MyDatabaseContext>().Todo.AsNoTracking()
                    .Select(x => x.ID).Take(1).ToListAsync(ct);
            else
                _ = await services.GetRequiredService<IOrdersService>().SummaryAsync(ct);
            if (deployment.Role == DeploymentRole.ReportingPortal && deployment.ReportStorageUri is not null)
                await services.GetRequiredService<BlobContainerClient>().GetPropertiesAsync(cancellationToken: ct);
            return HealthCheckResult.Healthy();
        }
        catch (Exception error) when (error is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            logger.LogError(error, "Readiness dependency failed for {Role}.", deployment.Role);
            return HealthCheckResult.Unhealthy("A required dependency is unavailable.");
        }
    }
}
