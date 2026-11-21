using System.ComponentModel.DataAnnotations;

namespace DotNetCoreSqlDb.Models;

public class Todo
{
    public int ID { get; set; }
    [Required, StringLength(500), RegularExpression(@"(?s).*\S.*", ErrorMessage = "Enter a description.")]
    public string Description { get; set; } = "";
    [Required, RegularExpression("^(IT|Facilities|Consulting)$")]
    public string Category { get; set; } = "IT";
    [Required, RegularExpression("^(Open|InProgress|Completed)$")]
    public string Status { get; set; } = "Open";
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }
}
