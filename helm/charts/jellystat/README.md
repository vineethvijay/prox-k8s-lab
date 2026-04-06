# Jellystat

```bash
# Copy and fill in secrets
cp helm/charts/jellystat/values-secret.yaml.example helm/charts/jellystat/values-secret.yaml

# Deploy
helm upgrade --install jellystat helm/charts/jellystat -n default -f helm/charts/jellystat/values-secret.yaml
```
