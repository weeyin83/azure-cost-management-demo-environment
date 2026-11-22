using System.Data.Common;
using Azure.Core;
using DotNetCoreSqlDb.Data;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.SqlServer.Storage.Internal;

namespace ContosoFinOps.Tests;

public class DatabaseInitializerTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Migration_connections_use_administrator_credential_including_master(bool master)
    {
        var credential = new RecordingCredential();
        var authentication = new DatabaseInitializer.AdministratorAuthenticationInterceptor(credential);
        var probe = new AuthenticationProbe();
        var options = new DbContextOptionsBuilder<MyDatabaseContext>()
            .UseSqlServer("Server=test.database.windows.net;Database=orders;Encrypt=True")
            .AddInterceptors(authentication, probe).Options;
        await using var database = new MyDatabaseContext(options);
        if (master)
        {
#pragma warning disable EF1001 // Exercise the migration provider's separate master connection.
            await using var connection = database.GetService<ISqlServerConnection>().CreateMasterConnection();
            await Assert.ThrowsAsync<ProbeCompletedException>(() => connection.OpenAsync(CancellationToken.None));
#pragma warning restore EF1001
        }
        else
        {
            await Assert.ThrowsAsync<ProbeCompletedException>(() => database.Database.OpenConnectionAsync());
        }
        Assert.Equal(master ? "master" : "orders", probe.Catalog);
        Assert.Equal("https://database.windows.net/.default", Assert.Single(credential.Scopes!));
        Assert.Equal("test-administrator-token", probe.Token);
    }

    private sealed class RecordingCredential : TokenCredential
    {
        public string[]? Scopes { get; private set; }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Scopes = requestContext.Scopes;
            return new AccessToken("test-administrator-token", DateTimeOffset.UtcNow.AddMinutes(5));
        }

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class AuthenticationProbe : DbConnectionInterceptor
    {
        public string? Catalog { get; private set; }
        public string? Token { get; private set; }

        public override async ValueTask<InterceptionResult> ConnectionOpeningAsync(
            DbConnection connection, ConnectionEventData eventData, InterceptionResult result,
            CancellationToken cancellationToken = default)
        {
            var sql = Assert.IsType<SqlConnection>(connection);
            Catalog = sql.Database;
            Assert.NotNull(sql.AccessTokenCallback);
            var token = await sql.AccessTokenCallback(new TestAuthenticationParameters(sql), cancellationToken);
            Token = token.AccessToken;
            throw new ProbeCompletedException();
        }
    }

    private sealed class TestAuthenticationParameters(SqlConnection connection) : SqlAuthenticationParameters(
        SqlAuthenticationMethod.NotSpecified, connection.DataSource, connection.Database,
        "https://database.windows.net/", "", "", "", Guid.NewGuid(), connection.ConnectionTimeout);

    private sealed class ProbeCompletedException : Exception;
}
