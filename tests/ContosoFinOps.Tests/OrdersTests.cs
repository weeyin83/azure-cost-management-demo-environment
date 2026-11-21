using System.Net;
using System.Net.Http.Json;
using System.Text.RegularExpressions;
using DotNetCoreSqlDb.Models;

namespace ContosoFinOps.Tests;

public class OrdersTests
{
    [Fact]
    public async Task ApiCrudStatusAndSummaryAreConsistent()
    {
        await using var factory = new LabFactory("OrdersAPI");
        using var client = factory.CreateClient();
        var created = await client.PostAsJsonAsync("/api/orders", new CreateOrder("Install meeting room equipment", "IT"));
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var order = (await created.Content.ReadFromJsonAsync<Todo>())!;
        Assert.True(order.ID > 0);
        Assert.Equal("Open", order.Status);
        Assert.NotEqual(default, order.CreatedUtc);
        var update = await client.PutAsJsonAsync($"/api/orders/{order.ID}/status", new UpdateOrderStatus("Completed"));
        Assert.Equal(HttpStatusCode.NoContent, update.StatusCode);
        Assert.Equal(1, (await client.GetFromJsonAsync<OrderSummary>("/api/orders/summary"))!.Completed);
        Assert.Equal("Completed", (await client.GetFromJsonAsync<Todo>($"/api/orders/{order.ID}"))!.Status);
        Assert.Equal(HttpStatusCode.NoContent, (await client.DeleteAsync($"/api/orders/{order.ID}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/orders/{order.ID}")).StatusCode);
    }

    [Theory]
    [InlineData("", "IT")]
    [InlineData("   ", "IT")]
    [InlineData("Description", "Invalid")]
    public async Task ApiRejectsInvalidInput(string description, string category)
    {
        await using var factory = new LabFactory("OrdersAPI");
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/orders",
            new CreateOrder(description, category))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PutAsJsonAsync("/api/orders/1/status",
            new UpdateOrderStatus("Unknown"))).StatusCode);
    }

    [Fact]
    public async Task DescriptionLimitIsExactly500Characters()
    {
        await using var factory = new LabFactory("OrdersAPI");
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Created, (await client.PostAsJsonAsync("/api/orders",
            new CreateOrder(new string('A', 500), "IT"))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/orders",
            new CreateOrder(new string('A', 501), "IT"))).StatusCode);
    }

    [Fact]
    public async Task CustomerFormRequiresAntiforgeryAndUsesActualApi()
    {
        await using var api = new LabFactory("OrdersAPI");
        using var apiClient = api.CreateClient();
        await using var portal = new LabFactory("CustomerPortal", apiClient);
        using var client = portal.CreateClient(new() { AllowAutoRedirect = false });
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsync("/Todos/Create",
            new FormUrlEncodedContent(new Dictionary<string, string> { ["NewTodo.Description"] = "A request" }))).StatusCode);
        var page = await client.GetStringAsync("/Todos");
        var token = Regex.Match(page, "name=\"__RequestVerificationToken\"[^>]*value=\"([^\"]+)\"").Groups[1].Value;
        Assert.NotEmpty(token);
        var result = await client.PostAsync("/Todos/Create", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["__RequestVerificationToken"] = token, ["NewTodo.Description"] = "Facilities request",
            ["NewTodo.Category"] = "Facilities"
        }));
        Assert.Equal(HttpStatusCode.Redirect, result.StatusCode);
        Assert.Single((await apiClient.GetFromJsonAsync<Todo[]>("/api/orders"))!);
    }

    [Fact]
    public async Task DependencyFailureReturns503NotEmptySuccess()
    {
        await using var factory = new LabFactory("CustomerPortal");
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/Todos")).StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/health/ready")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/live")).StatusCode);
    }
}
