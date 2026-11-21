using DotNetCoreSqlDb.Data;
using DotNetCoreSqlDb.Models;
using Microsoft.EntityFrameworkCore;

namespace DotNetCoreSqlDb.Services;

public sealed class SqlOrdersService(MyDatabaseContext database) : IOrdersService
{
    public async Task<IReadOnlyList<Todo>> ListAsync(CancellationToken ct) =>
        await database.Todo.AsNoTracking().OrderByDescending(x => x.ID).Take(200).ToListAsync(ct);
    public Task<Todo?> FindAsync(int id, CancellationToken ct) =>
        database.Todo.AsNoTracking().SingleOrDefaultAsync(x => x.ID == id, ct);
    public async Task<Todo> CreateAsync(CreateOrder order, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var entity = new Todo { Description = order.Description.Trim(), Category = order.Category,
            Status = "Open", CreatedUtc = now, UpdatedUtc = now };
        database.Todo.Add(entity);
        await database.SaveChangesAsync(ct);
        return entity;
    }
    public async Task<bool> UpdateStatusAsync(int id, string status, CancellationToken ct)
    {
        var entity = await database.Todo.FindAsync([id], ct);
        if (entity is null) return false;
        entity.Status = status;
        entity.UpdatedUtc = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(ct);
        return true;
    }
    public async Task<bool> DeleteAsync(int id, CancellationToken ct)
    {
        var entity = await database.Todo.FindAsync([id], ct);
        if (entity is null) return false;
        database.Todo.Remove(entity);
        await database.SaveChangesAsync(ct);
        return true;
    }
    public async Task<OrderSummary> SummaryAsync(CancellationToken ct)
    {
        var groups = await database.Todo.AsNoTracking().GroupBy(x => x.Status)
            .Select(group => new { Status = group.Key, Count = group.Count() }).ToListAsync(ct);
        return new(groups.Sum(x => x.Count),
            groups.Where(x => x.Status == "Open").Sum(x => x.Count),
            groups.Where(x => x.Status == "InProgress").Sum(x => x.Count),
            groups.Where(x => x.Status == "Completed").Sum(x => x.Count));
    }
}
