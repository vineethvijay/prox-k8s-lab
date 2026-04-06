# VPN Downloader (Gluetun VPN sidecar)

```bash
# Copy and fill in secrets
cp helm/charts/vpn-downloader/values-secret.yaml.example helm/charts/vpn-downloader/values-secret.yaml

# Deploy
helm upgrade --install vpn-downloader helm/charts/vpn-downloader -n default -f helm/charts/vpn-downloader/values-secret.yaml
```
