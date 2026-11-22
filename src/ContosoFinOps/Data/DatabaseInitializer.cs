using System.Data.Common;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace DotNetCoreSqlDb.Data;

public static class DatabaseInitializer
{
    public static async Task RunAsync(IConfiguration configuration)
    {
        var server = configuration["server"] ?? throw new ArgumentException("--server is required.");
        var user = configuration["runtime-user"] ?? throw new ArgumentException("--runtime-user is required.");
        if (!Regex.IsMatch(server, @"^[a-z0-9-]+\.database\.windows\.net$") ||
            !Regex.IsMatch(user, @"^[a-zA-Z0-9-]{1,128}$"))
            throw new ArgumentException("Invalid server or runtime user.");
        if (!Guid.TryParse(configuration["runtime-client-id"], out var clientId))
            throw new ArgumentException("--runtime-client-id must be the managed identity's application/client ID.");
        if (!Guid.TryParse(configuration["tenant-id"], out var tenantId) || tenantId == Guid.Empty)
            throw new ArgumentException("--tenant-id must be the selected SQL administrator's tenant ID.");
        var directory = Path.GetFullPath(configuration["sql-script-directory"] ??
            throw new ArgumentException("--sql-script-directory is required."));
        var connection = new SqlConnectionStringBuilder
        {
            DataSource = $"tcp:{server},1433", InitialCatalog = "orders",
            Encrypt = SqlConnectionEncryptOption.Mandatory, TrustServerCertificate = false
        };
        var credential = new AzureCliCredential(new AzureCliCredentialOptions { TenantId = tenantId.ToString() });
        var authentication = new AdministratorAuthenticationInterceptor(credential);
        await using var sql = new SqlConnection(connection.ConnectionString);
        authentication.Apply(sql);
        var options = new DbContextOptionsBuilder<MyDatabaseContext>().UseSqlServer(sql)
            .AddInterceptors(authentication).Options;
        await using var database = new MyDatabaseContext(options);
        try
        {
            Console.WriteLine("Applying reviewed migrations using the Azure CLI login in the SQL administrator tenant.");
            await database.Database.MigrateAsync();
            await sql.OpenAsync();
            var grant = await File.ReadAllTextAsync(Path.Combine(directory, "grant-database-access.sql"));
            grant = grant.Replace("$(RuntimeUser)", user)
                .Replace("$(RuntimeSid)", Convert.ToHexString(clientId.ToByteArray()));
            await using (var command = new SqlCommand(grant, sql)) await command.ExecuteNonQueryAsync();
            if (configuration.GetValue<bool>("seed"))
            {
                var seed = await File.ReadAllTextAsync(Path.Combine(directory, "seed-demo.sql"));
                await using var command = new SqlCommand(seed, sql);
                await command.ExecuteNonQueryAsync();
            }
        }
        catch (SqlException exception) when (exception.Number == 18456)
        {
            throw new InvalidOperationException(
                $"SQL rejected the Azure CLI login in tenant {tenantId}. Run az login --tenant {tenantId} " +
                "as the configured SQL Entra administrator or a member of its administrator group. " +
                "Verify group membership and sign in again after membership changes. " +
                "Subscription Owner/Contributor permissions do not grant SQL data-plane access. " +
                "No administrator, directory permissions or firewall rules are changed automatically.", exception);
        }
        Console.WriteLine("Database initialized. Remove temporary administrator network access before publication.");
    }

    internal sealed class AdministratorAuthenticationInterceptor(TokenCredential credential) : DbConnectionInterceptor
    {
        private readonly Func<SqlAuthenticationParameters, CancellationToken, Task<SqlAuthenticationToken>> callback =
            async (_, cancellationToken) =>
            {
                var token = await credential.GetTokenAsync(
                    new TokenRequestContext(["https://database.windows.net/.default"]), cancellationToken);
                return new SqlAuthenticationToken(token.Token, token.ExpiresOn);
            };

        public void Apply(SqlConnection connection) => connection.AccessTokenCallback = callback;

        public override InterceptionResult ConnectionOpening(
            DbConnection connection, ConnectionEventData eventData, InterceptionResult result)
        {
            Apply((SqlConnection)connection);
            return result;
        }

        public override ValueTask<InterceptionResult> ConnectionOpeningAsync(
            DbConnection connection, ConnectionEventData eventData, InterceptionResult result,
            CancellationToken cancellationToken = default)
        {
            Apply((SqlConnection)connection);
            return ValueTask.FromResult(result);
        }
    }
}
