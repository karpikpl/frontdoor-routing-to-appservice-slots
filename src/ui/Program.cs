// ASP.NET Core 8 MVC app that signs users in with Microsoft Entra ID,
// served behind Azure Front Door at the /ui/* path prefix.
//
// Important wiring:
//   * UsePathBase("/ui") so generated URLs (incl. OIDC redirect URI)
//     include the /ui prefix and match the path AFD forwards through.
//   * ForwardedHeaders middleware trusts AFD's X-Forwarded-Host / -Proto,
//     so Microsoft.Identity.Web builds the redirect URI against the
//     PUBLIC AFD hostname (not the private *.azurewebsites.net origin).
//   * App registration is created by the AZD preprovision hook
//     (see azure.yaml). The postprovision hook sets the redirect URI on
//     the app reg to https://<afd>/ui/signin-oidc once AFD is known.

using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto |
        ForwardedHeaders.XForwardedHost;
    // AFD is the only upstream proxy; trust any source for simplicity.
    o.KnownNetworks.Clear();
    o.KnownProxies.Clear();
});

builder.Services
    .AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApp(builder.Configuration.GetSection("AzureAd"));

builder.Services.AddAuthorization(o =>
{
    // Require authentication everywhere by default.
    o.FallbackPolicy = o.DefaultPolicy;
});

builder.Services
    .AddControllersWithViews()
    .AddMicrosoftIdentityUI();

var app = builder.Build();

app.UseForwardedHeaders();
app.UsePathBase("/ui");
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();

// Unauthenticated health probe (used by AFD origin health check).
app.MapGet("/healthz", () => Results.Text("ok", "text/plain"))
   .AllowAnonymous();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.Run();
