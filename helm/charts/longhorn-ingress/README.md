# Longhorn Ingress

Ingress only — Longhorn itself is installed via its own Helm chart.

```bash
helm upgrade --install longhorn-ingress helm/charts/longhorn-ingress -n longhorn-system
```
