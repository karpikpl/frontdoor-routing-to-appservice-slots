// nginx (nginx:1.27-alpine) reverse proxy in a Container App.
//
// Routes from Front Door (catch-all `/*` route, Shared Private Link via
// groupId 'managedEnvironments') land here. nginx then forwards:
//   /staging/<rest>  ->  https://<appStagingHost>/<rest>
//   /<anything else> ->  https://<appProdHost>/<anything else>
//
// Both upstream hostnames live in privatelink.azurewebsites.net (resolved
// privately through the VNet-linked private DNS zone), so traffic stays on
// the Azure backbone end-to-end.
//
// Config injection pattern lifted from
// otis/ai-foundry-config-testing/options-infra/modules/litellm/litellm-proxy.bicep:
//   * NGINX_CONF_TEMPLATE is held as a Container Apps secret.
//   * An init container ('nginx-conf-renderer') installs gettext (envsubst)
//     and writes the rendered config to an EmptyDir volume mounted at
//     /etc/nginx/conf.d.
//   * The main nginx container reads it on startup.

param location string
param tags object = {}

param name string
param containerAppsEnvironmentId string
param workloadProfileName string = 'Consumption'

@description('Production slot FQDN, e.g. app-fdr-dev-xxx.azurewebsites.net.')
param appProdHost string

@description('Staging slot FQDN, e.g. app-fdr-dev-xxx-staging.azurewebsites.net.')
param appStagingHost string

@description('Min replicas (1 keeps the proxy always-on so first request to Front Door is fast).')
param minReplicas int = 1
param maxReplicas int = 2

// nginx config template — envsubst substitutes $APP_PROD_HOST and
// $APP_STAGING_HOST, every other $variable is escaped via a quoted
// envsubst whitelist so nginx keeps seeing them as native variables.
//
// Notes:
//   * `proxy_ssl_server_name on` + `proxy_ssl_name` set SNI to the upstream
//     hostname, which is what App Service expects for cert + host routing.
//   * `proxy_set_header Host` is set to the upstream FQDN so App Service
//     routes to the right site/slot (App Service routes by Host header).
//   * `resolver 168.63.129.16` is Azure DNS; combined with the variable
//     indirection `set $up ...` it forces per-request DNS resolution.
var nginxConfTemplate = '''
server {
    listen 8080 default_server;
    server_name _;

    resolver 168.63.129.16 valid=30s;

    location = /healthz {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # Route: /staging/* -> staging slot (with prefix stripped).
    location /staging/ {
        rewrite ^/staging/(.*)$ /$1 break;

        proxy_http_version 1.1;
        proxy_set_header Host                $APP_STAGING_HOST;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   https;
        proxy_set_header X-Forwarded-Host    $host;
        proxy_set_header Connection          "";

        set $up_staging https://$APP_STAGING_HOST;
        proxy_pass $up_staging;

        proxy_ssl_server_name on;
        proxy_ssl_name $APP_STAGING_HOST;
        proxy_ssl_session_reuse on;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    # Bare /staging (no trailing slash) -> 301 to /staging/.
    location = /staging {
        return 301 /staging/;
    }

    # Default: everything else -> production slot.
    location / {
        proxy_http_version 1.1;
        proxy_set_header Host                $APP_PROD_HOST;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   https;
        proxy_set_header X-Forwarded-Host    $host;
        proxy_set_header Connection          "";

        set $up_prod https://$APP_PROD_HOST;
        proxy_pass $up_prod;

        proxy_ssl_server_name on;
        proxy_ssl_name $APP_PROD_HOST;
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
          // envsubst with an explicit whitelist so ONLY $APP_PROD_HOST and
          // $APP_STAGING_HOST are substituted; nginx-native variables
          // ($remote_addr, $up_prod, $host, ...) stay literal.
          args: [
            '-c'
            'set -e; apk add --no-cache gettext >/dev/null && printf "%s" "$NGINX_CONF_TEMPLATE" > /tmp/default.conf.tmpl && envsubst \'$APP_PROD_HOST $APP_STAGING_HOST\' < /tmp/default.conf.tmpl > /etc/nginx/conf.d/default.conf && echo "Rendered nginx config:" && cat /etc/nginx/conf.d/default.conf'
          ]
          env: [
            {
              name: 'NGINX_CONF_TEMPLATE'
              secretRef: 'nginx-conf-template'
            }
            {
              name: 'APP_PROD_HOST'
              value: appProdHost
            }
            {
              name: 'APP_STAGING_HOST'
              value: appStagingHost
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
