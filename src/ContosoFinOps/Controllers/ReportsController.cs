using DotNetCoreSqlDb.Models;
using DotNetCoreSqlDb.Services;
using Microsoft.AspNetCore.Mvc;

namespace DotNetCoreSqlDb.Controllers;

public class ReportsController(IOrdersService orders, ReportExportService export) : Controller
{
    public async Task<IActionResult> Index(CancellationToken ct) =>
        View(new ReportingViewModel(await orders.SummaryAsync(ct), await orders.ListAsync(ct)));
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Export(CancellationToken ct) =>
        File(await export.ExportAsync(await orders.ListAsync(ct), ct), "text/csv; charset=utf-8", "contoso-orders.csv");
}
