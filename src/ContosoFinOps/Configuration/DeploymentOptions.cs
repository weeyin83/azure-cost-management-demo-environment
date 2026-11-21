using Microsoft.AspNetCore.Mvc.ApplicationModels;
using Microsoft.Data.SqlClient;

namespace DotNetCoreSqlDb.Configuration;

public enum DeploymentRole { CustomerPortal, OrdersAPI, ReportingPortal, DevelopmentPortal }

public sealed record DeploymentOptions(DeploymentRole Role, string EnvironmentLabel,
    Uri? ApiBaseUri, Uri? ReportStorageUri)
{
    public bool UsesSql => Role is DeploymentRole.OrdersAPI or DeploymentRole.DevelopmentPortal;

    public static DeploymentOptions Read(IConfiguration config, IHostEnvironment environment)
    {
        if (!Enum.TryParse<DeploymentRole>(config["Deployment:Role"], false, out var role) ||
            !Enum.IsDefined(role) || config["Deployment:Role"] != role.ToString())
            throw new InvalidOperationException("Deployment:Role must name one of the four deployment roles.");
        Uri? api = null;
        Uri? storage = null;
        if (role is DeploymentRole.CustomerPortal or DeploymentRole.ReportingPortal)
        {
            api = Endpoint(config["Deployment:ApiBaseUri"], "Deployment:ApiBaseUri", environment);
            if (!api.AbsoluteUri.EndsWith('/'))
                throw new InvalidOperationException("Deployment:ApiBaseUri must end with '/'.");
        }
        if (role == DeploymentRole.ReportingPortal &&
            !string.IsNullOrWhiteSpace(config["Deployment:ReportStorageUri"]))
            storage = Endpoint(config["Deployment:ReportStorageUri"], "Deployment:ReportStorageUri", environment);
        if (role is DeploymentRole.OrdersAPI or DeploymentRole.DevelopmentPortal)
        {
            var connection = config.GetConnectionString("Orders");
            if (string.IsNullOrWhiteSpace(connection))
                throw new InvalidOperationException("ConnectionStrings:Orders must be explicitly configured.");
            var sql = new SqlConnectionStringBuilder(connection);
            if (!environment.IsDevelopment() && !environment.IsEnvironment("Testing") &&
                (sql.Authentication != SqlAuthenticationMethod.ActiveDirectoryManagedIdentity ||
                 !sql.Encrypt || sql.TrustServerCertificate))
                throw new InvalidOperationException("Azure SQL requires managed identity, encryption and certificate validation.");
        }
        if (role == DeploymentRole.ReportingPortal && storage is null &&
            !environment.IsDevelopment() && !environment.IsEnvironment("Testing"))
            throw new InvalidOperationException("ReportingPortal requires Deployment:ReportStorageUri in Azure.");
        return new(role, config["Deployment:EnvironmentLabel"] ?? environment.EnvironmentName, api, storage);
    }

    private static Uri Endpoint(string? value, string name, IHostEnvironment environment)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttps &&
             !(environment.IsDevelopment() || environment.IsEnvironment("Testing"))))
            throw new InvalidOperationException($"{name} must be an absolute HTTPS URI.");
        if (uri.Scheme is not ("https" or "http") || !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new InvalidOperationException($"{name} must be an HTTP(S) endpoint without credentials, query or fragment.");
        return uri;
    }
}

public sealed class DeploymentRoleConvention(DeploymentRole role) : IApplicationModelConvention
{
    public void Apply(ApplicationModel application)
    {
        var allowed = role switch
        {
            DeploymentRole.CustomerPortal => new[] { "Home", "Todos" },
            DeploymentRole.ReportingPortal => ["Home", "Reports"],
            DeploymentRole.OrdersAPI => ["OrdersApi"],
            DeploymentRole.DevelopmentPortal => ["Home", "Todos", "OrdersApi"],
            _ => throw new InvalidOperationException("Unsupported deployment role.")
        };
        foreach (var controller in application.Controllers.ToArray())
            if (!allowed.Contains(controller.ControllerName))
                application.Controllers.Remove(controller);
    }
}
