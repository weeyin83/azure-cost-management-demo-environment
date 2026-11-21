namespace DotNetCoreSqlDb.Models;

public sealed record ReportingViewModel(OrderSummary Summary, IReadOnlyList<Todo> Recent);
