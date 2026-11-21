using System.ComponentModel.DataAnnotations;

namespace DotNetCoreSqlDb.Models;

public sealed record CreateOrder(
    [Required, StringLength(500), RegularExpression(@"(?s).*\S.*")] string Description,
    [Required, RegularExpression("^(IT|Facilities|Consulting)$")] string Category);
public sealed record UpdateOrderStatus(
    [Required, RegularExpression("^(Open|InProgress|Completed)$")] string Status);
public sealed record OrderSummary(int Total, int Open, int InProgress, int Completed);
