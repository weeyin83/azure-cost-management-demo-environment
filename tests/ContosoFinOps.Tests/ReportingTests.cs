using System.Net;
using System.Net.Http.Json;
using DotNetCoreSqlDb.Models;
using DotNetCoreSqlDb.Services;

namespace ContosoFinOps.Tests;

public class ReportingTests
{
    [Fact]
    public void CsvQuotesAndNeutralizesSpreadsheetFormulas()
    {
        var csv = System.Text.Encoding.UTF8.GetString(ReportExportService.Csv([
            new() { ID = 1, Description = " =HYPERLINK(\"evil\")", Category = "IT", Status = "Open" },
            new() { ID = 2, Description = "Line 1,\nLine \"2\"", Category = "IT", Status = "Open" }
        ]));
        Assert.Contains("\"' =HYPERLINK(\"\"evil\"\")\"", csv);
        Assert.Contains("\"Line 1,\nLine \"\"2\"\"\"", csv);
    }
    [Fact]
    public async Task ReportingReadsLiveApiAndCannotMutate()
    {
        await using var api = new LabFactory("OrdersAPI");
        using var apiClient = api.CreateClient();
        await apiClient.PostAsJsonAsync("/api/orders", new CreateOrder("Quarterly service review", "Consulting"));
        await using var reporting = new LabFactory("ReportingPortal", apiClient);
        using var client = reporting.CreateClient();
        Assert.Contains("Quarterly service review", await client.GetStringAsync("/Reports"));
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsJsonAsync("/api/orders",
            new CreateOrder("Not allowed", "IT"))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsync("/Reports/Export", null)).StatusCode);
    }
}
