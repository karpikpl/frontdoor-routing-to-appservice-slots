targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Name of the container app to create.')
param name string

@description('Resource ID of the existing Container Apps managed environment.')
param containerAppsEnvironmentId string

param workloadProfileName string = 'Consumption'

@description('The Front Door instance ID (GUID from profile.properties.frontDoorId).')
@secure()
param expectedFrontDoorId string

@description('Min replicas (1 keeps the proxy always-on so first request to Front Door is fast).')
param minReplicas int = 1

param maxReplicas int = 2

param tags object = {}

var nginxConfTemplate = '''
map $http_x_azure_fdid $fdid_ok {
    default             0;
    "__EXPECTED_FDID__" 1;
}

server {
    listen 8080 default_server;
    server_name _;

    resolver 168.63.129.16 valid=30s;

    absolute_redirect off;
    port_in_redirect  off;

    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 2;

    location = /healthz {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location = /staging {
        if ($fdid_ok = 0) {
            return 403 "Forbidden: request did not come from expected Front Door instance\n";
        }
        return 302 /staging/;
    }

    location ^~ /staging/ {
        if ($fdid_ok = 0) {
            return 403 "Forbidden: request did not come from expected Front Door instance\n";
        }

        if ($http_x_backend_host = "") {
            return 400 "Missing X-Backend-Host header\n";
        }

        if ($http_x_backend_host !~* "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.azurewebsites\\.net$") {
            return 400 "Invalid X-Backend-Host\n";
        }

        set $backend $http_x_backend_host;
        rewrite ^/staging/(.*)$ /$1 break;

        proxy_http_version 1.1;
        proxy_set_header Host $backend;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Proxied-By "nginx-fdr";
        proxy_set_header Connection "";

        proxy_pass https://$backend;
        proxy_ssl_server_name on;
        proxy_ssl_name $backend;
        proxy_ssl_session_reuse on;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location / {
        if ($fdid_ok = 0) {
            return 403 "Forbidden: request did not come from expected Front Door instance\n";
        }

        if ($http_x_backend_host = "") {
            add_header X-Echo-Backend "$http_x_backend_host" always;
            return 400 "Missing X-Backend-Host header (got=[$http_x_backend_host])\n";
        }

        if ($http_x_backend_host !~* "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.azurewebsites\\.net$") {
            return 400 "Invalid X-Backend-Host\n";
        }

        set $backend $http_x_backend_host;

        proxy_http_version 1.1;
        proxy_set_header Host $backend;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Proxied-By "nginx-fdr";
        proxy_set_header Connection "";

        proxy_pass https://$backend;
        proxy_ssl_server_name on;
        proxy_ssl_name $backend;
        proxy_ssl_session_reuse on;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
'''

var nginxConf = replace(nginxConfTemplate, '__EXPECTED_FDID__', expectedFrontDoorId)

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppsEnvironmentId
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
          value: nginxConf
        }
      ]
    }
    template: {
      revisionSuffix: 'cfg-${substring(uniqueString(nginxConf), 0, 8)}'
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
 