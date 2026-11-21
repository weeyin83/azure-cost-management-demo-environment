using Azure.Identity;
using Azure.Storage.Blobs;
using DotNetCoreSqlDb.Configuration;
using DotNetCoreSqlDb.Data;
using DotNetCoreSqlDb.Health;
using DotNetCoreSqlDb.Services;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
if (builder.Configuration.GetValue<bool>("initialize-database"))
{
    await DatabaseInitializer.RunAsync(builder.Configuration);
    return;
}
var deployment = DeploymentOptions.Read(builder.Configuration, builder.Environment);
builder.Services.AddSingleton(deployment);
builder.Services.AddControllersWithViews(options =>
    options.Conventions.Add(new DeploymentRoleConvention(deployment.Role)));
builder.Services.AddAntiforgery(options =>
    options.Cookie.SecurePolicy = builder.Environment.IsDevelopment() || builder.Environment.IsEnvironment("Testing")
        ? CookieSecurePolicy.None : CookieSecurePolicy.Always);
builder.Services.AddProblemDetails();
builder.Services.AddApplicationInsightsTelemetry();
builder.Logging.AddAzureWebAppDiagnostics();

if (deployment.UsesSql)
{
    builder.Services.AddDbContext<MyDatabaseContext>(options =>
        options.UseSqlServer(builder.Configuration.GetConnectionString("Orders"),
            sql => sql.EnableRetryOnFailure(3)));
    builder.Services.AddScoped<IOrdersService, SqlOrdersService>();
}
else
{
    builder.Services.AddHttpClient<IOrdersService, HttpOrdersService>(client =>
    {
        client.BaseAddress = deployment.ApiBaseUri;
        client.Timeout = TimeSpan.FromSeconds(15);
    });
}
if (deployment.Role == DeploymentRole.ReportingPortal)
{
    if (deployment.ReportStorageUri is not null)
        builder.Services.AddSingleton(new BlobContainerClient(deployment.ReportStorageUri,
            new ManagedIdentityCredential()));
    builder.Services.AddScoped<ReportExportService>();
}
builder.Services.AddHealthChecks().AddCheck<ReadinessHealthCheck>("dependencies", tags: ["ready"],
    timeout: TimeSpan.FromSeconds(20));
var app = builder.Build();

app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    var error = context.Features.Get<IExceptionHandlerFeature>()!.Error;
    app.Logger.LogError(error, "Request failed: {TraceId}", context.TraceIdentifier);
    context.Response.StatusCode = error is HttpRequestException or TaskCanceledException ? 503 : 500;
    await Results.Problem(statusCode: context.Response.StatusCode,
        title: context.Response.StatusCode == 503 ? "The orders service is unavailable." : "The request failed.",
        extensions: new Dictionary<string, object?> { ["traceId"] = context.TraceIdentifier })
        .ExecuteAsync(context);
}));
if (!app.Environment.IsDevelopment() && !app.Environment.IsEnvironment("Testing"))
{
    app.UseHsts();
    app.UseWhen(context => !context.Request.Path.StartsWithSegments("/health"),
        branch => branch.UseHttpsRedirection());
}
app.UseStaticFiles();
app.UseRouting();
app.UseAuthorization();
app.MapHealthChecks("/health/live", new() { Predicate = _ => false });
app.MapHealthChecks("/health/ready", new() { Predicate = check => check.Tags.Contains("ready") });
app.MapControllers();
app.MapControllerRoute("default", "{controller=Home}/{action=Index}/{id?}");
app.Run();

public partial class Program;
