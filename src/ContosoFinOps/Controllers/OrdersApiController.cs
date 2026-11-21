using DotNetCoreSqlDb.Models;
using DotNetCoreSqlDb.Services;
using Microsoft.AspNetCore.Mvc;

namespace DotNetCoreSqlDb.Controllers;

[ApiController, Route("api/orders")]
public class OrdersApiController(IOrdersService orders) : ControllerBase
{
    [HttpGet]
    public Task<IReadOnlyList<Todo>> List(CancellationToken ct) => orders.ListAsync(ct);
    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id, CancellationToken ct) =>
        await orders.FindAsync(id, ct) is { } order ? Ok(order) : NotFound();
    [HttpGet("summary")]
    public Task<OrderSummary> Summary(CancellationToken ct) => orders.SummaryAsync(ct);
    [HttpPost]
    public async Task<IActionResult> Create(CreateOrder input, CancellationToken ct)
    {
        var order = await orders.CreateAsync(input, ct);
        return CreatedAtAction(nameof(Get), new { id = order.ID }, order);
    }
    [HttpPut("{id:int}/status")]
    public async Task<IActionResult> Status(int id, UpdateOrderStatus input, CancellationToken ct) =>
        await orders.UpdateStatusAsync(id, input.Status, ct) ? NoContent() : NotFound();
    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, CancellationToken ct) =>
        await orders.DeleteAsync(id, ct) ? NoContent() : NotFound();
}
