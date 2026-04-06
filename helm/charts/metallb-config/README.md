# MetalLB Config

IPAddressPool + L2Advertisement — MetalLB itself is installed via its own Helm chart.

```bash
helm upgrade --install metallb-config helm/charts/metallb-config -n metallb-system
```
