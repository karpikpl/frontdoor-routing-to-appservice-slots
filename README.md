# Front Door → App Service Slots (via nginx)

> **The problem this repo solves:** Azure Front Door's Private Link integration with App Service **does not support deployment slots** — only the production site can be a Private Link origin. So if you want the slot benefits (instant blue/green swap, pre-production smoke testing on the same plan) **and** you want all traffic to stay private end-to-end, AFD alone can't do it. This repo demonstrates how to bridge that gap with a tiny **nginx Container App** that AFD reaches over Private Link and that forwards into slot private endpoints over the VNet.
>
> Reference: [Microsoft Learn — *Connect Azure Front Door Premium to an App Service origin with Private Link*](https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-enable-private-link-web-app):
> > *"This feature isn't supported with App Service Slots."*

---

## Why?

Deployment slots are the standard PaaS pattern for blue/green on App Service: deploy to `staging`, smoke-test the slot's private endpoint, then `swap` instantly to production. They're cheap (run on the same App Service plan) and the swap is near-zero-downtime.

Front Door Premium is the standard way to expose an App Service publicly without giving it a public network endpoint — its **Shared Private Link** feature creates a private endpoint that only AFD can use, so the App Service stays `publicNetworkAccess: Disabled`.

The catch: AFD's SPL integration with App Service is hard-coded to the `sites` sub-resource. **You can't create a Shared Private Link from AFD to the `sites/slots/<slot-name>` sub-resource.** The portal won't list slots, ARM rejects the request, and the [docs explicitly call it out](https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-enable-private-link-web-app). The workarounds people typically reach for all have downsides:

| Workaround | Downside |
|---|---|
| Give the staging slot a public URL | Defeats the point of `publicNetworkAccess: Disabled` |
| Skip slots, use two separate Web Apps instead | Loses the `swap` semantics, doubles your App Service plan footprint, no shared config / sticky settings |
| Put App Gateway in front instead of AFD | App Gateway *does* support a private endpoint per slot, but you lose AFD's global anycast, edge caching, and global WAF |
| Use AFD with public origins + IP restrictions | Origin is still on the internet; trades private networking for a deny-list |

So we keep both AFD's Private Link **and** real App Service slots, and put a thin intermediary in between:

1. AFD has a Shared Private Link to a **Container Apps environment** (which *is* supported as an SPL target).
2. That Container App runs **stock nginx** and reaches the App Service slots over the VNet via their **own** private endpoints (`pe-app-prod` and `pe-app-staging`). The slot PE is fine — *App Service itself* fully supports per-slot private endpoints; it's only **AFD's** SPL that doesn't.
3. AFD's Rules Engine tells nginx which slot to hit by appending an `X-Backend-Host` request header per route.

End result: every public byte rides AFD → SPL → nginx → VNet → slot PE. Nothing on either app is reachable from the public internet.

---

## Topology

```
                       ┌──────────────────────────────────────┐
                       │  Azure Front Door Premium            │
                       │  Rules Engine appends per-route:     │
                       │    X-Backend-Host: <slot-fqdn>       │
                       └──┬───────────────┬──────────────┬────┘
                          │               │              │
                  Shared Private Link to each origin (only path to origins)
                          │               │              │
            /direct/*     │   /ui/*       │       /* and /staging/*
       (prod slot only —  │  (Entra MVC)  │
        AFD's "native"    │               │
        SPL path)         │               │
                          ▼               ▼              ▼
        ┌─────────────────────────┐  ┌──────────┐  ┌──────────────────────┐
        │ App Service (Linux S1)  │  │ UI app   │  │ nginx Container App  │
        │ .NET 8 minimal API      │  │ ASP.NET  │  │ reads X-Backend-Host │
        │  ├─ prod slot  (blue)   │  │ MVC +    │  │ proxy_pass to that   │
        │  └─ staging slot (green)│  │ Entra ID │  │ FQDN over Priv.Link  │
        │  PublicNetworkAccess:   │  └────┬─────┘  └───────────┬──────────┘
        │   Disabled              │       │                    │
        │  Private endpoints:     │       │                    │
        │   pe-app-prod   (sites) │       │                    │
        │   pe-app-staging        │       │                    │
        │     (sites-staging)     │       │                    │
        │   ▲                     │       │                    │
        │   │ both PEs reachable  │       │                    │
        │   │ from the VNet —     │       │                    │
        │   │ but AFD's SPL       │       │                    │
        │   │ only lands on prod  │       │                    │
        └───┴─────────────────────┘       │                    │
                                          │                    │
                  ─────────────────────── VNet ─────────────────┘
```

Key point: **AFD's SPL gives it a private path to *only* the production slot.** Reaching the staging slot privately requires a hop through something else in the VNet that *can* see both PEs — that's nginx.

---

## How the slot-aware routing works

The clever bit is on AFD, not on nginx.

For every nginx-bound route, AFD runs a one-rule **rule set** that appends a request header naming the backend host:

```bicep
// /staging and /staging/* route
{
  name: 'ModifyRequestHeader'
  parameters: {
    headerAction: 'Append'                 // ← see "gotchas" below
    headerName:   'X-Backend-Host'
    value:        'app-fdr-...-staging.azurewebsites.net'
  }
}
```

nginx is a transparent proxy — it never knows there are two slots, it just reads the header and forwards:

```nginx
location / {
    if ($http_x_backend_host = "") { return 400; }                # AFD must inject
    if ($http_x_backend_host !~* "\.azurewebsites\.net$") { return 400; }  # SSRF guard
    set $backend $http_x_backend_host;
    proxy_set_header Host         $backend;
    proxy_set_header X-Proxied-By "nginx-fdr";
    proxy_pass https://$backend;
}
```

The slot FQDN (`*-staging.azurewebsites.net`) resolves inside the VNet to the staging slot's private endpoint IP — via the `privatelink.azurewebsites.net` private DNS zone linked to the VNet. nginx never touches the public internet.

**Why this is safe:** nginx is reachable *only* through AFD's Shared Private Link. There's no way for an end user to hit nginx directly and spoof `X-Backend-Host`. AFD's `Append` action runs at the edge, after the client request is fully terminated. The nginx config also allow-lists the header suffix as a belt-and-braces SSRF guard.

**Adding a third slot / route?** It's two AFD primitives: a route (pattern → origin group) and a one-action rule set (`Append X-Backend-Host = <hostname>`). nginx doesn't change.

---

## What you get

Four routes on a single Front Door endpoint:

| Path | Origin | Notes |
|------|--------|-------|
| `/` (catch-all) | nginx → **production slot** | `X-Proxied-By: nginx-fdr` |
| `/staging`, `/staging/*` | nginx → **staging slot** | nginx strips the `/staging` prefix |
| `/direct/*` | App Service prod (no nginx) | AFD's "native" SPL path — works for prod only, by design |
| `/ui/*` | ASP.NET MVC UI app | **Microsoft Entra ID** sign-in, redirect URI wired through AFD |

The `.NET` sample app surfaces `SLOT_ROLE`, `DEPLOYMENT_COLOR` (blue/green), and `X-Proxied-By` so you can see exactly which slot you hit and whether nginx was in the path.

---

## Resources deployed

- **Front Door Premium** profile, endpoint, 3 origin groups (`og-app`, `og-ui`, `og-nginx`), 4 routes, rule sets for header injection and `/direct` strip
- **App Service Plan** (Linux, S1 — required for slots)
  - `app-...` web app + `staging` deployment slot, each with its own private endpoint
  - `app-ui-...` MVC web app for the Entra-protected UI
- **Container Apps Environment** (workload-profile, internal) + `ca-nginx-...` Container App running stock `nginx:1.27`
- **Virtual Network** with subnets for App Service PE, ACA, and AFD shared private endpoints
- **Private DNS Zones**: `privatelink.azurewebsites.net`, `privatelink.<region>.azurecontainerapps.io`
- **Log Analytics workspace** wired into all of the above
- **Microsoft Entra app registration** for the UI app (created by AZD preprovision hook, redirect URI set in postprovision)

Everything is in `infra/` (Bicep) and `azure.yaml` (AZD).

---

## Quick start

Prerequisites: [`azd`](https://aka.ms/azd), Azure CLI, .NET 8 SDK, an Azure subscription, and an Entra tenant where you can create an app registration.

```bash
git clone <this repo>
cd frontdoor-routing
azd auth login
azd up
```

`azd up` will:

1. Run the `preprovision` hook — captures your current public IP (for SCM allow-list) and creates / refreshes the Entra app registration for the UI app.
2. `azd provision` — deploys all Bicep.
3. `azd deploy` — publishes `src/app` to the production slot, then republishes it to the staging slot.
4. Run the `postprovision` hook — sets the UI app's Entra redirect URI to `https://<afd-endpoint>/ui/signin-oidc`.

When it finishes:

```bash
afd=$(azd env get-value AFD_ENDPOINT_HOSTNAME)

curl "https://$afd/api/whoami"            # → main / blue, proxiedBy: nginx-fdr
curl "https://$afd/staging/api/whoami"    # → staging / green, proxiedBy: nginx-fdr
curl "https://$afd/direct/api/whoami"     # → main / blue, direct (no nginx)
open  "https://$afd/ui/"                  # → Microsoft Entra sign-in flow
```

Swap slots and watch the same URL flip blue ↔ green:

```bash
az webapp deployment slot swap \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value APP_SERVICE_NAME) \
  --slot staging
```

---

## Repository layout

```
.
├── azure.yaml                       AZD config + pre/postprovision/deploy hooks
├── infra/
│   ├── main.bicep                   subscription-scope: RG + everything else
│   ├── main.bicepparam              env-derived parameters (IP, Entra IDs, …)
│   ├── resourcenames.bicep          centralised naming
│   └── modules/
│       ├── network.bicep            VNet + subnets + private DNS zones
│       ├── app-service.bicep        prod + staging slots, slot-sticky env, SCM allow-list
│       ├── app-service-ui.bicep     UI MVC web app + private endpoint
│       ├── container-apps-env.bicep ACA managed environment
│       ├── nginx-container-app.bicep transparent header-driven proxy
│       ├── front-door.bicep         profile, endpoint, origin groups, routes, rule sets
│       └── log-analytics.bicep
└── src/
    ├── app/                         .NET 8 Minimal API: /api/whoami + slot HTML
    └── ui/                          .NET 8 ASP.NET MVC + Microsoft.Identity.Web (Entra ID)
```

---

## Gotchas worth knowing

These are the things that ate the most time while building this — calling them out so you don't repeat them.

| Symptom | Cause | Fix |
|---|---|---|
| Can't create an AFD Shared Private Link to a slot | [Not supported](https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-enable-private-link-web-app) — only the `sites` sub-resource is allowed | This whole repo 🙂 — route via an intermediary that *is* a supported SPL target (ACA) |
| AFD rule says `ModifyRequestHeader Overwrite`, but header never reaches origin | `Overwrite` is a no-op when the header doesn't already exist on the request (despite what the docs imply) | Use `headerAction: 'Append'` |
| AFD `UrlRewrite` action silently doesn't rewrite | Reliability issue with the rules engine for nginx-bound routes | Do path stripping in nginx (`rewrite ^/staging/(.*)$ /$1 break;`) |
| `azd deploy` hangs forever on "Checking deployment slots" | `publicNetworkAccess: Disabled` also blocks SCM/Kudu (which azd talks to) | Set `publicNetworkAccess: Enabled` but use `ipSecurityRestrictions` deny-all on main + `scmIpSecurityRestrictions` allow `MY_IP` on SCM. AFD's Shared Private Link bypasses these IP rules. |
| `azd deploy` errors with "deployment slots detected but no target specified" | azd 1.25+ requires explicit slot selection | `azd env set AZD_DEPLOY_APP_SLOT_NAME production` (handled by preprovision hook) |
| "Cannot exceed the number of slots allowed for the 'Basic' SKU" | App Service Basic doesn't support slots | Use Standard (S1) or higher |
| nginx returns absolute redirects with the internal ACA hostname | Default `absolute_redirect on` leaks listen host:port | `absolute_redirect off; port_in_redirect off;` |
| nginx `set $foo …` after `rewrite … break;` is skipped | `break` ends the rewrite phase, including subsequent `set` directives in the same location | Put `set` **before** `rewrite` |
| Container Apps doesn't restart when only the env-var value changes | Secret-only changes don't bump the revision | Set `revisionSuffix: 'cfg-${substring(uniqueString(template),0,8)}'` so a config-hash change forces a new revision |
| AFD endpoint hostname has a random suffix (`-a2esgpe…`) | Anti-subdomain-takeover hash, non-deterministic | Read it from outputs **after** provision; the `postprovision` hook uses it to set the Entra redirect URI |

---

## Cleanup

```bash
azd down --purge
```

This deletes the resource group and purges the soft-deleted Front Door profile so the name is immediately reusable.

---

## How the slot-aware routing works

The clever bit is on AFD, not on nginx.

For every nginx-bound route, AFD runs a one-rule **rule set** that appends a request header naming the backend host:

```bicep
// /staging and /staging/* route
{
  name: 'ModifyRequestHeader'
  parameters: {
    headerAction: 'Append'                 // ← see "gotchas" below
    headerName:   'X-Backend-Host'
    value:        'app-fdr-...-staging.azurewebsites.net'
  }
}
```

nginx never knows there are two slots. It just reads the header and reverse-proxies:

```nginx
location / {
    if ($http_x_backend_host = "") { return 400; }                # AFD must inject
    if ($http_x_backend_host !~* "\.azurewebsites\.net$") { return 400; }  # SSRF guard
    set $backend $http_x_backend_host;
    proxy_set_header Host       $backend;
    proxy_set_header X-Proxied-By "nginx-fdr";
    proxy_pass https://$backend;
}
```

**Why this is safe:** nginx is reachable *only* through AFD's Shared Private Link. There's no way for an end user to hit nginx directly and spoof `X-Backend-Host`. AFD's `Append` action runs at the edge, after the client request is fully terminated.

**Adding a third slot / route?** It's two AFD primitives: a route (pattern → origin group) and a one-action rule set (`Append X-Backend-Host = <hostname>`). nginx doesn't change.

---

## What you get

Four routes on a single Front Door endpoint:

| Path | Origin | Notes |
|------|--------|-------|
| `/` (catch-all) | nginx → **production slot** | `X-Proxied-By: nginx-fdr` |
| `/staging`, `/staging/*` | nginx → **staging slot** | nginx strips the `/staging` prefix |
| `/direct/*` | App Service prod (no nginx) | Demonstrates the "without slot routing" baseline |
| `/ui/*` | ASP.NET MVC UI app | **Microsoft Entra ID** sign-in, redirect URI wired through AFD |

The `.NET` sample app surfaces `SLOT_ROLE`, `DEPLOYMENT_COLOR` (blue/green), and `X-Proxied-By` so you can see exactly which slot you hit and whether nginx was in the path.

---

## Resources deployed

- **Front Door Premium** profile, endpoint, 3 origin groups (`og-app`, `og-ui`, `og-nginx`), 4 routes, rule sets for header injection and `/direct` strip
- **App Service Plan** (Linux, S1 — required for slots)
  - `app-...` web app + `staging` deployment slot
  - `app-ui-...` MVC web app for the Entra-protected UI
- **Container Apps Environment** (workload-profile, internal) + `ca-nginx-...` Container App running stock `nginx:1.27`
- **Virtual Network** with subnets for App Service PE, ACA, and AFD shared private endpoints
- **Private DNS Zones**: `privatelink.azurewebsites.net`, `privatelink.<region>.azurecontainerapps.io`
- **Log Analytics workspace** wired into all of the above
- **Microsoft Entra app registration** for the UI app (created by AZD preprovision hook, redirect URI set in postprovision)

Everything is in `infra/` (Bicep) and `azure.yaml` (AZD).

---

## Quick start

Prerequisites: [`azd`](https://aka.ms/azd), Azure CLI, .NET 8 SDK, an Azure subscription, and an Entra tenant where you can create an app registration.

```bash
git clone <this repo>
cd frontdoor-routing
azd auth login
azd up
```

`azd up` will:

1. Run the `preprovision` hook — captures your current public IP (for SCM allow-list) and creates / refreshes the Entra app registration for the UI app.
2. `azd provision` — deploys all Bicep.
3. `azd deploy` — publishes `src/app` to the production slot, then republishes it to the staging slot.
4. Run the `postprovision` hook — sets the UI app's Entra redirect URI to `https://<afd-endpoint>/ui/signin-oidc`.

When it finishes:

```bash
afd=$(azd env get-value AFD_ENDPOINT_HOSTNAME)

curl "https://$afd/api/whoami"            # → main / blue, proxiedBy: nginx-fdr
curl "https://$afd/staging/api/whoami"    # → staging / green, proxiedBy: nginx-fdr
curl "https://$afd/direct/api/whoami"     # → main / blue, direct (no nginx)
open  "https://$afd/ui/"                  # → Microsoft Entra sign-in flow
```

Swap slots and watch the same URL flip blue ↔ green:

```bash
az webapp deployment slot swap \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value APP_SERVICE_NAME) \
  --slot staging
```

---

## Repository layout

```
.
├── azure.yaml                       AZD config + pre/postprovision/deploy hooks
├── infra/
│   ├── main.bicep                   subscription-scope: RG + everything else
│   ├── main.bicepparam              env-derived parameters (IP, Entra IDs, …)
│   ├── resourcenames.bicep          centralised naming
│   └── modules/
│       ├── network.bicep            VNet + subnets + private DNS zones
│       ├── app-service.bicep        prod + staging slots, slot-sticky env, SCM allow-list
│       ├── app-service-ui.bicep     UI MVC web app + private endpoint
│       ├── container-apps-env.bicep ACA managed environment
│       ├── nginx-container-app.bicep transparent header-driven proxy
│       ├── front-door.bicep         profile, endpoint, origin groups, routes, rule sets
│       └── log-analytics.bicep
└── src/
    ├── app/                         .NET 8 Minimal API: /api/whoami + slot HTML
    └── ui/                          .NET 8 ASP.NET MVC + Microsoft.Identity.Web (Entra ID)
```

---

## Gotchas worth knowing

These are the things that ate the most time while building this — calling them out so you don't repeat them.

| Symptom | Cause | Fix |
|---|---|---|
| AFD rule says `ModifyRequestHeader Overwrite`, but header never reaches origin | `Overwrite` is a no-op when the header doesn't already exist on the request (despite what the docs imply) | Use `headerAction: 'Append'` |
| AFD `UrlRewrite` action silently doesn't rewrite | Reliability issue with the rules engine for nginx-bound routes | Do path stripping in nginx (`rewrite ^/staging/(.*)$ /$1 break;`) |
| `azd deploy` hangs forever on "Checking deployment slots" | `publicNetworkAccess: Disabled` also blocks SCM/Kudu (which azd talks to) | Set `publicNetworkAccess: Enabled` but use `ipSecurityRestrictions` deny-all on main + `scmIpSecurityRestrictions` allow `MY_IP` on SCM. AFD's Shared Private Link bypasses these IP rules. |
| `azd deploy` errors with "deployment slots detected but no target specified" | azd 1.25+ requires explicit slot selection | `azd env set AZD_DEPLOY_APP_SLOT_NAME production` (handled by preprovision hook) |
| "Cannot exceed the number of slots allowed for the 'Basic' SKU" | App Service Basic doesn't support slots | Use Standard (S1) or higher |
| nginx returns absolute redirects with the internal ACA hostname | Default `absolute_redirect on` leaks listen host:port | `absolute_redirect off; port_in_redirect off;` |
| nginx `set $foo …` after `rewrite … break;` is skipped | `break` ends the rewrite phase, including subsequent `set` directives in the same location | Put `set` **before** `rewrite` |
| Container Apps doesn't restart when only the env-var value changes | Secret-only changes don't bump the revision | Set `revisionSuffix: 'cfg-${substring(uniqueString(template),0,8)}'` so a config-hash change forces a new revision |
| AFD endpoint hostname has a random suffix (`-a2esgpe…`) | Anti-subdomain-takeover hash, non-deterministic | Read it from outputs **after** provision; the `postprovision` hook uses it to set the Entra redirect URI |

---

## Cleanup

```bash
azd down --purge
```

This deletes the resource group and purges the soft-deleted Front Door profile so the name is immediately reusable.
