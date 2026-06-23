// Minimal API that surfaces the slot's blue/green identity.
//
// Slot-sticky app settings (set by app-service.bicep + sites/config slotConfigNames):
//   SLOT_ROLE          main | staging
//   DEPLOYMENT_COLOR   blue | green
//   ACTIVE_SLOT_NAME   production | staging
//
// After `az webapp deployment slot swap ... --slot staging` these values
// stay tied to the slot, so the "main/blue" page swaps over to the formerly
// staging instance (and vice versa) without changing the public AFD URL.

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

string SlotRole()    => Environment.GetEnvironmentVariable("SLOT_ROLE") ?? "unknown";
string Color()       => Environment.GetEnvironmentVariable("DEPLOYMENT_COLOR") ?? "unknown";
string ActiveSlot()  => Environment.GetEnvironmentVariable("ACTIVE_SLOT_NAME") ?? "unknown";
string MachineName() => Environment.MachineName;

app.MapGet("/healthz", () => Results.Text("ok", "text/plain"));

app.MapGet("/api/whoami", (HttpContext ctx) => Results.Json(new
{
    slotRole       = SlotRole(),
    color          = Color(),
    activeSlotName = ActiveSlot(),
    host           = ctx.Request.Host.Value,
    path           = ctx.Request.Path.Value,
    proxiedBy      = ctx.Request.Headers["X-Proxied-By"].ToString(),
    machineName    = MachineName(),
    utc            = DateTime.UtcNow,
}));

app.MapGet("/{**catchall}", (HttpContext ctx) =>
{
    var color = Color();
    var proxiedBy = ctx.Request.Headers["X-Proxied-By"].ToString();
    var proxyBadge = string.IsNullOrEmpty(proxiedBy)
        ? "<p><em>Direct from AFD (no proxy)</em></p>"
        : $"<p>🔀 <strong>Proxied by {System.Net.WebUtility.HtmlEncode(proxiedBy)}</strong></p>";
    var bg = color switch
    {
        "blue"  => "#dbeafe",
        "green" => "#dcfce7",
        _       => "#f3f4f6",
    };
    var accent = color switch
    {
        "blue"  => "#1d4ed8",
        "green" => "#15803d",
        _       => "#374151",
    };

    // $$ raw string: {{ }} interpolates, single { } is literal (so CSS braces are written as-is).
    var html = $$"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>{{SlotRole()}} / {{color}}</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; background: {{bg}}; margin: 0; padding: 0; }
    .card { max-width: 640px; margin: 4rem auto; background: white; border-radius: 12px;
            box-shadow: 0 4px 16px rgba(0,0,0,.08); padding: 2rem; }
    h1 { color: {{accent}}; margin-top: 0; }
    dt { font-weight: 600; color: #555; margin-top: .75rem; }
    dd { margin-left: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .pill { display: inline-block; padding: .25rem .75rem; border-radius: 999px;
            background: {{accent}}; color: white; font-weight: 600; }
  </style>
</head>
<body>
  <div class="card">
    <h1>App Service slot: <span class="pill">{{SlotRole()}}</span></h1>
    <p>Color: <strong>{{color}}</strong></p>
    {{proxyBadge}}
    <dl>
      <dt>SLOT_ROLE</dt><dd>{{SlotRole()}}</dd>
      <dt>DEPLOYMENT_COLOR</dt><dd>{{color}}</dd>
      <dt>ACTIVE_SLOT_NAME</dt><dd>{{ActiveSlot()}}</dd>
      <dt>Host header</dt><dd>{{ctx.Request.Host.Value}}</dd>
      <dt>Path</dt><dd>{{ctx.Request.Path.Value}}</dd>
      <dt>Machine name</dt><dd>{{MachineName()}}</dd>
      <dt>Server time (UTC)</dt><dd>{{DateTime.UtcNow:O}}</dd>
    </dl>
  </div>
</body>
</html>
""";
    return Results.Content(html, "text/html");
});

app.Run();
