using DotNetCoreSqlDb.Models;
using DotNetCoreSqlDb.Services;
using Microsoft.AspNetCore.Mvc;

namespace DotNetCoreSqlDb.Controllers;

public class TodosController(IOrdersService orders) : Controller
{
    public async Task<IActionResult> Index(CancellationToken ct) => View(await ModelAsync(null, ct));
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create([Bind("Description,Category", Prefix = "NewTodo")] Todo todo,
        CancellationToken ct)
    {
        if (!ModelState.IsValid) return View("Index", await ModelAsync(todo, ct));
        await orders.CreateAsync(new(todo.Description, todo.Category), ct);
        return RedirectToAction(nameof(Index));
    }
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Status(int id, UpdateOrderStatus update, CancellationToken ct)
    {
        if (!ModelState.IsValid) return ValidationProblem(ModelState);
        return await orders.UpdateStatusAsync(id, update.Status, ct) ?
            RedirectToAction(nameof(Index)) : NotFound();
    }
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id, CancellationToken ct) =>
        await orders.DeleteAsync(id, ct) ? RedirectToAction(nameof(Index)) : NotFound();
    private async Task<TodosIndexViewModel> ModelAsync(Todo? todo, CancellationToken ct) =>
        new() { NewTodo = todo ?? new Todo(), Todos = await orders.ListAsync(ct) };
}
