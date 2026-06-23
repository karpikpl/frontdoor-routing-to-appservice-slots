using System.Text;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FrontdoorUi.Controllers;

[Authorize]
public class HomeController : Controller
{
    [HttpGet("/")]
    [HttpGet("Home/Index")]
    public IActionResult Index()
    {
        var name =
            User.Identity?.Name ??
            User.FindFirst("name")?.Value ??
            User.FindFirst("preferred_username")?.Value ??
            "(unknown)";

        var proxiedBy = Request.Headers["X-Proxied-By"].ToString();
        var proxyBadge = string.IsNullOrEmpty(proxiedBy)
            ? "<p><em>Direct from AFD (no proxy)</em></p>"
            : $"<p>🔀 <strong>Proxied by {System.Net.WebUtility.HtmlEncode(proxiedBy)}</strong></p>";

        var sb = new StringBuilder();
        foreach (var c in User.Claims)
        {
            sb.Append($"<dt>{System.Net.WebUtility.HtmlEncode(c.Type)}</dt>");
            sb.Append($"<dd>{System.Net.WebUtility.HtmlEncode(c.Value)}</dd>");
        }

        var html = $$"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>UI — signed in</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; background: #f5f3ff; margin: 0; padding: 0; }
    .card { max-width: 720px; margin: 4rem auto; background: white; border-radius: 12px;
            box-shadow: 0 4px 16px rgba(0,0,0,.08); padding: 2rem; }
    h1 { color: #6d28d9; margin-top: 0; }
    .pill { display: inline-block; padding: .25rem .75rem; border-radius: 999px;
            background: #6d28d9; color: white; font-weight: 600; }
    dt { font-weight: 600; color: #555; margin-top: .5rem; }
    dd { margin-left: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
         word-break: break-all; }
    .actions { margin-top: 1.5rem; }
    .actions a { color: #6d28d9; text-decoration: none; margin-right: 1rem; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello <span class="pill">{{System.Net.WebUtility.HtmlEncode(name)}}</span></h1>
    <p>You're signed in through Microsoft Entra ID via Azure Front Door.</p>
    {{proxyBadge}}
    <div class="actions">
      <a href="/ui/MicrosoftIdentity/Account/SignOut">Sign out</a>
    </div>
    <h3>Claims</h3>
    <dl>{{sb}}</dl>
  </div>
</body>
</html>
""";
        return Content(html, "text/html");
    }
}
