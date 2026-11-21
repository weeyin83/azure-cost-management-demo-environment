using DotNetCoreSqlDb.Models;

namespace DotNetCoreSqlDb.Services;

public interface IOrdersService
{
    Task<IReadOnlyList<Todo>> ListAsync(CancellationToken cancellationToken);
    Task<Todo?> FindAsync(int id, CancellationToken cancellationToken);
    Task<Todo> CreateAsync(CreateOrder order, CancellationToken cancellationToken);
    Task<bool> UpdateStatusAsync(int id, string status, CancellationToken cancellationToken);
    Task<bool> DeleteAsync(int id, CancellationToken cancellationToken);
    Task<OrderSummary> SummaryAsync(CancellationToken cancellationToken);
}
