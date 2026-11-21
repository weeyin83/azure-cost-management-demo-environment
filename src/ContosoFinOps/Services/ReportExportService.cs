using System.Globalization;
using System.Text;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using DotNetCoreSqlDb.Models;

namespace DotNetCoreSqlDb.Services;

public sealed class ReportExportService(IServiceProvider services)
{
    public static byte[] Csv(IReadOnlyList<Todo> orders)
    {
        static string Cell(string value)
        {
            var trimmed = value.TrimStart();
            if ((trimmed.Length > 0 && "=+-@".Contains(trimmed[0])) ||
                (value.Length > 0 && "\t\r\n".Contains(value[0]))) value = "'" + value;
            return "\"" + value.Replace("\"", "\"\"") + "\"";
        }
        var output = new StringBuilder("ID,Description,Category,Status,CreatedUtc,UpdatedUtc\r\n");
        foreach (var order in orders)
            output.Append(string.Join(",", order.ID.ToString(CultureInfo.InvariantCulture),
                Cell(order.Description), Cell(order.Category), Cell(order.Status),
                Cell(order.CreatedUtc.ToString("O")), Cell(order.UpdatedUtc.ToString("O")))).Append("\r\n");
        return Encoding.UTF8.GetBytes(output.ToString());
    }
    public async Task<byte[]> ExportAsync(IReadOnlyList<Todo> orders, CancellationToken ct)
    {
        var bytes = Csv(orders);
        var container = services.GetService<BlobContainerClient>();
        if (container is not null)
        {
            using var stream = new MemoryStream(bytes);
            await container.GetBlobClient($"orders/{DateTimeOffset.UtcNow:yyyyMMddTHHmmss}-{Guid.NewGuid():N}.csv")
                .UploadAsync(stream, new BlobUploadOptions
                {
                    HttpHeaders = new BlobHttpHeaders { ContentType = "text/csv; charset=utf-8" }
                }, ct);
        }
        return bytes;
    }
}
