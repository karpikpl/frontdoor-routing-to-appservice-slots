# frontdoor-routing

AZD-deployed Bicep stack: **Azure Front Door Premium** → **App Service (Linux .NET 8, blue/green slots, private link)**, with a **second AFD route** through an **nginx Container App** that proxies to either the production or staging slot — keeping all traffic private end-to-end.

## Topology

```
                         ┌──────────────────────────────────┐
                         │  Azure Front Door Premium        │
                         │  (global, no WAF)                │
                         └──┬──────────────────────────┬────┘
        Route /direct/*     │                          │   Route /* (catch-all)
        SPL groupId: sites  │                          │   SPL groupId: managedEnvironments
                            ▼                          ▼
                ┌─────────────────────────┐   ┌──────────────────────────────┐
                │  App Service (Linux S1) │   │  Container App: nginx:1.27   │
                │  .NET 8 sample app      │   │  (workload-profile env,      │
                │  PNA: Disabled          │   │   internal, PNA: Disabled)   │
                │  Private endpoints:     │   │  Init container renders      │
                │   - sites               │   │  nginx.conf via envsubst     │
                │   - sites-staging       │   └──────────┬───────────────────┘
                └───────────┬─────────────┘              │
                            │                            │  proxy_pass over
                            │                            │  privatelink DNS
                            ▼                            ▼
                ┌─────────────────────────────────────────────┐
                │  App Service prod slot  /  staging slot     │
                │  Same image, blue/green via slot-sticky     │
                │  env vars (SLOT_ROLE, DEPLOYMENT_COLOR,     │
                │   ACTIVE_SLOT_NAME).                        │
                └─────────────────────────────────────────────┘
```

### Route behavior

| Front Door URL                            | Path inside cluster                                       | Lands on              |
| ----------------------------------------- | --------------------------------------------------------- | --------------------- |
| `https://<afd>/direct/...`                | AFD strips `/direct` → App Service                        | **production slot**   |
| `https://<afd>/...` (catch-all)           | nginx Container App → `/...` → prod hostname              | **production slot**   |
| `https://<afd>/staging/...`               | nginx Container App → strips `/staging` → staging hostname| **staging slot**      |

### Blue/green via slot-sticky settings

`app-service.bicep` marks `SLOT_ROLE`, `DEPLOYMENT_COLOR`, `ACTIVE_SLOT_NAME` as **slot-sticky** (via `Microsoft.Web/sites/config/slotConfigNames`). The values stay tied to the slot they were set on:

| Setting            | Production slot | Staging slot |
| ------------------ | --------------- | ------------ |
| `SLOT_ROLE`        | `main`          | `staging`    |
| `DEPLOYMENT_COLOR` | `blue`          | `green`      |
| `ACTIVE_SLOT_NAME` | `production`    | `staging`    |

After `az webapp deployment slot swap`, the previously-staging instance becomes production (still serves the `staging`/`green` env vars), so `/direct/` and `/` start serving green content and `/staging/` starts serving blue — public AFD URL unchanged.

## Quick start

Prereqs: Azure CLI, [Azure Developer CLI (`azd`)](https://aka.ms/azd-install), .NET 8 SDK, `zip`.

```bash
cd frontdoor-routing
azd auth login
azd env new fdr-dev
azd env set AZURE_LOCATION eastus2
azd up
```

`azd up` runs in order:

1. **Provision** — Bicep deploys VNet, App Service + staging slot (with private endpoints), Container Apps env + nginx, Front Door Premium. **Shared Private Link** requests from AFD to both backends auto-approve.
2. **Build & package** — azd packages `src/app` (.NET 8 minimal API).
3. **Deploy** — `azd deploy` publishes to the **production slot**.
4. **Postdeploy hook** — `dotnet publish` + `az webapp deploy --slot staging` ships the same artifact to the **staging slot**.

After `azd up`, run:

```bash
./scripts/validate.sh
```

Or manually:

```bash
AFD=$(azd env get-value AFD_ENDPOINT_HOSTNAME)
curl "https://$AFD/direct/api/whoami"      # -> blue / main
curl "https://$AFD/api/whoami"             # -> blue / main (via nginx)
curl "https://$AFD/staging/api/whoami"     # -> green / staging (via nginx)
```

## Swap demo

```bash
APP=$(azd env get-value APP_SERVICE_NAME)
RG=$(azd env get-value AZURE_RESOURCE_GROUP)
az webapp deployment slot swap --resource-group "$RG" --name "$APP" --slot staging
```

Re-run the curl commands — now `/direct/` and `/` return **green** (the formerly-staging instance is now production), and `/staging/` returns **blue**.

## Parameters (in `infra/main.bicep`)

| Param             | Default                          | Notes                                                |
| ----------------- | -------------------------------- | ---------------------------------------------------- |
| `location`        | `resourceGroup().location`       | Set via `AZURE_LOCATION` env var. Defaults `eastus2`.|
| `prefix`          | `fdr`                            | Short prefix used in every resource name.            |
| `env`             | `dev`                            | One of dev/uat/prd. Used in names + tags.            |
| `resourceToken`   | `take(uniqueString(rg.id), 8)`   | Override only if you want deterministic names.       |
| `environmentName` | `dev`                            | AZD environment name, applied as `azd-env-name` tag. |

## Files

```
frontdoor-routing/
├── azure.yaml                    AZD config + postdeploy hook for slot deploy
├── README.md
├── src/app/                      Sample .NET 8 minimal-API app
│   ├── frontdoor-sample.csproj
│   ├── Program.cs                Reads SLOT_ROLE / DEPLOYMENT_COLOR / ACTIVE_SLOT_NAME
│   └── appsettings.json
├── infra/
│   ├── main.bicep                Root deployment (RG-scoped)
│   ├── main.bicepparam
│   ├── resourcenames.bicep       Deterministic naming
│   └── modules/
│       ├── vnet.bicep
│       ├── monitoring.bicep
│       ├── private-dns.bicep
│       ├── app-service.bicep     ASP + Web App + staging slot + sticky settings
│       ├── app-service-pe.bicep  PEs for groupIds `sites` + `sites-staging`
│       ├── container-app-env.bicep
│       ├── nginx-container-app.bicep   envsubst-based config injection
│       └── front-door.bicep      AFD Premium + 2 origins + 2 routes + URL rewrite
└── scripts/
    └── validate.sh               curl smoke tests after azd up
```

## Notes & gotchas

- **No WAF** by design. Add one later by attaching a `Microsoft.Cdn/profiles/securityPolicies` resource linked to a `Microsoft.Network/frontdoorWebApplicationFirewallPolicies` (SKU Premium).
- **Shared Private Link approval** — both App Service and Container Apps managed environments auto-approve SPL requests from AFD in the same tenant. If you ever cross tenants, add an `az network private-endpoint-connection approve` postdeploy step.
- **App Service public access disabled** — direct `curl https://<webapp>.azurewebsites.net/` returns 403. All traffic must come through Front Door.
- **App Service runtime DNS** — `vnetRouteAllEnabled: true` plus the regional VNet integration subnet lets the slots resolve each other's hostnames through the private DNS zone (used here only for the nginx side-route).
- **nginx config** — held as a Container Apps secret; an `alpine:3.20` init container installs `gettext` and runs `envsubst` over an explicit whitelist (`$APP_PROD_HOST $APP_STAGING_HOST`) so nginx-native variables stay literal. Pattern lifted from a LiteLLM proxy in a sibling repo.
- **Container Apps env workload profile** — `Consumption` for cost; switch to `D4` dedicated if you need consistent low-latency response (Consumption has cold starts).
