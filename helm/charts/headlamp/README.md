# Headlamp

RBAC and Ingress only. The app itself is installed via the upstream chart:

```bash
# Install the headlamp app
helm repo add headlamp https://headlamp-k8s.github.io/headlamp/
helm upgrade --install headlamp-app headlamp/headlamp -n headlamp

# Install RBAC + Ingress
helm upgrade --install headlamp helm/charts/headlamp -n headlamp
```
