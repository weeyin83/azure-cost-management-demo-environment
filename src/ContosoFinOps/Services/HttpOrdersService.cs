using System.Net;
using System.Net.Http.Json;
using DotNetCoreSqlDb.Models;

namespace DotNetCoreSqlDb.Services;

public sealed class HttpOrdersService(HttpClient client) : IOrdersService
{
    private async Task<T> ReadAsync<T>(string path, CancellationToken ct)
    {
        using var response = await client.GetAsync(path, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<T>(ct) ??
            throw new HttpRequestException("The Orders API returned an empty response.");
    }
    public async Task<IReadOnlyList<Todo>> ListAsync(CancellationToken ct) =>
        await ReadAsync<Todo[]>("api/orders", ct);
    public async Task<Todo?> FindAsync(int id, CancellationToken ct)
    {
        using var response = await client.GetAsync($"api/orders/{id}", ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Todo>(ct) ??
            throw new HttpRequestException("The Orders API returned an empty order.");
    }
    public async Task<Todo> CreateAsync(CreateOrder order, CancellationToken ct)
    {
        using var response = await client.PostAsJsonAsync("api/orders", order, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<Todo>(ct) ??
            throw new HttpRequestException("The Orders API returned an empty created order.");
    }
    public async Task<bool> UpdateStatusAsync(int id, string status, CancellationToken ct)
    {
        using var response = await client.PutAsJsonAsync($"api/orders/{id}/status", new UpdateOrderStatus(status), ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        return true;
    }
    public async Task<bool> DeleteAsync(int id, CancellationToken ct)
    {
        using var response = await client.DeleteAsync($"api/orders/{id}", ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        return true;
    }
    public Task<OrderSummary> SummaryAsync(CancellationToken ct) =>
        ReadAsync<OrderSummary>("api/orders/summary", ct);
}
