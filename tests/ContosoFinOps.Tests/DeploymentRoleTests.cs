using System.Net;
using DotNetCoreSqlDb.Configuration;
using DotNetCoreSqlDb.Data;
using DotNetCoreSqlDb.Services;
using Microsoft.Extensions.DependencyInjection;

namespace ContosoFinOps.Tests;

public class DeploymentRoleTests
{
    [Theory]
    [InlineData("CustomerPortal", "/api/orders")]
    [InlineData("ReportingPortal", "/api/orders")]
    [InlineData("ReportingPortal", "/Todos")]
    [InlineData("OrdersAPI", "/Todos")]
    [InlineData("DevelopmentPortal", "/Reports")]
    public async Task RolesDoNotExposeOtherRolesRoutes(string role, string path)
    {
        await using var factory = new LabFactory(role);
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync(path)).StatusCode);
    }
    [Theory]
    [InlineData("CustomerPortal")]
    [InlineData("ReportingPortal")]
    public void ProductionPortalsHaveNoSqlContext(string role)
    {
        using var factory = new LabFactory(role);
        using var scope = factory.Services.CreateScope();
        Assert.Null(scope.ServiceProvider.GetService<MyDatabaseContext>());
        Assert.IsType<HttpOrdersService>(scope.ServiceProvider.GetRequiredService<IOrdersService>());
        Assert.False(scope.ServiceProvider.GetRequiredService<DeploymentOptions>().UsesSql);
    }
    [Fact]
    public void InvalidRoleFailsStartup()
    {
        using var factory = new LabFactory("Typo");
        Assert.Throws<InvalidOperationException>(() => factory.CreateClient());
    }
}
