using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

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
        var directory = Path.GetFullPath(configuration["sql-script-directory"] ??
            throw new ArgumentException("--sql-script-directory is required."));
        var connection = new SqlConnectionStringBuilder
        {
            DataSource = $"tcp:{server},1433", InitialCatalog = "orders",
            Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault,
            Encrypt = SqlConnectionEncryptOption.Mandatory, TrustServerCertificate = false
        };
        var options = new DbContextOptionsBuilder<MyDatabaseContext>().UseSqlServer(connection.ConnectionString).Options;
        await using var database = new MyDatabaseContext(options);
        Console.WriteLine("Applying reviewed migrations as the explicitly authenticated administrator.");
        await database.Database.MigrateAsync();
        await using var sql = new SqlConnection(connection.ConnectionString);
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
        Console.WriteLine("Database initialized. Remove temporary administrator network access before publication.");
    }
}
