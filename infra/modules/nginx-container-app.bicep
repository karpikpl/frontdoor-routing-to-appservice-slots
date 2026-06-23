// nginx (nginx:1.27-alpine) reverse proxy in a Container App, deployed as a
// TRANSPARENT header-driven proxy.
//
// Architecture:
//   * Azure Front Door owns all routing logic. For each route it injects an
//     X-Backend-Host header (action=Overwrite, so client-supplied values are
//     replaced — they can't be spoofed).
//   * nginx blindly proxies to https://$http_x_backend_host. No path logic,
//     no per-slot conditionals, no redirects.
//   * Only AFD can reach this Container App: the ACA env is VNet-injected
//     and internal, and AFD reaches it via Shared Private Link (groupId
//     'managedEnvironments'). So trusting the header is safe.
//
// nginx still uses Azure DNS (168.63.129.16) + per-request resolution
// (set $backend ... ; proxy_pass https://$backend;) so it picks up the
// privatelink.azurewebsites.net records that resolve to the PE IPs.

param location string
param tags object = {}

param name string
param containerAppsEnvironmentId string
param workloadProfileName string = 'Consumption'

@description('Min replicas (1 keeps the proxy always-on so first request to Front Door is fast).')
param minReplicas int = 1
param maxReplicas int = 2

// Static nginx config — no envsubst needed since AFD provides the target host
// dynamically per request via X-Backend-Host. Variable names with $ are
// nginx-native and stay literal.
var nginxConfTemplate = '''
server {
    listen 8080 default_server;
    server_name _;

    # Use Azure DNS so privatelink.azurewebsites.net is resolved to the PE IPs
    # at request time (nginx caches per `valid` TTL).
    resolver 168.63.129.16 valid=30s;

    # Reject any redirect from nginx itself (we never want one — AFD owns all
    # path manipulation). Relative redirects + no port leak just in case.
    absolute_redirect off;
    port_in_redirect  off;

    # Health probe consumed by AFD origin health check.
    location = /healthz {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # Debug endpoint: echoes all headers nginx receives. Remove once verified.
    location = /__debug {
        access_log off;
        add_header Content-Type text/plain always;
        add_header X-Echo-Backend "$http_x_backend_host" always;
        return 200 "x-backend-host=[$http_x_backend_host]\nhost=[$http_host]\nx-azure-ref=[$http_x_azure_ref]\nx-forwarded-host=[$http_x_forwarded_host]\nuri=[$request_uri]\n";
    }

    # Strip the /staging prefix before proxying. AFD's UrlRewrite action proved
    # unreliable in our tests, so we do it here. Matches /staging exactly and
    # /staging/anything.
    location = /staging {
        return 302 /staging/;
    }
    location ^~ /staging/ {
        if ($http_x_backend_host = "") {
            return 400 "Missing X-Backend-Host header\n";
        }
        if ($http_x_backend_host !~* "\.azurewebsites\.net$") {
            return 400 "Invalid X-Backend-Host\n";
        }
        set $backend $http_x_backend_host;
        rewrite ^/staging/(.*)$ /$1 break;

        proxy_http_version 1.1;
        proxy_set_header Host                $backend;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   https;
        proxy_set_header X-Forwarded-Host    $host;
        proxy_set_header X-Proxied-By        "nginx-fdr";
        proxy_set_header Connection          "";

        proxy_pass https://$backend;

        proxy_ssl_server_name on;
        proxy_ssl_name $backend;
        proxy_ssl_session_reuse on;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location / {
        # AFD must inject X-Backend-Host. Refuse otherwise — that means the
        # request bypassed our AFD rule sets, which shouldn't be possible.
        if ($http_x_backend_host = "") {
            add_header X-Echo-Backend "$http_x_backend_host" always;
            return 400 "Missing X-Backend-Host header (got=[$http_x_backend_host])\n";
        }
        # Allow-list backend host suffix to prevent SSRF if header validation
        # ever fails open.
        if ($http_x_backend_host !~* "\.azurewebsites\.net$") {
            return 400 "Invalid X-Backend-Host\n";
        }

        set $backend $http_x_backend_host;

        proxy_http_version 1.1;
        proxy_set_header Host                $backend;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   https;
        proxy_set_header X-Forwarded-Host    $host;
        proxy_set_header X-Proxied-By        "nginx-fdr";
        proxy_set_header Connection          "";

        proxy_pass https://$backend;

        proxy_ssl_server_name on;
        proxy_ssl_name $backend;
        proxy_ssl_session_reuse on;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
'''

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': 'nginx' })
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: workloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: [
        {
          name: 'nginx-conf-template'
          #disable-next-line use-secure-value-for-secure-inputs
          value: nginxConfTemplate
        }
      ]
    }
    template: {
      // The template hash is embedded as a label so any change to the nginx
      // config forces a new ACA revision (otherwise secret-value changes
      // alone don't trigger a restart).
      revisionSuffix: 'cfg-${substring(uniqueString(nginxConfTemplate), 0, 8)}'
      initContainers: [
        {
          name: 'nginx-conf-renderer'
          image: 'alpine:3.20'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          command: [
            '/bin/sh'
          ]
          // No envsubst — the template is fully static (no $APP_* placeholders).
          // Just write the secret content to the shared volume.
          args: [
            '-c'
            'set -e; printf "%s" "$NGINX_CONF_TEMPLATE" > /etc/nginx/conf.d/default.conf && echo "Rendered nginx config:" && cat /etc/nginx/conf.d/default.conf'
          ]
          env: [
            {
              name: 'NGINX_CONF_TEMPLATE'
              secretRef: 'nginx-conf-template'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'nginx-conf'
              mountPath: '/etc/nginx/conf.d'
            }
          ]
        }
      ]
      containers: [
        {
          name: 'nginx'
          image: 'nginx:1.27-alpine'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          volumeMounts: [
            {
              volumeName: 'nginx-conf'
              mountPath: '/etc/nginx/conf.d'
            }
          ]
          probes: [
            {
              type: 'Readiness'
              initialDelaySeconds: 3
              periodSeconds: 10
              httpGet: {
                path: '/healthz'
                port: 8080
                scheme: 'HTTP'
              }
            }
            {
              type: 'Liveness'
              initialDelaySeconds: 10
              periodSeconds: 30
              httpGet: {
                path: '/healthz'
                port: 8080
                scheme: 'HTTP'
              }
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'nginx-conf'
          storageType: 'EmptyDir'
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output id string = containerApp.id
output name string = containerApp.name
output fqdn string = containerApp.properties.configuration.ingress.fqdn
