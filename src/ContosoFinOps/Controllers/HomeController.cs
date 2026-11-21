using DotNetCoreSqlDb.Configuration;
using Microsoft.AspNetCore.Mvc;

namespace DotNetCoreSqlDb.Controllers;

public class HomeController(DeploymentOptions deployment) : Controller
{
    public IActionResult Index() => deployment.Role == DeploymentRole.ReportingPortal ?
        RedirectToAction("Index", "Reports") : RedirectToAction("Index", "Todos");
}
