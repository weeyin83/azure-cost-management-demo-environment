using DotNetCoreSqlDb.Configuration;
using DotNetCoreSqlDb.Data;
using DotNetCoreSqlDb.Services;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;

namespace ContosoFinOps.Tests;

internal sealed class LabFactory(string role, HttpClient? upstream = null) : WebApplicationFactory<Program>
{
    private readonly string database = Guid.NewGuid().ToString();
    protected override IHost CreateHost(IHostBuilder builder)
    {
        // Minimal-hosting startup reads these settings before deferred app-configuration callbacks run.
        builder.ConfigureHostConfiguration(config => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            [HostDefaults.EnvironmentKey] = "Testing",
            ["Deployment:Role"] = role,
            ["Deployment:ApiBaseUri"] = "http://orders.test/",
            ["Deployment:ReportStorageUri"] = "",
            ["ConnectionStrings:Orders"] = "Server=localhost;Database=Test;Integrated Security=true",
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = ""
        }));
        return base.CreateHost(builder);
    }
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureServices(services =>
        {
            if (role is "OrdersAPI" or "DevelopmentPortal")
            {
                services.RemoveAll<DbContextOptions<MyDatabaseContext>>();
                services.RemoveAll<IDbContextOptionsConfiguration<MyDatabaseContext>>();
                services.AddDbContext<MyDatabaseContext>(options => options.UseInMemoryDatabase(database));
            }
            else
                services.AddHttpClient<IOrdersService, HttpOrdersService>()
                    .ConfigurePrimaryHttpMessageHandler(() => new ForwardingHandler(upstream));
        });
    }
    private sealed class ForwardingHandler(HttpClient? client) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (client is null) throw new HttpRequestException("Deliberate upstream failure for test.");
            using var forwarded = new HttpRequestMessage(request.Method,
                "http://localhost" + request.RequestUri!.PathAndQuery) { Content = request.Content };
            return await client.SendAsync(forwarded, ct);
        }
    }
}
